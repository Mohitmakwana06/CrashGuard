/// CrashGuard — Permission service.
///
/// Requests all runtime permissions required by the app.
/// Provides helpers to check and prompt for individual capabilities
/// like Bluetooth and Location (used by the BLE scan flow).
///
/// KEY FIXES:
///   1. Check-before-request pattern to avoid Android 10+ location
///      settings redirect loop.
///   2. Detects `permanentlyDenied` on Android 14+ and shows a
///      one-time explanation dialog instead of silently skipping.
///   3. Returns [PermissionRequestResult] with per-permission details
///      so callers can report specific failures to the user.
library;

import 'dart:developer' as dev;

import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:permission_handler/permission_handler.dart';

/// Structured result from [PermissionService.requestAll].
class PermissionRequestResult {
  final bool allCriticalGranted;
  final bool locationPermanentlyDenied;
  final bool notificationPermanentlyDenied;
  final bool notificationGranted;
  final bool locationGranted; // ADD: so main.dart can check location specifically before starting FGS
  final String? summary;

  const PermissionRequestResult({
    required this.allCriticalGranted,
    this.locationPermanentlyDenied = false,
    this.notificationPermanentlyDenied = false,
    this.notificationGranted = false,
    this.locationGranted = false, // ADD
    this.summary,
  });
}

/// Handles runtime permission requests.
class PermissionService {
  PermissionService._();

  /// Whether we've already requested permissions this app session.
  /// Prevents the Android location-settings redirect loop on every resume.
  static bool _hasRequestedThisSession = false;

  /// Whether we've already shown the explanation dialog this session.
  static bool _hasShownExplanationDialog = false;

  /// Cached results from the last permission check.
  static bool _lastLocationResult = false;
  static bool _lastNotificationResult = false;

  /// Requests all required permissions at startup.
  ///
  /// Returns a [PermissionRequestResult] with detailed per-permission status.
  ///
  /// IMPORTANT: Only requests permissions that are NOT already granted.
  /// Does NOT request `locationAlways` at startup — that permission on
  /// Android 10+ triggers a redirect to the system Settings app.
  ///
  /// On Android 14+, if the system returns `permanentlyDenied` on the
  /// FIRST request, this is flagged in the result so the caller can
  /// show an explanation dialog.
  static Future<PermissionRequestResult> requestAll() async {
    // Guard: only request once per session to prevent the loop.
    if (_hasRequestedThisSession) {
      dev.log('[PermissionService] Already requested this session — checking cached state');
      final verified = await verifyGranted();
      return PermissionRequestResult(
        allCriticalGranted: verified,
        locationGranted: _lastLocationResult, // ADD this
      );
    }
    _hasRequestedThisSession = true;

    // ── Step 1: Check what's already granted ────────────────────────
    final locationStatus = await Permission.location.status;
    final notificationStatus = await Permission.notification.status;
    final bleScanStatus = await Permission.bluetoothScan.status;
    final bleConnectStatus = await Permission.bluetoothConnect.status;

    dev.log('[PermissionService] Pre-check: '
        'location=$locationStatus, notification=$notificationStatus, '
        'bleScan=$bleScanStatus, bleConnect=$bleConnectStatus');

    // ── Step 2: Detect permanently denied BEFORE requesting ─────────
    // On Android 14+, the system can auto-deny permissions. If a
    // permission is already permanently denied, calling .request()
    // is a no-op — it won't show a dialog. We need to detect this
    // and guide the user to Settings instead.
    bool locationPermDenied = locationStatus.isPermanentlyDenied;
    bool notificationPermDenied = notificationStatus.isPermanentlyDenied;

    // ── Step 3: Only request what's missing and requestable ──────────
    final toRequest = <Permission>[];

    if (!locationStatus.isGranted && !locationPermDenied) {
      toRequest.add(Permission.location);
    }
    if (!notificationStatus.isGranted && !notificationPermDenied) {
      toRequest.add(Permission.notification);
    }
    if (!bleScanStatus.isGranted && !bleScanStatus.isPermanentlyDenied) {
      toRequest.add(Permission.bluetoothScan);
    }
    if (!bleConnectStatus.isGranted && !bleConnectStatus.isPermanentlyDenied) {
      toRequest.add(Permission.bluetoothConnect);
    }

    // NOTE: We deliberately skip locationAlways and
    // ignoreBatteryOptimizations at startup. These trigger
    // system-level redirects that break the UX flow.

    if (toRequest.isNotEmpty) {
      dev.log('[PermissionService] Requesting: ${toRequest.map((p) => p.toString()).join(', ')}');
      final results = await toRequest.request();

      // Check if the system returned permanentlyDenied AFTER requesting.
      // This happens on Android 14+ when user taps "Don't allow" or
      // when the system auto-denies.
      if (results[Permission.location]?.isPermanentlyDenied == true) {
        locationPermDenied = true;
      }
      if (results[Permission.notification]?.isPermanentlyDenied == true) {
        notificationPermDenied = true;
      }
    } else {
      dev.log('[PermissionService] All permissions already granted or permanently denied');
    }

    // ── Step 4: Build result ────────────────────────────────────────
    final verified = await verifyGranted();

    // Build a summary of what's missing.
    String? summary;
    if (!verified) {
      final missing = <String>[];
      if (!_lastLocationResult) {
        missing.add(locationPermDenied
            ? 'Location (permanently denied — enable in Settings)'
            : 'Location');
      }
      if (!_lastNotificationResult) {
        missing.add(notificationPermDenied
            ? 'Notifications (permanently denied — enable in Settings)'
            : 'Notifications');
      }
      summary = 'Missing permissions: ${missing.join(', ')}';
      dev.log('[PermissionService] $summary');
    }

    return PermissionRequestResult(
      allCriticalGranted: verified,
      locationPermanentlyDenied: locationPermDenied,
      notificationPermanentlyDenied: notificationPermDenied,
      locationGranted: _lastLocationResult, // ADD
      summary: summary,
    );
  }

