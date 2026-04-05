/// CrashGuard — Device management service (Firebase RTDB).
///
/// Manages the `users/{userId}` and `devices/{deviceId}` paths
/// in Firebase Realtime Database. Handles linking/unlinking devices,
/// fetching device info, and monitoring online/offline status.
///
/// KEY FIXES:
///   1. Added _activeDeviceId guard to prevent duplicate listeners.
///   2. Added _ensureControllerOpen() for safe stream lifecycle.
///   3. Added fetchCurrentStatus() for one-shot checks on app resume.
///   4. Increased stale threshold to 45s, reduced re-check to 15s.
library;

import 'dart:async';
import 'dart:developer' as dev;

import 'package:firebase_database/firebase_database.dart';

import '../core/constants.dart';
import '../core/env_config.dart';
import '../models/device_info.dart';

/// How many seconds without a heartbeat before treating device as offline.
/// Set to 3× the ESP32 heartbeat interval (15s × 3 = 45s) to allow for
/// network jitter and single missed heartbeats.
const int kDeviceStaleThresholdSeconds = 45;

/// Firebase device management service.
class DeviceService {
  DeviceService._();

  static final FirebaseDatabase _db = FirebaseDatabase.instance;

  /// Active subscription for device status monitoring.
  static StreamSubscription<DatabaseEvent>? _statusSubscription;

  /// Periodic timer for staleness checks.
  static Timer? _stalenessTimer;

  /// The device ID currently being listened to (prevents duplicate listeners).
  static String? _activeDeviceId;

  /// The most recent status, used to replay to new subscribers.
  static bool _lastKnownStatus = false;

  /// Stream controller for device online/offline status.
  static StreamController<bool> _statusController =
      StreamController<bool>.broadcast();

  /// Public stream of device online status.
  static Stream<bool> get deviceStatusStream async* {
    yield _lastKnownStatus;
    yield* _statusController.stream;
  }

  // ---------------------------------------------------------------------------
  // Controller Lifecycle
  // ---------------------------------------------------------------------------

  /// Ensures the stream controller is open. Recreates it if previously closed.
  static void _ensureControllerOpen() {
    if (_statusController.isClosed) {
      _statusController = StreamController<bool>.broadcast();
      dev.log('[DeviceService] Recreated _statusController');
    }
  }

  /// Safely emits a value on the status controller.
  static void _safeAdd(bool value) {
    _lastKnownStatus = value;
    if (!_statusController.isClosed) {
      _statusController.add(value);
    }
  }

  // ---------------------------------------------------------------------------
  // Linking / Unlinking
  // ---------------------------------------------------------------------------

  /// Links a device to a user in Firebase.
  ///
  /// Writes to both `users/{userId}` and `devices/{deviceId}`.
  /// Also persists locally via [EnvConfig].
  static Future<void> linkDevice({
    required String userId,
    required String deviceId,
    required String deviceName,
  }) async {
    final now = DateTime.now().millisecondsSinceEpoch;

    try {
      // Write to users/{userId}
      await _db.ref('$kFirebaseUsersRoot/$userId').update({
        'deviceId': deviceId,
        'deviceName': deviceName,
        'pairedAt': now,
      });
    } catch (e) {
      dev.log('[DeviceService] Error writing user link: $e');
    }

    try {
      // Write to devices/{deviceId}
      await _db.ref('$kFirebaseDevicesRoot/$deviceId').update({
        'userId': userId,
        'deviceName': deviceName,
        'status': 'online',
        'lastSeen': now,
      });
    } catch (e) {
      dev.log('[DeviceService] Error writing device link: $e');
    }

    // Persist locally.
    await EnvConfig.setLinkedDeviceId(deviceId);
    await EnvConfig.setLinkedDeviceName(deviceName);
    await EnvConfig.setDevicePaired(true);

    dev.log('[DeviceService] Linked device $deviceId to user $userId');
  }

