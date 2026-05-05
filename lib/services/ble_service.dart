/// CrashGuard — BLE service for device scanning & WiFi provisioning.
///
/// Uses [flutter_blue_plus] to scan for devices, connect via BLE,
/// wait for stabilization, check service/characteristic compatibility safely,
/// send WiFi credentials + user ID as JSON, and verify provisioning.
///
/// PRODUCTION-GRADE v2 — Key improvements:
///   1. fullReset() — hard-resets all BLE state for clean retry
///   2. _credentialsSent flag — pre/post-send disconnect distinction
///   3. Race-based response reading — instant disconnect detection
///   4. OK:{device_name} parsing — extracts device ID from ESP32 response
///   5. 30s Firebase polling with 3s interval + message stream
///   6. Comprehensive error mapping for all ESP32 FAIL codes
library;

import 'dart:async';
import 'dart:convert';
import 'dart:developer' as dev;

import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:firebase_database/firebase_database.dart';

import '../core/constants.dart';

/// Possible states during the BLE provisioning flow.
enum BleProvisioningState {
  idle,
  scanning,
  connecting,
  discoveringServices,
  checkingCompatibility,
  sendingCredentials,
  waitingForResponse,
  provisionedAwaitingWifi,
  verifying,
  success,
  failed,
}

/// Result of a BLE provisioning attempt.
class BleProvisioningResult {
  final bool success;
  final String? error;

  /// The device name extracted from "OK:{device_name}" response.
  /// Null if the response was just "OK" or provisioning failed.
  final String? deviceName;

  const BleProvisioningResult({
    required this.success,
    this.error,
    this.deviceName,
  });
}

/// BLE scanning and WiFi provisioning service.
class BleService {
  BleService._();

  static bool _isScanning = false;
  static BluetoothDevice? _connectedDevice;

  /// Tracks whether credentials have been fully written to the characteristic.
  /// This is the KEY distinction: disconnect before send = error,
  /// disconnect after send = expected (ESP32 WiFi radio takeover).
  static bool _credentialsSent = false;

  static StreamController<BleProvisioningState> _stateController =
      StreamController<BleProvisioningState>.broadcast();

  /// Stream of user-facing error/status messages.
  static StreamController<String> _messageController =
      StreamController<String>.broadcast();

  static Stream<BleProvisioningState> get stateStream => _stateController.stream;
  static Stream<String> get messageStream => _messageController.stream;

  static BleProvisioningState _currentState = BleProvisioningState.idle;
  static BleProvisioningState get currentState => _currentState;

  static void _setState(BleProvisioningState state) {
    _currentState = state;
    if (!_stateController.isClosed) {
      _stateController.add(state);
    }
  }

  static void _emitMessage(String msg) {
    if (!_messageController.isClosed) {
      _messageController.add(msg);
    }
    dev.log('[BleService] Message: $msg');
  }

  // ---------------------------------------------------------------------------
  // Full Reset — call before EVERY new pairing attempt
  // ---------------------------------------------------------------------------

  /// Hard-resets all BLE state for a completely clean start.
  ///
  /// Must be called:
  ///   - At the START of every new provisioning attempt
  ///   - When the user taps "Try Again"
  ///   - When the provisioning screen is re-entered
  static Future<void> fullReset() async {
    dev.log('[BleService] ══════ FULL RESET ══════');

    // 1. Stop any active scan
    try {
      if (_isScanning) {
        await FlutterBluePlus.stopScan();
      }
    } catch (e) {
      dev.log('[BleService] stopScan error during reset: $e');
    }
    _isScanning = false;

    // 2. Disconnect any connected device
    try {
      if (_connectedDevice != null) {
        await _connectedDevice!.disconnect();
      }
    } catch (e) {
      dev.log('[BleService] disconnect error during reset: $e');
    }
    _connectedDevice = null;

    // 3. Reset all internal state
    _credentialsSent = false;
    _currentState = BleProvisioningState.idle;

    // 4. Recreate stream controllers if they were closed
    if (_stateController.isClosed) {
      _stateController = StreamController<BleProvisioningState>.broadcast();
    }
    if (_messageController.isClosed) {
      _messageController = StreamController<String>.broadcast();
    }

    // 5. Emit idle state
    _setState(BleProvisioningState.idle);

    dev.log('[BleService] ══════ RESET COMPLETE ══════');
  }

  // ---------------------------------------------------------------------------
  // Scanning
  // ---------------------------------------------------------------------------

