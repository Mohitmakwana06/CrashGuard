/// CrashGuard — Firebase Realtime Database service.
///
/// Listens to `accidents/{device_id}` for new accident events
/// written by the linked ESP32 device. Implements debounce logic
/// to prevent duplicate triggers.
///
/// KEY FIXES v4:
///   1. Added `_listenerStartTime` — events with timestamps before this
///      are ignored. This prevents `onChildAdded` replaying old events
///      from poisoning the debounce window.
///   2. Reduced debounce to 10 seconds (via constants).
///   3. Reset `_lastProcessedTimestamp` on each `startListening()` call.
///   4. Comprehensive print() logging at every decision point.
///   5. If event timestamp cannot be parsed, event is ALLOWED through
///      (better to send a duplicate alert than miss a real accident).
library;

import 'dart:async';

import 'package:firebase_database/firebase_database.dart';

import '../core/constants.dart';
import '../core/env_config.dart';
import '../models/accident_event.dart';

/// Manages the Firebase Realtime Database connection and accident listeners.
class FirebaseService {
  FirebaseService._();

  static final FirebaseDatabase _db = FirebaseDatabase.instance;

  /// Stream controller that emits validated [AccidentEvent]s.
  static StreamController<AccidentEvent> _accidentController =
      StreamController<AccidentEvent>.broadcast();

  /// Stream controller for connection state changes.
  static StreamController<bool> _connectionController =
      StreamController<bool>.broadcast();

  /// Public stream of accident events (already debounced).
  static Stream<AccidentEvent> get accidentStream => _accidentController.stream;

  /// Public stream of connection state (true = connected).
  static Stream<bool> get connectionStream => _connectionController.stream;

  /// Last processed event timestamp (for debounce).
  static String? _lastProcessedTimestamp;

  /// Time when `startListening()` was called. Events with timestamps
  /// before this are skipped (they are replayed old events, not new ones).
  static DateTime? _listenerStartTime;

  /// The active subscription (so we can cancel on dispose).
  static StreamSubscription<DatabaseEvent>? _childSubscription;
  static StreamSubscription<DatabaseEvent>? _connectedSubscription;

  /// The device ID currently being listened to.
  static String? _activeDeviceId;

  // ---------------------------------------------------------------------------
  // Public API
  // ---------------------------------------------------------------------------

  /// Starts listening to the linked device's accident events.
  ///
  /// If [deviceId] is provided, listens on that device.
  /// Otherwise falls back to [EnvConfig.linkedDeviceIdSync].
  ///
  /// Path: `accidents/{deviceId}`
  /// Uses `onChildAdded` to catch each new event written by ESP32.
  static void startListening({String? deviceId}) {
    final id = deviceId ?? EnvConfig.linkedDeviceIdSync;

    // If already listening to the same device, skip.
    if (_activeDeviceId == id) {
      print('[Firebase] Already listening to $id -- skipping duplicate');
      return;
    }

    // If listening to a different device, stop first.
    if (_activeDeviceId != null) {
      print('[Firebase] Switching device: $_activeDeviceId -> $id');
      stopListening();
    }

    // Ensure controllers are alive (recreate if previously closed).
    _ensureControllersOpen();

    // CRITICAL FIX: Record when the listener started so we can skip
    // replayed old events from onChildAdded.
    _listenerStartTime = DateTime.now().toUtc();
    print('[Firebase] Listener start time set to: $_listenerStartTime');

    // CRITICAL FIX: Reset debounce state so old sessions don't
    // carry over and filter new events.
    _lastProcessedTimestamp = null;
    print('[Firebase] Debounce state reset (_lastProcessedTimestamp = null)');

    _activeDeviceId = id;
    final ref = _db.ref('$kFirebaseAccidentsRoot/$id');

    print('[Firebase] ============================================');
    print('[Firebase] LISTENER STARTED');
    print('[Firebase] Path: $kFirebaseAccidentsRoot/$id');
    print('[Firebase] Debounce window: ${kDebounceWindowSeconds}s');
    print('[Firebase] ============================================');

    // Listen for new children (each child is a timestamped event).
    _childSubscription = ref.onChildAdded.listen(
      _handleChildAdded,
      onError: (error) {
        print('[Firebase] Listener error: $error');
        // Attempt to recover after a brief delay.
        Future.delayed(const Duration(seconds: 5), () {
          if (_activeDeviceId == id) {
            print('[Firebase] Attempting listener recovery...');
            _childSubscription?.cancel();
            _childSubscription = ref.onChildAdded.listen(
              _handleChildAdded,
              onError: (e) =>
                  print('[Firebase] Recovery listener error: $e'),
            );
          }
        });
      },
    );

    // Monitor connection state.
    _connectedSubscription =
        _db.ref('.info/connected').onValue.listen((event) {
      final connected = event.snapshot.value as bool? ?? false;
      _safeAddToConnection(connected);
      print('[Firebase] Connection state: ${connected ? "CONNECTED" : "DISCONNECTED"}');
    }, onError: (error) {
      print('[Firebase] Connection listener error: $error');
    });
  }