  /// Unlinks a device from a user. Clears local storage.
  static Future<void> unlinkDevice({
    required String userId,
    required String deviceId,
  }) async {
    try {
      // Remove device fields from user profile.
      await _db.ref('$kFirebaseUsersRoot/$userId').update({
        'deviceId': null,
        'deviceName': null,
        'pairedAt': null,
      });
    } catch (e) {
      dev.log('[DeviceService] Error clearing user link: $e');
    }

    try {
      // Remove user from device record.
      await _db.ref('$kFirebaseDevicesRoot/$deviceId').update({
        'userId': null,
        'status': 'offline',
      });
    } catch (e) {
      dev.log('[DeviceService] Error clearing device link: $e');
    }

    // Clear local cache.
    await EnvConfig.clearDeviceInfo();

    // Stop status monitoring.
    await stopListening();

    dev.log('[DeviceService] Unlinked device $deviceId from user $userId');
  }

  // ---------------------------------------------------------------------------
  // Fetching
  // ---------------------------------------------------------------------------

  /// Fetches the linked device info for a user from Firebase.
  ///
  /// Returns null if no device is linked.
  static Future<DeviceInfo?> getLinkedDevice(String userId) async {
    try {
      final snapshot =
          await _db.ref('$kFirebaseUsersRoot/$userId').get();

      if (!snapshot.exists || snapshot.value == null) return null;

      final data = Map<dynamic, dynamic>.from(snapshot.value as Map);
      final deviceId = data['deviceId'] as String?;
      if (deviceId == null || deviceId.isEmpty) return null;

      return DeviceInfo.fromUserMap(userId, data);
    } catch (e) {
      dev.log('[DeviceService] Error fetching linked device: $e');
      return null;
    }
  }

  /// Fetches device status from the `devices/` path.
  static Future<DeviceInfo?> getDeviceStatus(String deviceId) async {
    try {
      final snapshot =
          await _db.ref('$kFirebaseDevicesRoot/$deviceId').get();

      if (!snapshot.exists || snapshot.value == null) return null;

      final data = Map<dynamic, dynamic>.from(snapshot.value as Map);
      return DeviceInfo.fromDeviceMap(deviceId, data);
    } catch (e) {
      dev.log('[DeviceService] Error fetching device status: $e');
      return null;
    }
  }

  /// One-shot status fetch — useful on app resume to get immediate status
  /// before real-time listener data arrives.
  static Future<bool> fetchCurrentStatus(String deviceId) async {
    final path = '$kFirebaseDevicesRoot/$deviceId';
    dev.log('[DeviceService] Querying path: $path');
    try {
      final snapshot = await _db.ref(path).get();

      if (!snapshot.exists || snapshot.value == null) return false;

      final data = Map<dynamic, dynamic>.from(snapshot.value as Map);
      final status = (data['status'] as String?) ?? 'offline';
      final lastSeen = data['lastSeen'];

      bool isOnline = status == 'online';
      if (isOnline && lastSeen != null) {
        isOnline = _isRecentlySeen(lastSeen);
      }

      _safeAdd(isOnline);
      dev.log('[DeviceService] fetchCurrentStatus: $deviceId → ${isOnline ? "ONLINE" : "OFFLINE"}');
      return isOnline;
    } catch (e) {
      dev.log('[DeviceService] fetchCurrentStatus error: $e');
      return false;
    }
  }

  // ---------------------------------------------------------------------------
  // Real-time Status Monitoring
  // ---------------------------------------------------------------------------