  /// Starts scanning for CrashGuard BLE devices.
  static Stream<List<ScanResult>> startScan() {
    if (_isScanning) {
      FlutterBluePlus.stopScan();
    }
    _isScanning = true;
    _setState(BleProvisioningState.scanning);
    _emitMessage('Scanning for CrashGuard device...');

    FlutterBluePlus.startScan(
      timeout: kBleScanTimeout,
      androidUsesFineLocation: false,
    );

    FlutterBluePlus.isScanning.where((s) => !s).first.then((_) {
      _isScanning = false;
      if (_currentState == BleProvisioningState.scanning) {
        _setState(BleProvisioningState.idle);
      }
    });

    return FlutterBluePlus.scanResults.map((results) {
      return results.where((r) {
        final name = r.device.platformName;
        final hasService = r.advertisementData.serviceUuids.contains(Guid(kBleServiceUuid));
        // FIX: Use startsWith instead of exact match — some Android phones
        // truncate the BLE name in the advertisement packet.
        return hasService || name.startsWith('CrashGuard');
      }).toList();
    });
  }

  static Future<void> stopScan() async {
    if (_isScanning) {
      await FlutterBluePlus.stopScan();
      _isScanning = false;
    }
  }

  // ---------------------------------------------------------------------------
  // Provisioning Flow
  // ---------------------------------------------------------------------------

  /// Runs the complete provisioning flow.
  ///
  /// Call [fullReset] before this to ensure a clean start.
  static Future<BleProvisioningResult> provisionDevice({
    required BluetoothDevice device,
    required String ssid,
    required String password,
    required String userId,
  }) async {
    // Use platformName as the default device ID (matches ESP32 DEVICE_NAME).
    // This may be overridden by the "OK:{device_name}" response.
    final fallbackDeviceId = device.platformName.isNotEmpty
        ? device.platformName
        : device.remoteId.str;

    // Reset the credentials-sent flag at the start of every attempt.
    _credentialsSent = false;

    try {
      // 1. Connect
      _emitMessage('Connecting to device...');
      await _connectToDevice(device);

      // 2. Discover services
      _emitMessage('Discovering services...');
      final services = await _discoverServices(device);

      // 3. Find our characteristic
      _emitMessage('Checking compatibility...');
      final characteristic = _findCharacteristic(services);

      // 4. Send credentials
      _setState(BleProvisioningState.sendingCredentials);
      _emitMessage('Sending WiFi credentials...');
      dev.log('[BleService] Sending WiFi credentials...');
      
      final payload = jsonEncode({
        "ssid": ssid,
        "pass": password,
        "uid": userId,
      });

      // Prefer write-without-response to prevent 15s ACK timeouts.
      final bool writeNoResp = characteristic.properties.writeWithoutResponse;

      try {
        await characteristic.write(
          utf8.encode(payload),
          withoutResponse: writeNoResp,
        );
      } catch (e) {
        if (e.toString().contains('fbp-code:1') || e.toString().contains('Timeout')) {
          dev.log('[BleService] Write timed out but ESP32 likely received it. Continuing...');
          _emitMessage('Credentials sent (device processing...)');
        } else {
          rethrow;
        }
      }

      // ── Mark credentials as sent — from here, BLE disconnect = EXPECTED ──
      _credentialsSent = true;
      dev.log('[BleService] ✅ _credentialsSent = true');
      
      // Small delay for ESP32 to process JSON
      await Future.delayed(const Duration(milliseconds: 500));
      
      // 5. Read response — RACE against device disconnect
      _setState(BleProvisioningState.waitingForResponse);
      _emitMessage('Waiting for device response...');
      final response = await _readResponseWithDisconnectRace(device, characteristic);

      // 6. Process response
      return await _processResponse(response, fallbackDeviceId);

    } catch (e) {
      // ──────────────────────────────────────────────────────────────────────
      // BLE disconnect AFTER credentials sent → EXPECTED (ESP32 WiFi takeover)
      // ──────────────────────────────────────────────────────────────────────
      if (_credentialsSent && _isDisconnectError(e)) {
        _setState(BleProvisioningState.provisionedAwaitingWifi);
        _emitMessage('Credentials sent! Device is connecting to WiFi...');
        dev.log('[BleService] ✅ BLE disconnected after send — polling Firebase...');
        
        return await _verifyViaFirebase(fallbackDeviceId);
      }

      // ──────────────────────────────────────────────────────────────────────
      // BLE disconnect BEFORE credentials sent → REAL error
      // ──────────────────────────────────────────────────────────────────────
      _setState(BleProvisioningState.failed);
      
      final errText = _mapExceptionToUserMessage(e);
      _emitMessage(errText);
      dev.log('[BleService] ❌ Provisioning error (credentialsSent=$_credentialsSent): $e');
      
      return BleProvisioningResult(success: false, error: errText);
    }
  }