  /// Starts listening using the dynamically resolved device ID.
  ///
  /// Fetches the device ID from SharedPreferences / .env and starts.
  static Future<void> startListeningAsync() async {
    final id = await EnvConfig.getLinkedDeviceId();
    startListening(deviceId: id);
  }

  /// Stops listening and releases resources.
  static Future<void> stopListening() async {
    print('[Firebase] Stopping listener for device: $_activeDeviceId');
    _activeDeviceId = null;
    _listenerStartTime = null;
    await _childSubscription?.cancel();
    _childSubscription = null;
    await _connectedSubscription?.cancel();
    _connectedSubscription = null;
  }

  /// Marks an event as handled in Firebase.
  ///
  /// Writes `HANDLED` status back to the event node.
  static Future<void> markAsHandled(AccidentEvent event) async {
    try {
      final deviceId = _activeDeviceId ?? EnvConfig.linkedDeviceIdSync;
      final ref = _db.ref(
        '$kFirebaseAccidentsRoot/$deviceId/${event.id}',
      );
      await ref.update({'status': kStatusHandled});
      print('[Firebase] Marked event ${event.id} as HANDLED');
    } catch (e) {
      print('[Firebase] Failed to mark as handled: $e');
    }
  }

  /// Writes a test accident event to Firebase (for simulator).
  static Future<void> writeTestAccident({String? deviceId}) async {
    final id = deviceId ?? _activeDeviceId ?? EnvConfig.linkedDeviceIdSync;
    final ts = DateTime.now().toUtc().toIso8601String();
    final ref = _db.ref('$kFirebaseAccidentsRoot/$id').push();

    try {
      await ref.set({
        'status': kStatusAccident,
        'latitude': 28.6139,
        'longitude': 77.2090,
        'timestamp': ts,
        'device_id': id,
      });
      print('[Firebase] Wrote test accident via push key at $ts');
    } catch (e) {
      print('[Firebase] Error writing test accident: $e');
    }
  }

  // ---------------------------------------------------------------------------
  // Internals
  // ---------------------------------------------------------------------------

  /// Ensures the stream controllers are open. Recreates them if they
  /// were previously closed (e.g., after stopListening or disposal).
  static void _ensureControllersOpen() {
    if (_accidentController.isClosed) {
      _accidentController = StreamController<AccidentEvent>.broadcast();
    }
    if (_connectionController.isClosed) {
      _connectionController = StreamController<bool>.broadcast();
    }
  }

  /// Safely adds an accident event to the controller (won't crash if closed).
  static void _safeAddToAccident(AccidentEvent event) {
    if (!_accidentController.isClosed) {
      _accidentController.add(event);
    }
  }

  /// Safely adds a connection state to the controller (won't crash if closed).
  static void _safeAddToConnection(bool connected) {
    if (!_connectionController.isClosed) {
      _connectionController.add(connected);
    }
  }