  /// Starts listening to the device's online/offline status.
  ///
  /// Uses a two-layer approach:
  /// 1. Firebase `onValue` listener for immediate status changes.
  /// 2. Periodic staleness timer that re-checks `lastSeen` every 15s.
  ///    If `lastSeen` is older than [kDeviceStaleThresholdSeconds], the
  ///    device is treated as offline even if `status` says "online".
  ///
  /// GUARD: If already listening to the same device, this is a no-op.
  static void listenToDeviceStatus(String deviceId) {
    // Guard: prevent duplicate listener registration for the same device.
    if (_activeDeviceId == deviceId) {
      dev.log('[DeviceService] Already listening to $deviceId — skipping');
      return;
    }

    // If listening to a different device, stop first.
    if (_activeDeviceId != null) {
      dev.log('[DeviceService] Switching listener from $_activeDeviceId to $deviceId');
      stopListening();
    }

    _activeDeviceId = deviceId;
    _ensureControllerOpen();

    final path = '$kFirebaseDevicesRoot/$deviceId';
    dev.log('[DeviceService] Querying path: $path');

    // Layer 1: Real-time Firebase listener on the entire device node.
    final ref = _db.ref(path);
    _statusSubscription = ref.onValue.listen((event) {
      try {
        if (!event.snapshot.exists || event.snapshot.value == null) {
          _safeAdd(false);
          dev.log('[DeviceService] Device $deviceId: no data → offline');
          return;
        }

        final data = Map<dynamic, dynamic>.from(event.snapshot.value as Map);
        final status = (data['status'] as String?) ?? 'offline';
        final lastSeen = data['lastSeen'];

        bool isOnline = status == 'online';

        // Staleness check: if lastSeen is a valid epoch and too old, force offline.
        if (isOnline && lastSeen != null) {
          isOnline = _isRecentlySeen(lastSeen);
        }

        _safeAdd(isOnline);
        dev.log('[DeviceService] Device $deviceId: status=$status, '
            'lastSeen=$lastSeen, resolved=${isOnline ? "ONLINE" : "OFFLINE"}');
      } catch (e) {
        dev.log('[DeviceService] Status parse error: $e');
        _safeAdd(false);
      }
    }, onError: (error) {
      dev.log('[DeviceService] Status listener error: $error');
      _safeAdd(false);
    });

    // Layer 2: Periodic staleness re-check every 15s (was 30s).
    _stalenessTimer = Timer.periodic(
      const Duration(seconds: 15),
      (_) => _recheckStaleness(deviceId),
    );

    dev.log('[DeviceService] Started listening to device: $deviceId');
  }

  /// Periodically re-fetches device data to detect stale "online" status.
  static Future<void> _recheckStaleness(String deviceId) async {
    // Safety: don't run staleness check if no longer active
    if (_activeDeviceId != deviceId) return;

    try {
      final snapshot = await _db.ref('$kFirebaseDevicesRoot/$deviceId').get();
      if (!snapshot.exists || snapshot.value == null) {
        _safeAdd(false);
        return;
      }

      final data = Map<dynamic, dynamic>.from(snapshot.value as Map);
      final status = (data['status'] as String?) ?? 'offline';
      final lastSeen = data['lastSeen'];

      bool isOnline = status == 'online';
      if (isOnline && lastSeen != null) {
        isOnline = _isRecentlySeen(lastSeen);
      }

      _safeAdd(isOnline);
    } catch (e) {
      dev.log('[DeviceService] Staleness recheck error: $e');
    }
  }

  /// Checks if [lastSeen] (epoch ms or raw int) is within the threshold.
  static bool _isRecentlySeen(dynamic lastSeen) {
    try {
      final int lastSeenMs;
      if (lastSeen is num) {
        lastSeenMs = lastSeen.toInt();
      } else if (lastSeen is String) {
        lastSeenMs = int.tryParse(lastSeen) ?? 0;
      } else {
        dev.log('[DeviceService] _isRecentlySeen error: lastSeen is unknown type ${lastSeen.runtimeType}');
        return false;
      }

      // If the value looks like a real epoch (after year 2020), check staleness.
      // Year 2020 epoch ms ≈ 1577836800000
      if (lastSeenMs > 1577836800000) {
        final now = DateTime.now().millisecondsSinceEpoch;
        final double ageSeconds = (now - lastSeenMs) / 1000;
        dev.log('[DeviceService] _isRecentlySeen check: lastSeenMs=$lastSeenMs, now=$now, ageSeconds=$ageSeconds');
        if (ageSeconds > kDeviceStaleThresholdSeconds) {
          dev.log('[DeviceService] Device stale: ${ageSeconds.toInt()}s since last heartbeat');
          return false;
        }
      }
      // If it's a small number (millis() uptime from ESP32 fallback),
      // just trust the "online" status field.
      return true;
    } catch (e) {
      dev.log('[DeviceService] _isRecentlySeen generic error: $e');
      return false;
    }
  }

  /// Stops monitoring device status.
  static Future<void> stopListening() async {
    _activeDeviceId = null;
    _lastKnownStatus = false;
    await _statusSubscription?.cancel();
    _statusSubscription = null;
    _stalenessTimer?.cancel();
    _stalenessTimer = null;
    dev.log('[DeviceService] Stopped listening');
  }
}