  /// Verifies current permission state without requesting anything.
  /// Safe to call on every app resume.
  static Future<bool> verifyGranted() async {
    _lastLocationResult = await Permission.location.isGranted;
    _lastNotificationResult = await Permission.notification.isGranted;

    dev.log('[PermissionService] Verify: location=$_lastLocationResult, '
        'notification=$_lastNotificationResult');
    return _lastLocationResult && _lastNotificationResult;
  }

  /// Returns the cached location permission result (no async call).
  static bool get isLocationCached => _lastLocationResult;

  /// Checks if location permission is currently granted.
  static Future<bool> isLocationGranted() async {
    _lastLocationResult = await Permission.location.isGranted;
    return _lastLocationResult;
  }

  /// Checks if Bluetooth scan + connect permissions are granted.
  static Future<bool> isBluetoothGranted() async {
    final scan = await Permission.bluetoothScan.isGranted;
    final connect = await Permission.bluetoothConnect.isGranted;
    return scan && connect;
  }

  /// Requests Bluetooth-specific permissions. Returns true if granted.
  static Future<bool> requestBluetooth() async {
    final statuses = await [
      Permission.bluetoothScan,
      Permission.bluetoothConnect,
    ].request();

    final scanGranted = statuses[Permission.bluetoothScan]?.isGranted ?? false;
    final connectGranted = statuses[Permission.bluetoothConnect]?.isGranted ?? false;
    return scanGranted && connectGranted;
  }

  /// Requests location permission only. Returns true if granted.
  static Future<bool> requestLocation() async {
    // Check first — avoid re-requesting if already granted.
    if (await Permission.location.isGranted) return true;

    final status = await Permission.location.request();
    _lastLocationResult = status.isGranted;
    return _lastLocationResult;
  }

  // ---------------------------------------------------------------------------
  // Explanation Dialog (for permanently denied permissions)
  // ---------------------------------------------------------------------------

  /// Shows a one-time explanation dialog when critical permissions are
  /// permanently denied on Android 14+.
  ///
  /// The dialog explains why the permission is needed and offers an
  /// "Open Settings" button. Only shown ONCE per app session.
  static Future<void> showExplanationDialog(
    BuildContext context, {
    required bool locationDenied,
    required bool notificationDenied,
  }) async {
    // Guard: show only once per session.
    if (_hasShownExplanationDialog) return;
    _hasShownExplanationDialog = true;

    final reasons = <String>[];
    if (locationDenied) {
      reasons.add('• Location — required for accident detection and emergency GPS');
    }
    if (notificationDenied) {
      reasons.add('• Notifications — required for emergency alerts');
    }

    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        icon: const Icon(Icons.lock_outline_rounded, size: 32),
        title: const Text('Permissions Required'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'CrashGuard needs the following permissions to protect you:',
            ),
            const SizedBox(height: 12),
            ...reasons.map((r) => Padding(
                  padding: const EdgeInsets.only(bottom: 4),
                  child: Text(r, style: const TextStyle(fontSize: 13)),
                )),
            const SizedBox(height: 12),
            const Text(
              'These were denied by your system. Please enable them manually in Settings.',
              style: TextStyle(fontSize: 12, color: Colors.grey),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Skip for now'),
          ),
          FilledButton.icon(
            onPressed: () {
              Navigator.pop(ctx);
              openAppSettings();
            },
            icon: const Icon(Icons.settings_rounded, size: 18),
            label: const Text('Open Settings'),
          ),
        ],
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // BLE Readiness Check (Bluetooth ON + Permissions)
  // ---------------------------------------------------------------------------

  /// Ensures Bluetooth adapter is ON and permissions are granted.
  ///
  /// Returns a [BleReadyResult] describing the outcome.
  /// If Bluetooth is off, requests the system to turn it on.
  static Future<BleReadyResult> ensureBleReady() async {
    // 1. Check & request BLE permissions
    final blePermsGranted = await isBluetoothGranted();
    if (!blePermsGranted) {
      final granted = await requestBluetooth();
      if (!granted) {
        return const BleReadyResult(
          ready: false,
          reason: 'Bluetooth permissions are required to scan for devices.',
        );
      }
    }

    // 2. Check & request Location permission (required for BLE scanning on Android)
    final locationGranted = await isLocationGranted();
    if (!locationGranted) {
      final granted = await requestLocation();
      if (!granted) {
        return const BleReadyResult(
          ready: false,
          reason: 'Location permission is required for Bluetooth scanning on Android.',
        );
      }
    }

    // 3. Check if Bluetooth adapter is ON
    final adapterState = await FlutterBluePlus.adapterState.first;
    if (adapterState != BluetoothAdapterState.on) {
      // Request the system to turn Bluetooth on
      try {
        await FlutterBluePlus.turnOn();
        // Wait briefly and re-check
        await Future.delayed(const Duration(seconds: 2));
        final newState = await FlutterBluePlus.adapterState.first;
        if (newState != BluetoothAdapterState.on) {
          return const BleReadyResult(
            ready: false,
            reason: 'Bluetooth must be turned on to scan for devices.',
          );
        }
      } catch (e) {
        dev.log('[PermissionService] turnOn error: $e');
        return const BleReadyResult(
          ready: false,
          reason: 'Please enable Bluetooth manually from your device settings.',
        );
      }
    }

    return const BleReadyResult(ready: true);
  }
}

/// Result of a BLE readiness check.
class BleReadyResult {
  final bool ready;
  final String? reason;
  const BleReadyResult({required this.ready, this.reason});
}
