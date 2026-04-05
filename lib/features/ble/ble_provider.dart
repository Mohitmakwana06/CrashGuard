/// CrashGuard — BLE state providers (Riverpod).
///
/// Manages BLE scanning results, connection state, and
/// provisioning progress for the widget tree.
library;

import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../services/ble_service.dart';

/// Whether a BLE scan is currently active.
final bleScanningProvider = StateProvider<bool>((ref) => false);

/// Latest list of filtered BLE scan results.
final bleScanResultsProvider = StateProvider<List<ScanResult>>((ref) => []);

/// Current BLE provisioning state.
final bleProvisioningStateProvider = StateProvider<BleProvisioningState>(
  (ref) => BleProvisioningState.idle,
);

/// Error message from the last provisioning attempt.
final bleErrorProvider = StateProvider<String?>((ref) => null);

/// Whether a device is paired (loaded from SharedPreferences on startup).
final isDevicePairedProvider = StateProvider<bool>((ref) => false);

/// Name of the currently paired device.
final pairedDeviceNameProvider = StateProvider<String?>((ref) => null);

/// ID of the currently paired device.
final pairedDeviceIdProvider = StateProvider<String?>((ref) => null);

/// Whether the paired device is currently online.
final deviceOnlineProvider = StateProvider<bool>((ref) => false);