  // ---------------------------------------------------------------------------
  // CHANGED: New write-only method — does NOT wait for BLE notify response.
  // The pairing screen calls this, then polls Firebase directly.
  // ---------------------------------------------------------------------------

  /// Writes WiFi credentials to the ESP32 via BLE but does NOT wait for a
  /// BLE notify/read response. Returns immediately after a successful write.
  ///
  /// This is the recommended path because the ESP32 disconnects BLE before
  /// connecting to WiFi, so the notify response never arrives.
  ///
  /// The caller (pairing screen) is responsible for:
  ///   1. Disconnecting BLE after this returns
  ///   2. Polling Firebase for the device's "online" status
  static Future<BleProvisioningResult> writeCredentialsOnly({
    required BluetoothDevice device,
    required String ssid,
    required String password,
    required String userId,
  }) async {
    final fallbackDeviceId = device.platformName.isNotEmpty
        ? device.platformName
        : device.remoteId.str;

    _credentialsSent = false;

    try {
      // 1. Connect
      _emitMessage('Connecting to device...');
      await _connectToDevice(device);

      // 2. Discover services
      _emitMessage('Discovering services...');
      final services = await _discoverServices(device);

      // 3. Find our characteristic
      _emitMessage('Checking compatibility...');
      final characteristic = _findCharacteristic(services);

      // 4. Send credentials
      _setState(BleProvisioningState.sendingCredentials);
      _emitMessage('Sending WiFi credentials...');
      dev.log('[BleService] writeCredentialsOnly: Sending WiFi credentials...');

      final payload = jsonEncode({
        "ssid": ssid,
        "pass": password,
        "uid": userId,
      });

      final bool writeNoResp = characteristic.properties.writeWithoutResponse;

      try {
        await characteristic.write(
          utf8.encode(payload),
          withoutResponse: writeNoResp,
        );
      } catch (e) {
        if (e.toString().contains('fbp-code:1') ||
            e.toString().contains('Timeout')) {
          dev.log('[BleService] Write timed out but ESP32 likely received it.');
          _emitMessage('Credentials sent (device processing...)');
        } else {
          rethrow;
        }
      }

      // ── Mark credentials as sent ──
      _credentialsSent = true;
      dev.log('[BleService] ✅ writeCredentialsOnly: _credentialsSent = true');

      // CHANGED: Do NOT wait for BLE notify — return immediately.
      // The screen will disconnect BLE and start Firebase polling.
      _setState(BleProvisioningState.provisionedAwaitingWifi);
      _emitMessage('Credentials sent! Device is connecting to WiFi...');

      return BleProvisioningResult(
        success: true,
        deviceName: fallbackDeviceId,
      );
    } catch (e) {
      // If BLE disconnected AFTER credentials were sent, still treat as success
      // because the ESP32 likely received them and is switching to WiFi.
      if (_credentialsSent && _isDisconnectError(e)) {
        dev.log('[BleService] ✅ writeCredentialsOnly: BLE disconnected after '
            'send — treating as success');
        _setState(BleProvisioningState.provisionedAwaitingWifi);
        _emitMessage('Credentials sent! Device is connecting to WiFi...');
        return BleProvisioningResult(
          success: true,
          deviceName: fallbackDeviceId,
        );
      }

      // Real error — credentials were NOT sent.
      _setState(BleProvisioningState.failed);
      final errText = _mapExceptionToUserMessage(e);
      _emitMessage(errText);
      dev.log('[BleService] ❌ writeCredentialsOnly error '
          '(credentialsSent=$_credentialsSent): $e');
      return BleProvisioningResult(success: false, error: errText);
    }
  }

