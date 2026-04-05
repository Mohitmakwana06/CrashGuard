/// CrashGuard — Application entry point.
///
/// Initializes Firebase, Hive, dotenv, notifications, FCM,
/// background service, requests permissions, sets up auth-gated
/// routing (Login -> BLE Scan -> Dashboard), starts the Firebase
/// RTDB listener for the linked device, and launches the app.
///
/// KEY FEATURES v5:
///   1. Notification launch detection — if app is started from a
///      background accident notification, triggers AlertService and
///      navigates directly to AlertScreen.
///   2. Background service invoke listener — handles accident data
///      sent from the background isolate when app is alive.
///   3. Cross-isolate deduplication via AccidentDeduplicator.
///   4. Every pre-runApp init step wrapped in its own try-catch.
///   5. Delayed permission/service init via addPostFrameCallback.
///   6. WidgetsBindingObserver for proper lifecycle management.
///   7. Single source of truth for Firebase listeners.
///   8. Comprehensive print() logging throughout.
library;

import 'dart:async';
import 'dart:developer' as dev;

import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_background_service/flutter_background_service.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hive_flutter/hive_flutter.dart';

import 'core/app_theme.dart';
import 'core/constants.dart';
import 'core/env_config.dart';
import 'core/error_provider.dart';
import 'core/theme_provider.dart';
import 'features/accident/accident_provider.dart';
import 'features/accident/dashboard_screen.dart';
import 'features/alert/alert_provider.dart';
import 'features/alert/alert_screen.dart';
import 'features/auth/auth_provider.dart';
import 'features/auth/login_screen.dart';
import 'features/ble/ble_provider.dart';
import 'features/common/error_banner.dart';

import 'models/accident_event.dart';
import 'models/contact_model.dart';
import 'services/alert_service.dart';
import 'services/background_service.dart';
import 'services/device_service.dart';
import 'services/fcm_service.dart';
import 'services/firebase_service.dart';
import 'services/notification_service.dart';
import 'services/permission_service.dart';

/// Global navigator key — allows pushing routes from background callbacks.
final GlobalKey<NavigatorState> navigatorKey = GlobalKey<NavigatorState>();

/// Global Riverpod container — allows updating providers from outside widgets.
late final ProviderContainer _container;

/// ─── Listener Management ────────────────────────────────────────────────────
/// Track all active subscriptions to prevent duplicates and leaks.
bool _isListenerActive = false;
StreamSubscription<AccidentEvent>? _accidentSub;
StreamSubscription<bool>? _connectionSub;
StreamSubscription<bool>? _deviceStatusSub;

/// Pending accident event from notification launch (set before runApp,
/// processed after first frame renders).
AccidentEvent? _pendingNotificationEvent;

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // ── STEP 1: Load environment variables (.env) ──────────────────────────
  try {
    await dotenv.load(fileName: '.env');
    print('[main] .env loaded successfully');
  } catch (e) {
    print('[main] Failed to load .env: $e -- using empty env');
  }

  // ── STEP 2: Initialize Firebase ────────────────────────────────────────
  try {
    await Firebase.initializeApp();
    print('[main] Firebase initialized');
  } catch (e) {
    print('[main] Firebase initialization failed: $e');
    runApp(_BootstrapErrorApp(error: 'Firebase failed to initialize:\n$e'));
    return;
  }

  // ── STEP 3: Initialize Hive for local storage ──────────────────────────
  try {
    await Hive.initFlutter();
    Hive.registerAdapter(EmergencyContactAdapter());
    await Hive.openBox<EmergencyContact>(kContactsBoxName);
    print('[main] Hive initialized');
  } catch (e) {
    print('[main] Hive initialization error: $e');
  }

  // ── STEP 4: Initialize notification service ────────────────────────────
  try {
    await NotificationService.initialize();
    print('[main] Notifications initialized');
  } catch (e) {
    print('[main] Notification init error: $e');
  }

  // ── STEP 5: Check if launched from accident notification ───────────────
  try {
    _pendingNotificationEvent =
        await NotificationService.getNotificationLaunchEvent();
    if (_pendingNotificationEvent != null) {
      print('[main] ================================================');
      print('[main] APP LAUNCHED FROM ACCIDENT NOTIFICATION');
      print('[main] Event: $_pendingNotificationEvent');
      print('[main] Will trigger alert after first frame');
      print('[main] ================================================');
    }
  } catch (e) {
    print('[main] Error checking notification launch: $e');
  }

  // ── STEP 6: Initialize FCM ─────────────────────────────────────────────
  try {
    await FcmService.initialize();
    print('[main] FCM initialized');
  } catch (e) {
    print('[main] FCM init error: $e');
  }

  // ── STEP 7: Create the Riverpod container ──────────────────────────────
  _container = ProviderContainer();

  // ── STEP 8: Load persisted device info into providers ──────────────────
  try {
    await _loadPersistedDeviceInfo();
  } catch (e) {
    print('[main] Failed to load persisted device info: $e');
  }

  // ── STEP 9: Set up notification tap routing ────────────────────────────
  _setupNotificationRouting();

  runApp(
    UncontrolledProviderScope(
      container: _container,
      child: const CrashGuardApp(),
    ),
  );

  // ── STEP 11: Post-frame initialization ─────────────────────────────────