  /// Processes a new child event from Firebase.
  static void _handleChildAdded(DatabaseEvent event) {
    try {
      final data = event.snapshot.value;
      final key = event.snapshot.key ?? '(null)';

      print('[Firebase] -------- New child added --------');
      print('[Firebase] Key: $key');

      if (data == null || data is! Map) {
        print('[Firebase] SKIP: non-map child data: $data');
        return;
      }

      final accidentEvent =
          AccidentEvent.fromMap(data, key: event.snapshot.key ?? '');

      print('[Firebase] Event status: "${accidentEvent.status}"');
      print('[Firebase] Event timestamp: "${accidentEvent.timestamp}"');
      print('[Firebase] Event device: "${accidentEvent.deviceId}"');
      print('[Firebase] Event coords: ${accidentEvent.latitude}, ${accidentEvent.longitude}');

      // Check 1: Must be an ACCIDENT status.
      if (!accidentEvent.isAccident) {
        print('[Firebase] SKIP: not an accident (status="${accidentEvent.status}")');
        return;
      }

      // Check 2: Skip events whose timestamp is BEFORE the listener started.
      // This prevents onChildAdded replaying old events from poisoning debounce.
      if (_listenerStartTime != null && accidentEvent.timestamp.isNotEmpty) {
        try {
          final eventTime = DateTime.parse(accidentEvent.timestamp);
          if (eventTime.isBefore(_listenerStartTime!)) {
            print('[Firebase] SKIP: old event (event=${accidentEvent.timestamp}, '
                'listener started=$_listenerStartTime)');
            return;
          }
          print('[Firebase] PASS: event is after listener start time');
        } catch (_) {
          // If timestamp cannot be parsed, DO NOT skip.
          // Better to send a duplicate alert than miss a real accident.
          print('[Firebase] WARN: could not parse timestamp '
              '"${accidentEvent.timestamp}" -- allowing event through');
        }
      }

      // Check 3: Debounce — skip if we already processed this exact timestamp.
      if (_lastProcessedTimestamp != null &&
          accidentEvent.timestamp == _lastProcessedTimestamp) {
        print('[Firebase] SKIP: duplicate timestamp "${accidentEvent.timestamp}"');
        return;
      }

      // Check 4: Debounce — skip if timestamp is within the debounce window.
      if (_lastProcessedTimestamp != null) {
        try {
          final lastTime = DateTime.parse(_lastProcessedTimestamp!);
          final thisTime = DateTime.parse(accidentEvent.timestamp);
          final diff = thisTime.difference(lastTime).inSeconds.abs();
          if (diff < kDebounceWindowSeconds) {
            print('[Firebase] SKIP: debounced (${diff}s < ${kDebounceWindowSeconds}s)');
            return;
          }
          print('[Firebase] PASS: debounce check OK (${diff}s >= ${kDebounceWindowSeconds}s)');
        } catch (_) {
          // FIX: When NTP hasn't synced, ESP32 sends millis() as timestamp
          // (e.g. "45123"). DateTime.parse() fails on these. Use numeric
          // comparison as a fallback debounce to prevent duplicate alerts.
          final lastMs = int.tryParse(_lastProcessedTimestamp!);
          final thisMs = int.tryParse(accidentEvent.timestamp);
          if (lastMs != null && thisMs != null) {
            final diffMs = (thisMs - lastMs).abs();
            if (diffMs < kDebounceWindowSeconds * 1000) {
              print('[Firebase] SKIP: millis debounced (${diffMs}ms < ${kDebounceWindowSeconds * 1000}ms)');
              return;
            }
            print('[Firebase] PASS: millis debounce OK (${diffMs}ms)');
          } else {
            print('[Firebase] WARN: could not parse timestamps for debounce '
                '-- allowing event through');
          }
        }
      } else {
        print('[Firebase] PASS: no previous event to debounce against');
      }

      // Accept this event.
      _lastProcessedTimestamp = accidentEvent.timestamp;
      _safeAddToAccident(accidentEvent);

      print('[Firebase] *** ACCIDENT EVENT ACCEPTED ***');
      print('[Firebase] Emitting to stream: $accidentEvent');
      print('[Firebase] --------------------------------');
    } catch (e) {
      print('[Firebase] Error processing child: $e');
    }
  }
}