  /// Processes a successful BLE response string.
  static Future<BleProvisioningResult> _processResponse(
    String response,
    String fallbackDeviceId,
  ) async {
    if (response.startsWith('OK')) {
      // Parse "OK:{device_name}" format
      String? parsedDeviceName;
      if (response.contains(':')) {
        parsedDeviceName = response.substring(response.indexOf(':') + 1).trim();
        if (parsedDeviceName.isEmpty) parsedDeviceName = null;
      }
      
      final deviceId = parsedDeviceName ?? fallbackDeviceId;
      
      dev.log('[BleService] ✅ Device replied OK. DeviceName=$parsedDeviceName, '
          'DeviceId=$deviceId. Verifying via Firebase...');
      
      return await _verifyViaFirebase(deviceId, deviceName: parsedDeviceName);
    } else {
      // FAIL:xxx response
      final reason = response.replaceFirst('FAIL:', '').trim();
      _setState(BleProvisioningState.failed);
      
      final userMsg = _mapErrorToUserMessage(reason);
      _emitMessage(userMsg);
      
      dev.log('[BleService] ❌ Device reported failure: $reason');
      return BleProvisioningResult(success: false, error: userMsg);
    }
  }

  /// Verifies the device came online via Firebase polling.
  static Future<BleProvisioningResult> _verifyViaFirebase(
    String deviceId, {
    String? deviceName,
  }) async {
    _setState(BleProvisioningState.verifying);
    _emitMessage('Verifying connection...');
    
    final isOnline = await _pollFirebaseForOnline(deviceId);
    
    if (isOnline) {
      _setState(BleProvisioningState.success);
      _emitMessage('Device provisioned successfully!');
      dev.log('[BleService] ✅ Provisioning verified via Firebase');
      return BleProvisioningResult(
        success: true,
        deviceName: deviceName ?? deviceId,
      );
    } else {
      _setState(BleProvisioningState.failed);
      const errorMsg = 'Device did not connect — check WiFi password and try again.';
      _emitMessage(errorMsg);
      dev.log('[BleService] ❌ Firebase polling timed out');
      return BleProvisioningResult(
        success: false,
        error: errorMsg,
        deviceName: deviceName,
      );
    }
  }

  static Future<void> disconnect() async {
    try {
      await _connectedDevice?.disconnect();
      _connectedDevice = null;
      dev.log('[BleService] Disconnected');
    } catch (e) {
      dev.log('[BleService] Disconnect error: $e');
    }
  }

  // ---------------------------------------------------------------------------
  // Response Reading — RACES against BLE disconnect
  // ---------------------------------------------------------------------------

  /// Reads the provisioning response from the characteristic.
  ///
  /// Creates a [Completer] that completes when EITHER:
  ///   (a) A valid response ("OK…" or "FAIL:…") arrives via notification/read
  ///   (b) The device's `connectionState` emits `disconnected`
  ///
  /// This eliminates the long hang because the disconnect is detected within
  /// milliseconds via the `connectionState` stream.
  static Future<String> _readResponseWithDisconnectRace(
    BluetoothDevice device,
    BluetoothCharacteristic characteristic,
  ) async {
    final completer = Completer<String>();
    StreamSubscription<BluetoothConnectionState>? connSub;
    StreamSubscription<List<int>>? notifySub;
    Timer? readPollTimer;

    void finish(String result) {
      if (!completer.isCompleted) {
        completer.complete(result);
      }
    }

    void finishError(Object error) {
      if (!completer.isCompleted) {
        completer.completeError(error);
      }
    }

    try {
      // ── Leg 1: Watch for BLE disconnect ──────────────────────────────────
      connSub = device.connectionState.listen((state) {
        if (state == BluetoothConnectionState.disconnected) {
          dev.log('[BleService] connectionState → disconnected (race winner)');
          finishError(Exception('BLE_DISCONNECT'));
        }
      });

      // ── Leg 2: Try notification-based response ───────────────────────────
      if (characteristic.properties.notify || characteristic.properties.indicate) {
        try {
          await characteristic.setNotifyValue(true);
          notifySub = characteristic.onValueReceived.listen((value) {
            final decoded = utf8.decode(value);
            if (decoded.isNotEmpty) {
              dev.log('[BleService] Notification received: $decoded');
              finish(decoded);
            }
          });
        } catch (e) {
          if (_isDisconnectError(e)) {
            finishError(Exception('BLE_DISCONNECT'));
          } else {
            dev.log('[BleService] Notify setup error (non-fatal): $e');
          }
        }
      }

      // ── Leg 3: Periodic manual reads as fallback ─────────────────────────
      var readAttempt = 0;
      readPollTimer = Timer.periodic(const Duration(seconds: 2), (timer) async {
        readAttempt++;
        if (readAttempt > 8) {
          timer.cancel();
          dev.log('[BleService] Read polling exhausted — treating as disconnect');
          finishError(Exception('BLE_DISCONNECT'));
          return;
        }
        try {
          final val = await characteristic.read();
          final decoded = utf8.decode(val);
          if (decoded.startsWith('OK') || decoded.startsWith('FAIL')) {
            dev.log('[BleService] Manual read got: $decoded');
            timer.cancel();
            finish(decoded);
          }
        } catch (e) {
          if (_isDisconnectError(e)) {
            timer.cancel();
            finishError(Exception('BLE_DISCONNECT'));
          } else {
            dev.log('[BleService] Read attempt $readAttempt error: $e');
          }
        }
      });

      // ── Hard timeout safety net (25s) ────────────────────────────────────
      final result = await completer.future.timeout(
        const Duration(seconds: 25),
        onTimeout: () {
          dev.log('[BleService] Hard timeout (25s) reached');
          throw Exception('BLE_DISCONNECT');
        },
      );

      return result;
    } finally {
      // Clean up all subscriptions/timers
      await connSub?.cancel();
      await notifySub?.cancel();
      readPollTimer?.cancel();
      try {
        await characteristic.setNotifyValue(false);
      } catch (_) {}
    }
  }

