/// CrashGuard — Notification service.
///
/// Configures [FlutterLocalNotificationsPlugin] with a max-priority
/// channel and provides methods for full-screen intent notifications
/// that appear over the lock screen and wake the device.
///
/// KEY FEATURES:
///   1. Full-screen intent notification — launches app when screen locked.
///   2. `ongoing: true` — user cannot swipe the notification away.
///   3. `category: alarm` — treated as urgent by Android OS.
///   4. `visibility: public` — shown on lock screen.
///   5. Notification tap routing — opens AlertScreen with accident data.
///   6. `getNotificationLaunchDetails()` — for cold start from notification.
library;

import 'dart:convert';

import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/constants.dart';
import '../models/accident_event.dart';

/// Callback invoked when the user taps the "Stop Detection" action button
/// on the monitoring notification. Called even when app is dead.
@pragma('vm:entry-point')
void onMonitoringNotificationResponse(NotificationResponse response) {
  print('[NotificationService] Monitoring action: ${response.actionId}');
  if (response.actionId == 'stop_detection') {
    // Save state that monitoring should be stopped
    _handleStopDetectionFromBackground();
  }
}

/// Handles the Stop Detection action when tapped from background.
Future<void> _handleStopDetectionFromBackground() async {
  try {
    // Clear monitoring session from SharedPreferences
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(kPrefIsMonitoringActive);
    await prefs.remove(kPrefMonitoringStartMs);
    print('[NotificationService] Monitoring session cleared from background');
  } catch (e) {
    print('[NotificationService] Error clearing monitoring session: $e');
  }
}

/// Callback invoked when the user taps the notification while app is dead.
/// The response is stored and handled on next app launch via
/// `getNotificationAppLaunchDetails()`.
@pragma('vm:entry-point')
void notificationTapBackground(NotificationResponse response) {
  // Background taps are handled by getNotificationAppLaunchDetails() on relaunch.
  print('[NotificationService] Background tap: ${response.payload}');
}

/// Manages local notifications (full-screen intent for accident alerts).
class NotificationService {
  static final FlutterLocalNotificationsPlugin _plugin =
      FlutterLocalNotificationsPlugin();

  /// Reference so other parts of the app can access the plugin.
  static FlutterLocalNotificationsPlugin get plugin => _plugin;

  /// Callback when accident notification is tapped (set by main.dart).
  /// The callback receives the parsed [AccidentEvent] if available.
  static void Function(AccidentEvent? event)? onAlertNotificationTapped;

  /// Initializes the notification plugin and creates the alert channel.
  static Future<void> initialize() async {
    const androidInit = AndroidInitializationSettings('@mipmap/ic_launcher');
    const initSettings = InitializationSettings(android: androidInit);

    await _plugin.initialize(
      initSettings,
      onDidReceiveNotificationResponse: _handleNotificationTap,
      onDidReceiveBackgroundNotificationResponse: onMonitoringNotificationResponse,
    );

    // Create the high-priority channel for accident alerts.
    final androidPlugin = _plugin
        .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin>();
    if (androidPlugin != null) {
      // Alert channel (full-screen accident notifications)
await androidPlugin.createNotificationChannel(
  const AndroidNotificationChannel(
    kAlertChannelId,
    kAlertChannelName,
    description: kAlertChannelDescription,
    importance: Importance.max,
    playSound: true,
    enableVibration: true,
  ),
);

// Background service channel (required for foreground service notification)
await androidPlugin.createNotificationChannel(
  const AndroidNotificationChannel(
    'crash_guard_bg',
    'CrashGuard Background',
    description: 'Keeps CrashGuard running in the background',
    importance: Importance.low,  // low so it doesn't disturb user
    playSound: false,
    enableVibration: false,
  ),
);

print('[NotificationService] Notification channels created');
    }
  }