WidgetsBinding.instance.addPostFrameCallback((_) async {
  // Handle notification launch first
  if (_pendingNotificationEvent != null) {
    await Future.delayed(const Duration(milliseconds: 500));
    await _handleNotificationLaunchEvent(_pendingNotificationEvent!);
    _pendingNotificationEvent = null;
  }

  // Small delay to let first frame render fully before heavy init
  await Future.delayed(const Duration(seconds: 1));

  // Setup background listener BEFORE starting services
  _setupBackgroundServiceListener();

  // Init services last — awaited so errors are caught properly
  await _initDelayedServices();
});
}

/// Handles a pending accident from notification launch.
///
/// Called after the first frame renders and services are ready.
/// Triggers AlertService and pushes AlertScreen.
Future<void> _handleNotificationLaunchEvent(AccidentEvent event) async {
  print('[main] Processing notification launch event: ${event.id}');

  // Don't dedup here — the background service already marked it as processed.
  // We NEED to trigger the alert even if it was "processed" by background.

  // If AlertService is already active (unlikely on cold start), skip.
  if (AlertService.isActive) {
    print('[main] AlertService already active -- just pushing AlertScreen');
    _pushAlertScreen();
    return;
  }

  // Update providers.
  _container.read(lastAccidentEventProvider.notifier).state = event;
  _container.read(accidentStatusProvider.notifier).state =
      AccidentStatus.alertActive;
  _container.read(alertCountdownProvider.notifier).state =
      kAlertTimeoutSeconds;

  // Trigger the alert.
  await AlertService.trigger(event: event);

  // Navigate to alert screen.
  _pushAlertScreen();
}

Future<void> _initDelayedServices() async {
  // ── Permissions ────────────────────────────────────────────────────────
  final permResult = await PermissionService.requestAll();

  if (!permResult.allCriticalGranted) {
    print('[main] Permissions not fully granted: ${permResult.summary}');

    if (permResult.locationPermanentlyDenied ||
        permResult.notificationPermanentlyDenied) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        final ctx = navigatorKey.currentContext;
        if (ctx != null) {
          PermissionService.showExplanationDialog(
            ctx,
            locationDenied: permResult.locationPermanentlyDenied,
            notificationDenied: permResult.notificationPermanentlyDenied,
          );
        }
      });
    }

    reportAppError(
      _container,
      message: permResult.summary ?? 'Some permissions were denied',
      source: 'Permissions',
      severity: ErrorSeverity.warning,
    );
  } else {
    print('[main] All critical permissions granted');
  }

  // ── Twilio Credential Check ────────────────────────────────────────────
  EnvConfig.logTwilioStatus();

  if (!EnvConfig.isTwilioConfiguredProperly) {
    final validationError = EnvConfig.twilioValidationError;
    print('[main] Twilio not configured: $validationError');
    reportAppError(
      _container,
      message: validationError ?? 'Twilio SMS is not configured',
      source: 'SMS Service',
      severity: ErrorSeverity.info,
    );
  }

  // ── Start Firebase Listener ────────────────────────────────────────────
  final currentUser = FirebaseAuth.instance.currentUser;
  final isPaired = await EnvConfig.isDevicePaired();
  print('[main] User: ${currentUser?.uid ?? "null"}, isPaired: $isPaired');

  if (currentUser != null && isPaired) {
    print('[main] Starting Firebase listener (user signed in + device paired)');
    await _startFirebaseListener();
  } else {
    print('[main] Firebase listener NOT started '
        '(user=${currentUser != null}, paired=$isPaired)');
  }

  // ── Start Background Service (Delayed by 3 seconds) ────────────────────
  Future.delayed(const Duration(seconds: 3), () async {
    try {
      await BackgroundService.initialize();
      print('[main] Background service started');
    } catch (e) {
      print('[main] Background service failed: $e');
    }
  });
}