  // ---------------------------------------------------------------------------
  // Firebase Polling — 30s with 3s interval + countdown messages
  // ---------------------------------------------------------------------------

  /// Polls the device's Firebase path every 3 seconds for up to 30 seconds.
  ///
  /// Emits countdown messages on the [messageStream] so the UI can show
  /// "Waiting for device heartbeat (Xs remaining)..."
  static Future<bool> _pollFirebaseForOnline(String deviceId) async {
    const totalSeconds = 30;
    const pollInterval = 3;
    final db = FirebaseDatabase.instance;
    final path = '$kFirebaseDevicesRoot/$deviceId';

    dev.log('[BleService] Starting Firebase poll at path: $path');

    for (var elapsed = 0; elapsed < totalSeconds; elapsed += pollInterval) {
      final remaining = totalSeconds - elapsed;
      _emitMessage('Waiting for device heartbeat (${remaining}s remaining)...');
      
      try {
        final snapshot = await db.ref(path).get();
        if (snapshot.exists && snapshot.value != null) {
          final data = Map<dynamic, dynamic>.from(snapshot.value as Map);
          final status = data['status'];
          final lastSeen = data['lastSeen'];
          dev.log('[BleService] Firebase poll: status=$status, lastSeen=$lastSeen');
          if (status == 'online') {
            return true;
          }
        }
      } catch (e) {
        dev.log('[BleService] Polling Firebase error: $e');
      }
      
      // Wait before next poll
      await Future.delayed(const Duration(seconds: pollInterval));
    }
    
    // Final check
    try {
      final snapshot = await db.ref(path).get();
      if (snapshot.exists && snapshot.value != null) {
        final data = Map<dynamic, dynamic>.from(snapshot.value as Map);
        if (data['status'] == 'online') return true;
      }
    } catch (_) {}
    
    dev.log('[BleService] Firebase polling timed out after ${totalSeconds}s');
    return false;
  }

  // ---------------------------------------------------------------------------
  // Error Mapping
  // ---------------------------------------------------------------------------

  /// Maps ESP32 FAIL error codes to user-friendly messages.
  static String _mapErrorToUserMessage(String reason) {
    final r = reason.toUpperCase();
    if (r.contains('WIFI_NOTFOUND') || r.contains('NOT_FOUND') || r.contains('SSID')) {
      return 'WiFi network not found. Check the network name and make sure you\'re in range.';
    }
    if (r.contains('WIFI_AUTH') || r.contains('AUTH')) {
      return 'Wrong WiFi password. Please check and try again.';
    }
    if (r.contains('WIFI_CONNECT_TIMEOUT')) {
      return 'Device could not reach router. Move it closer and try again.';
    }
    if (r.contains('WIFI_TIMEOUT') || r.contains('TIMEOUT')) {
      return 'Connection timed out. Move device closer to router.';
    }
    // FIX: Handle both specific and generic error codes from firmware
    if (r.contains('JSON') || r.contains('PARSE') || r.contains('INVALID')) {
      return 'Data error. Please try again.';
    }
    if (r.contains('MISSING_FIELDS')) {
      return 'Incomplete data sent to device. Please try again.';
    }
    if (reason.isNotEmpty) {
      return 'Device error: $reason';
    }
    return 'Device rejected credentials. Please verify WiFi details.';
  }