  /// Shows a full-screen intent notification (appears over lock screen).
  ///
  /// [payload] is an optional JSON string containing accident data.
  /// When present, it's passed through to the notification tap handler
  /// so AlertScreen can reconstruct the accident event.
  static Future<void> showAlertNotification({String? payload}) async {
    const androidDetails = AndroidNotificationDetails(
      kAlertChannelId,
      kAlertChannelName,
      channelDescription: kAlertChannelDescription,
      importance: Importance.max,
      priority: Priority.max,
      fullScreenIntent: true,
      ongoing: true,
      autoCancel: false,
      playSound: true,
      enableVibration: true,
      category: AndroidNotificationCategory.alarm,
      visibility: NotificationVisibility.public,
    );

    const details = NotificationDetails(android: androidDetails);

    await _plugin.show(
      kAlertNotificationId,
      'Accident Detected!',
      'Tap to respond before emergency SMS is sent.',
      details,
      payload: payload ?? 'accident_alert',
    );
    print('[NotificationService] Full-screen notification shown');
  }

  /// Cancels the alert notification.
  static Future<void> cancelAlertNotification() async {
    await _plugin.cancel(kAlertNotificationId);
    print('[NotificationService] Alert notification cancelled');
  }

  /// Shows a persistent monitoring notification with a "Stop Detection" action button.
  ///
  /// This notification:
  ///   - Uses the low-importance background channel (no sound)
  ///   - Has one action button: "Stop Detection"
  ///   - Is ongoing (user cannot swipe it away)
  ///   - Tapping the body opens the app
  ///   - Tapping the action button stops the service without opening app
  static Future<void> showMonitoringNotification() async {
    final androidDetails = AndroidNotificationDetails(
      'crash_guard_bg',
      'CrashGuard Background',
      channelDescription: 'Keeps CrashGuard running in the background',
      importance: Importance.low,
      priority: Priority.low,
      ongoing: true,
      autoCancel: false,
      playSound: false,
      enableVibration: false,
      actions: [
        const AndroidNotificationAction(
          'stop_detection',
          'Stop Detection',
          showsUserInterface: false,
        ),
      ],
    );

    final details = NotificationDetails(android: androidDetails);

    await _plugin.show(
      kMonitoringNotificationId,
      'CrashGuard Active',
      'Monitoring for accidents · Tap to open',
      details,
      payload: 'monitoring',
    );
    print('[NotificationService] Monitoring notification shown');
  }

  /// Cancels the persistent monitoring notification.
  static Future<void> cancelMonitoringNotification() async {
    await _plugin.cancel(kMonitoringNotificationId);
    print('[NotificationService] Monitoring notification cancelled');
  }

  /// Checks if the app was launched from an accident notification.
  ///
  /// Called once during app startup in main.dart.
  /// Returns the parsed [AccidentEvent] if a valid payload is found,
  /// or `null` if the app was launched normally.
  static Future<AccidentEvent?> getNotificationLaunchEvent() async {
    try {
      final details = await _plugin.getNotificationAppLaunchDetails();
      if (details == null || !details.didNotificationLaunchApp) {
        return null;
      }

      final payload = details.notificationResponse?.payload;
      if (payload == null || payload.isEmpty) return null;

      print('[NotificationService] App launched from notification: $payload');
      return _parsePayload(payload);
    } catch (e) {
      print('[NotificationService] Error checking launch details: $e');
      return null;
    }
  }

  /// Handles notification tap when app is in foreground.
  static void _handleNotificationTap(NotificationResponse response) {
    print('[NotificationService] Notification tapped: ${response.payload}');
    final event = _parsePayload(response.payload);
    onAlertNotificationTapped?.call(event);
  }

  /// Parses a notification payload JSON string into an [AccidentEvent].
  /// Returns `null` if the payload is invalid or not an accident alert.
  static AccidentEvent? _parsePayload(String? payload) {
    if (payload == null || payload.isEmpty) return null;

    // Handle legacy simple payload
    if (payload == 'accident_alert') return null;

    try {
      final map = jsonDecode(payload) as Map<String, dynamic>;
      if (map['type'] != 'accident_alert') return null;

      return AccidentEvent(
        id: map['key'] as String? ?? '',
        status: map['status'] as String? ?? 'ACCIDENT',
        latitude: (map['latitude'] as num?)?.toDouble() ?? 0.0,
        longitude: (map['longitude'] as num?)?.toDouble() ?? 0.0,
        timestamp: map['timestamp'] as String? ?? '',
        deviceId: map['device_id'] as String? ?? '',
      );
    } catch (e) {
      print('[NotificationService] Error parsing payload: $e');
      return null;
    }
  }
}