/// Loads persisted device info from SharedPreferences into Riverpod providers.
Future<void> _loadPersistedDeviceInfo() async {
  final isPaired = await EnvConfig.isDevicePaired();
  final deviceId = await EnvConfig.getLinkedDeviceId();
  final deviceName = await EnvConfig.getLinkedDeviceName();

  print('[main] Persisted device: isPaired=$isPaired, id=$deviceId, name=$deviceName');

  _container.read(isDevicePairedProvider.notifier).state = isPaired;
  if (isPaired) {
    _container.read(pairedDeviceIdProvider.notifier).state = deviceId;
    _container.read(pairedDeviceNameProvider.notifier).state = deviceName;
  }
}

/// Subscribes to Firebase accident events and triggers alerts.
///
/// CRITICAL: This method guards against duplicate registrations.
/// All previous subscriptions are cancelled before new ones are created.
Future<void> _startFirebaseListener() async {
  // Guard: prevent duplicate listener setup
  if (_isListenerActive) {
    print('[main] Listener already active -- skipping duplicate registration');
    return;
  }
  _isListenerActive = true;

  final deviceId = await EnvConfig.getLinkedDeviceId();
  print('[main] ================================================');
  print('[main] Starting Firebase listener for device: $deviceId');
  print('[main] ================================================');

  FirebaseService.startListening(deviceId: deviceId);

  // Cancel any stale subscriptions first
  await _accidentSub?.cancel();
  await _connectionSub?.cancel();
  await _deviceStatusSub?.cancel();

  _accidentSub = FirebaseService.accidentStream.listen(
    (AccidentEvent event) async {
      print('[main] ================================================');
      print('[main] ACCIDENT EVENT received from foreground stream');
      print('[main] Event: $event');
      print('[main] ================================================');

      // If AlertService is already active (background invoke beat us), skip.
      if (AlertService.isActive) {
        print('[main] AlertService already active -- skipping duplicate trigger');
        return;
      }

      print('[main] Calling AlertService.trigger()...');

      // Update providers.
      _container.read(lastAccidentEventProvider.notifier).state = event;
      _container.read(accidentStatusProvider.notifier).state =
          AccidentStatus.alertActive;
      _container.read(alertCountdownProvider.notifier).state =
          kAlertTimeoutSeconds;

      // Trigger the alert.
      AlertService.trigger(event: event);

      // Navigate to alert screen.
      _pushAlertScreen();
    },
    onError: (error) {
      print('[main] Accident stream error: $error');
    },
  );

  // Monitor connection state.
  _connectionSub = FirebaseService.connectionStream.listen(
    (connected) {
      _container.read(firebaseConnectedProvider.notifier).state = connected;
    },
    onError: (error) {
      print('[main] Connection stream error: $error');
    },
  );

  // Monitor device online/offline status.
  _deviceStatusSub = DeviceService.deviceStatusStream.listen(
    (isOnline) {
      _container.read(deviceOnlineProvider.notifier).state = isOnline;
    },
    onError: (error) {
      print('[main] Device status stream error: $error');
    },
  );

  DeviceService.listenToDeviceStatus(deviceId);

  // Immediately fetch current status (don't wait for first heartbeat).
  await DeviceService.fetchCurrentStatus(deviceId);

  print('[main] All listeners registered for device: $deviceId');
}