  /// Maps Flutter/BLE exceptions to user-friendly messages.
  static String _mapExceptionToUserMessage(dynamic e) {
    if (e is Exception && e.toString() == 'Exception: BLE_DISCONNECT') {  
      return 'Lost connection to device.';
    }
    final msg = e.toString().toLowerCase();
    if (msg.contains('disconnect') || msg.contains('not connected')) {
      return 'Lost connection to device. Move closer and try again.';
    }
    if (msg.contains('timeout')) {
      return 'Connection timed out. Make sure the device is powered on.';
    }
    if (msg.contains('service not found') || msg.contains('not compatible')) {
      return 'Device is not compatible with CrashGuard.';
    }
    if (msg.contains('characteristic not found')) {
      return 'Device firmware is outdated. Please update the ESP32.';
    }
    if (msg.contains('permission')) {
      return 'Bluetooth permissions are required. Please grant them in Settings.';
    }
    return e.toString().replaceAll('Exception: ', '');
  }

  // ---------------------------------------------------------------------------
  // Connection Sub-Functions
  // ---------------------------------------------------------------------------

  /// Connects to the device, flushes ghost states, sets MTU.
  static Future<void> _connectToDevice(BluetoothDevice device) async {
    _setState(BleProvisioningState.connecting);
    dev.log('[BleService] Connecting to ${device.remoteId}...');

    // Disconnect any ghost association
    try {
      await device.disconnect();
    } catch (_) {}
    // FIX: Wait for GATT resources to be fully released before reconnecting.
    // Without this delay, some Android phones get GATT error 133.
    await Future.delayed(const Duration(milliseconds: 300));

    await device.connect(
      timeout: const Duration(seconds: 15),
      autoConnect: false,
    );
    _connectedDevice = device;
    dev.log('[BleService] Connected to ${device.remoteId}');

    try {
      await device.requestMtu(512);
    } catch (e) {
      dev.log('[BleService] MTU request error (non-fatal): $e');
    }

    // Delay to ensure ESP32 readiness before service discovery
    await Future.delayed(const Duration(seconds: 1));
  }

  /// Discovers all services on the device.
  static Future<List<BluetoothService>> _discoverServices(BluetoothDevice device) async {
    _setState(BleProvisioningState.discoveringServices);
    dev.log('[BleService] Discovering services...');

    final services = await device.discoverServices();
    
    for (final service in services) {
      dev.log("  Service: ${service.uuid.str.toLowerCase()}");
      for (final char in service.characteristics) {
        dev.log("    Char: ${char.uuid.str.toLowerCase()}");
      }
    }
    
    return services;
  }

  /// Finds the CrashGuard BLE characteristic.
  static BluetoothCharacteristic _findCharacteristic(List<BluetoothService> services) {
    _setState(BleProvisioningState.checkingCompatibility);
    dev.log('[BleService] Checking compatibility...');
    
    final targetServiceUuid = kBleServiceUuid.toLowerCase();
    final targetCharUuid = kBleMainCharUuid.toLowerCase();

    BluetoothService? matchingService;
    for (final service in services) {
      if (service.uuid.str.toLowerCase() == targetServiceUuid) {
        matchingService = service;
        break;
      }
    }

    if (matchingService == null) {
      throw Exception('Device not compatible (service not found)');
    }

    BluetoothCharacteristic? matchingChar;
    for (final char in matchingService.characteristics) {
      if (char.uuid.str.toLowerCase() == targetCharUuid) {
        matchingChar = char;
        break;
      }
    }

    if (matchingChar == null) {
      throw Exception('Device not compatible (characteristic not found)');
    }

    return matchingChar;
  }

  /// Checks if an error indicates BLE disconnection.
  static bool _isDisconnectError(dynamic e) {
    if (e is Exception && e.toString() == 'Exception: BLE_DISCONNECT') return true;
    final msg = e.toString().toLowerCase();
    return msg.contains('disconnect') ||
        msg.contains('not connected') ||
        msg.contains('connection lost') ||
        msg.contains('133') || // Android GATT_ERROR
        msg.contains('fbp-code') ||
        msg.contains('timeout');
  }
}