/// Stops all Firebase listeners and cleans up subscriptions.
Future<void> _stopFirebaseListener() async {
  _isListenerActive = false;
  await _accidentSub?.cancel();
  _accidentSub = null;
  await _connectionSub?.cancel();
  _connectionSub = null;
  await _deviceStatusSub?.cancel();
  _deviceStatusSub = null;
  await FirebaseService.stopListening();
  await DeviceService.stopListening();
  print('[main] All Firebase listeners stopped');
}

/// Called on app resume — refreshes status without re-requesting permissions.
Future<void> _onAppResumed() async {
  print('[main] App resumed -- refreshing state');

  // Verify permissions (no dialogs, just check current state).
  await PermissionService.verifyGranted();

  // Refresh device status if paired.
  final isPaired = await EnvConfig.isDevicePaired();
  if (isPaired) {
    final deviceId = await EnvConfig.getLinkedDeviceId();
    await DeviceService.fetchCurrentStatus(deviceId);

    // Ensure listener is still running.
    if (!_isListenerActive) {
      print('[main] Listener was inactive on resume -- restarting');
      await _startFirebaseListener();
    }
  }
}

/// Sets up notification tap -> alert screen navigation.
void _setupNotificationRouting() {
  NotificationService.onAlertNotificationTapped = (AccidentEvent? event) {
    print('[main] Notification tapped -- event=$event');
    if (AlertService.isActive) {
      // Alert already running — just push the screen
      _pushAlertScreen();
    } else if (event != null) {
      // Alert not running — trigger from notification data
      _handleNotificationLaunchEvent(event);
    }
  };

  FcmService.onMessageTapped = (_) {
    if (AlertService.isActive) {
      _pushAlertScreen();
    }
  };
}

/// Listens for accident invocations from the background service isolate.
///
/// When the background service detects an accident, it invokes the UI
/// isolate with the event data. This handler triggers AlertService
/// and pushes AlertScreen.
void _setupBackgroundServiceListener() {
  try {
    FlutterBackgroundService().on('accident_detected').listen((data) async {
      if (data == null) return;

      print('[main] ================================================');
      print('[main] ACCIDENT received from background service');
      print('[main] Data: $data');
      print('[main] ================================================');

      // If AlertService is already active (foreground already triggered), skip.
      if (AlertService.isActive) {
        print('[main] AlertService already active -- skipping background invoke');
        return;
      }

      // Reconstruct AccidentEvent from the data map.
      final event = AccidentEvent(
        id: data['key'] as String? ?? '',
        status: data['status'] as String? ?? 'ACCIDENT',
        latitude: (data['latitude'] as num?)?.toDouble() ?? 0.0,
        longitude: (data['longitude'] as num?)?.toDouble() ?? 0.0,
        timestamp: data['timestamp'] as String? ?? '',
        deviceId: data['device_id'] as String? ?? '',
      );

      // Background already marked this as processed — don't dedup again.
      // Just trigger the alert.
      _container.read(lastAccidentEventProvider.notifier).state = event;
      _container.read(accidentStatusProvider.notifier).state =
          AccidentStatus.alertActive;
      _container.read(alertCountdownProvider.notifier).state =
          kAlertTimeoutSeconds;

      await AlertService.trigger(event: event);
      _pushAlertScreen();
    });
    print('[main] Background service listener registered');
  } catch (e) {
    print('[main] Error setting up background service listener: $e');
  }
}

/// Pushes the alert screen using the global navigator key.
void _pushAlertScreen() {
  final navigator = navigatorKey.currentState;
  if (navigator == null) {
    print('[main] Navigator not available -- cannot push AlertScreen');
    return;
  }

  navigator.push(
    PageRouteBuilder(
      opaque: true,
      pageBuilder: (_, animation, secondaryAnimation) => const AlertScreen(),
      transitionsBuilder: (_, animation, secondaryAnimation, child) {
        return FadeTransition(opacity: animation, child: child);
      },
      transitionDuration: const Duration(milliseconds: 300),
    ),
  );
}

// ─────────────────────────────────────────────────────────────────────────────
// Root Widget
// ─────────────────────────────────────────────────────────────────────────────

/// Root widget with auth-gated navigation + global ErrorBanner overlay.
class CrashGuardApp extends ConsumerWidget {
  const CrashGuardApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final themeMode = ref.watch(themeModeProvider);

    return MaterialApp(
      navigatorKey: navigatorKey,
      title: 'CrashGuard',
      debugShowCheckedModeBanner: false,
      theme: lightTheme,
      darkTheme: darkTheme,
      themeMode: themeMode,
      home: const Stack(
        children: [
          _AuthGate(),
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: ErrorBanner(),
          ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Auth Gate
// ─────────────────────────────────────────────────────────────────────────────

/// Auth gate — routes users based on auth state and device pairing.
class _AuthGate extends ConsumerStatefulWidget {
  const _AuthGate();

  @override
  ConsumerState<_AuthGate> createState() => _AuthGateState();
}

class _AuthGateState extends ConsumerState<_AuthGate>
    with WidgetsBindingObserver {
  StreamSubscription<User?>? _authSub;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);

    _authSub = FirebaseAuth.instance.authStateChanges().listen((user) async {
      if (user != null) {
        print('[main] Auth state: signed in as ${user.uid}');
        final isPaired = await EnvConfig.isDevicePaired();
        if (isPaired) {
          await _startFirebaseListener();
        }
      } else {
        print('[main] Auth state: signed out');
        await _stopFirebaseListener();
      }
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _authSub?.cancel();
    _authSub = null;
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    switch (state) {
      case AppLifecycleState.resumed:
        _onAppResumed();
        break;
      case AppLifecycleState.paused:
        dev.log('[main] App paused -- listeners kept alive');
        break;
      case AppLifecycleState.detached:
        dev.log('[main] App detached -- cleaning up');
        _stopFirebaseListener();
        break;
      default:
        break;
    }
  }

  @override
  Widget build(BuildContext context) {
    ref.listen<bool>(isDevicePairedProvider, (previous, next) {
      if (previous == false && next == true) {
        final user = FirebaseAuth.instance.currentUser;
        if (user != null) {
          print('[main] Device paired during session -- starting Firebase listener');
          _startFirebaseListener();
        }
      }
    });

    final authState = ref.watch(authStateProvider);

    return authState.when(
      data: (user) {
        if (user == null) {
          return const LoginScreen();
        }
        return const DashboardScreen();
      },
      loading: () => const Scaffold(
        body: Center(child: CircularProgressIndicator()),
      ),
      error: (e, st) => const LoginScreen(),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Bootstrap Error App (shown when Firebase fails to init)
// ─────────────────────────────────────────────────────────────────────────────

class _BootstrapErrorApp extends StatelessWidget {
  final String error;
  const _BootstrapErrorApp({required this.error});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'CrashGuard - Error',
      debugShowCheckedModeBanner: false,
      theme: lightTheme,
      home: Scaffold(
        body: SafeArea(
          child: Center(
            child: Padding(
              padding: const EdgeInsets.all(32),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.error_outline_rounded,
                      size: 64, color: Colors.red),
                  const SizedBox(height: 24),
                  const Text(
                    'CrashGuard Failed to Start',
                    style: TextStyle(
                      fontSize: 22,
                      fontWeight: FontWeight.w700,
                    ),
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 16),
                  Text(
                    error,
                    style: const TextStyle(fontSize: 14, color: Colors.black54),
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 32),
                  const Text(
                    'Please check your setup and restart the app.',
                    style: TextStyle(fontSize: 13, color: Colors.grey),
                    textAlign: TextAlign.center,
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
