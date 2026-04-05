/// CrashGuard — BLE pairing & WiFi provisioning screen.
///
/// Connects to a selected ESP32 device via BLE, collects WiFi credentials
/// from the user, sends them to the device, and waits for a response.
/// On success, links the device in Firebase and navigates to the dashboard.
///
/// PRODUCTION-GRADE v2 — Key improvements:
///   1. Calls BleService.fullReset() at the start of every attempt
///   2. "Try Again" button on every failure state
///   3. Dedicated UI panels for every provisioning state
///   4. WiFi-awaiting panel with 30s countdown
///   5. Verifying panel with heartbeat countdown
///   6. Parses "OK:{device_name}" response for correct device ID
///   7. Properly cancels operations in dispose()
///   8. Real-time BLE message stream display
library;

import 'dart:async';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/app_theme.dart';
import '../../core/env_config.dart';
import '../../services/ble_service.dart';
import '../../services/device_service.dart';
import 'ble_provider.dart';

/// WiFi provisioning + BLE pairing screen.
class BlePairingScreen extends ConsumerStatefulWidget {
  final BluetoothDevice device;

  const BlePairingScreen({super.key, required this.device});

  @override
  ConsumerState<BlePairingScreen> createState() => _BlePairingScreenState();
}

class _BlePairingScreenState extends ConsumerState<BlePairingScreen>
    with SingleTickerProviderStateMixin {
  final _ssidController = TextEditingController();
  final _passwordController = TextEditingController();
  final _formKey = GlobalKey<FormState>();
  bool _obscurePassword = true;
  bool _isProvisioning = false;
  String? _errorMessage;
  BleProvisioningState _state = BleProvisioningState.idle;

  StreamSubscription<BleProvisioningState>? _stateSub;
  StreamSubscription<String>? _messageSub;
  String? _lastBleMessage;

  /// Whether an active provisioning future is running (to avoid double-tap).
  bool _provisioningInProgress = false;

  late final AnimationController _pulseController;
  late final Animation<double> _pulseAnimation;

  @override
  void initState() {
    super.initState();
    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1200),
    )..repeat(reverse: true);
    _pulseAnimation = Tween<double>(begin: 0.9, end: 1.1).animate(
      CurvedAnimation(parent: _pulseController, curve: Curves.easeInOut),
    );

    // Listen to provisioning state changes.
    _stateSub = BleService.stateStream.listen((state) {
      if (mounted) {
        setState(() => _state = state);
      }
    });

    // Listen to BLE message stream for real-time status text.
    _messageSub = BleService.messageStream.listen((msg) {
      if (mounted) {
        setState(() => _lastBleMessage = msg);
      }
    });
  }

  @override
  void dispose() {
    _pulseController.dispose();
    _ssidController.dispose();
    _passwordController.dispose();
    _stateSub?.cancel();
    _messageSub?.cancel();

    // Clean up BLE state when screen is popped
    // (don't await — we're in dispose)
    BleService.disconnect();

    super.dispose();
  }

  // ---------------------------------------------------------------------------
  // Provisioning
  // ---------------------------------------------------------------------------

  Future<void> _startProvisioning() async {
    if (_provisioningInProgress) return;
    if (!_formKey.currentState!.validate()) return;

    final userId = FirebaseAuth.instance.currentUser?.uid;
    if (userId == null) {
      setState(() => _errorMessage = 'You must be signed in');
      return;
    }

    _provisioningInProgress = true;

    setState(() {
      _isProvisioning = true;
      _errorMessage = null;
      _lastBleMessage = null;
    });

    // ── CRITICAL: Full reset before every attempt ──
    await BleService.fullReset();

    final result = await BleService.provisionDevice(
      device: widget.device,
      ssid: _ssidController.text.trim(),
      password: _passwordController.text,
      userId: userId,
    );

    _provisioningInProgress = false;

    if (!mounted) return;

    if (result.success) {
      await _handleSuccess(result, userId);
    } else {
      setState(() {
        _isProvisioning = false;
        _errorMessage = result.error ?? 'Provisioning failed';
      });
      await BleService.disconnect();
    }
  }

  Future<void> _handleSuccess(BleProvisioningResult result, String userId) async {
    // Determine device ID and name from the response
    final deviceName = result.deviceName ?? widget.device.platformName;
    final deviceId = result.deviceName ??
        (widget.device.platformName.isNotEmpty
            ? widget.device.platformName
            : widget.device.remoteId.str);

    // Save to SharedPreferences via EnvConfig
    try {
      await EnvConfig.setLinkedDeviceId(deviceId);
      await EnvConfig.setLinkedDeviceName(deviceName);
      await EnvConfig.setDevicePaired(true);
    } catch (e) {
      debugPrint('[Pairing] EnvConfig save failed: $e');
    }

    // Link device in Firebase
    try {
      await DeviceService.linkDevice(
        userId: userId,
        deviceId: deviceId,
        deviceName: deviceName,
      );
    } catch (e) {
      debugPrint('[Pairing] Firebase linkDevice failed: $e');
    }

    // Update Riverpod providers
    ref.read(isDevicePairedProvider.notifier).state = true;
    ref.read(pairedDeviceIdProvider.notifier).state = deviceId;
    ref.read(pairedDeviceNameProvider.notifier).state = deviceName;

    // Disconnect BLE
    try {
      await BleService.disconnect();
    } catch (_) {}

    // Navigate to home
    if (mounted) {
      Navigator.of(context).popUntil((route) => route.isFirst);
    }
  }

  /// Resets everything and restarts from the form.
  Future<void> _tryAgain() async {
    await BleService.fullReset();
    if (mounted) {
      setState(() {
        _isProvisioning = false;
        _errorMessage = null;
        _lastBleMessage = null;
        _state = BleProvisioningState.idle;
        _provisioningInProgress = false;
      });
    }
  }

  // ---------------------------------------------------------------------------
  // State → UI Helpers
  // ---------------------------------------------------------------------------

  String _stateLabel(BleProvisioningState state) {
    return switch (state) {
      BleProvisioningState.idle => 'Ready to pair',
      BleProvisioningState.scanning => 'Scanning for CrashGuard device...',
      BleProvisioningState.connecting => 'Connecting to device...',
      BleProvisioningState.discoveringServices => 'Discovering services...',
      BleProvisioningState.checkingCompatibility => 'Checking compatibility...',
      BleProvisioningState.sendingCredentials => 'Sending WiFi credentials...',
      BleProvisioningState.waitingForResponse => 'Waiting for device...',
      BleProvisioningState.provisionedAwaitingWifi => 'Device connecting to WiFi, please wait...',
      BleProvisioningState.verifying => 'Verifying connection...',
      BleProvisioningState.success => 'Pairing complete! Device is online.',
      BleProvisioningState.failed => 'Connection failed',
    };
  }

  IconData _stateIcon(BleProvisioningState state) {
    return switch (state) {
      BleProvisioningState.idle => Icons.bluetooth_rounded,
      BleProvisioningState.scanning => Icons.bluetooth_searching_rounded,
      BleProvisioningState.connecting => Icons.bluetooth_connected_rounded,
      BleProvisioningState.discoveringServices => Icons.manage_search_rounded,
      BleProvisioningState.checkingCompatibility => Icons.fact_check_rounded,
      BleProvisioningState.sendingCredentials => Icons.send_rounded,
      BleProvisioningState.waitingForResponse => Icons.hourglass_top_rounded,
      BleProvisioningState.provisionedAwaitingWifi => Icons.wifi_rounded,
      BleProvisioningState.verifying => Icons.cloud_sync_rounded,
      BleProvisioningState.success => Icons.check_circle_rounded,
      BleProvisioningState.failed => Icons.error_rounded,
    };
  }

  Color _stateColor(BleProvisioningState state) {
    return switch (state) {
      BleProvisioningState.success => kSafeColor,
      BleProvisioningState.provisionedAwaitingWifi => Colors.orange,
      BleProvisioningState.verifying => Colors.orange,
      BleProvisioningState.failed => kAlertColor,
      _ => Theme.of(context).colorScheme.primary,
    };
  }

  int _stateStep(BleProvisioningState state) {
    return switch (state) {
      BleProvisioningState.idle => 0,
      BleProvisioningState.scanning => 0,
      BleProvisioningState.connecting => 1,
      BleProvisioningState.discoveringServices => 1,
      BleProvisioningState.checkingCompatibility => 1,
      BleProvisioningState.sendingCredentials => 2,
      BleProvisioningState.waitingForResponse => 3,
      BleProvisioningState.provisionedAwaitingWifi => 3,
      BleProvisioningState.verifying => 4,
      BleProvisioningState.success => 5,
      BleProvisioningState.failed => -1,
    };
  }

  // ---------------------------------------------------------------------------
  // Build
  // ---------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final deviceName = widget.device.platformName;
    final isAwaitingWifi = _state == BleProvisioningState.provisionedAwaitingWifi;
    final isVerifying = _state == BleProvisioningState.verifying;
    final isFailed = _state == BleProvisioningState.failed;
    final isActiveProgress = _isProvisioning &&
        !isAwaitingWifi &&
        !isVerifying &&
        !isFailed &&
        _state != BleProvisioningState.success;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Pair Device'),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_rounded),
          onPressed: () async {
            // Clean up before navigating away
            await BleService.fullReset();
            if (context.mounted) {
              Navigator.of(context).pop();
            }
          },
        ),
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 24),
          child: Column(
            children: [
              // ── Device Info & Status Icon ────────────────────────
              ScaleTransition(
                scale: _isProvisioning
                    ? _pulseAnimation
                    : const AlwaysStoppedAnimation(1.0),
                child: Container(
                  width: 80,
                  height: 80,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: _stateColor(_state).withValues(alpha: 0.15),
                    border: Border.all(
                      color: _stateColor(_state),
                      width: 2.5,
                    ),
                  ),
                  child: Icon(
                    _stateIcon(_state),
                    size: 36,
                    color: _stateColor(_state),
                  ),
                ),
              ),
              const SizedBox(height: 16),

              Text(
                deviceName,
                style: textTheme.titleLarge?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 4),
              AnimatedSwitcher(
                duration: const Duration(milliseconds: 300),
                child: Text(
                  _stateLabel(_state),
                  key: ValueKey(_state),
                  style: textTheme.bodyMedium?.copyWith(
                    color: _stateColor(_state),
                    fontWeight: FontWeight.w500,
                  ),
                  textAlign: TextAlign.center,
                ),
              ),
              const SizedBox(height: 20),

              // ── Step Indicator ───────────────────────────────────
              if (_isProvisioning) ...[
                _StepIndicator(currentStep: _stateStep(_state)),
                const SizedBox(height: 24),
              ],

              // ── Error Banner + Try Again ─────────────────────────
              if (_errorMessage != null) ...[
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    color: colorScheme.errorContainer,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Icon(Icons.error_outline_rounded,
                              size: 20, color: colorScheme.error),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              _errorMessage!,
                              style: textTheme.bodySmall?.copyWith(
                                color: colorScheme.onErrorContainer,
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      SizedBox(
                        width: double.infinity,
                        child: FilledButton.icon(
                          onPressed: _tryAgain,
                          icon: const Icon(Icons.refresh_rounded, size: 18),
                          label: const Text('Try Again'),
                          style: FilledButton.styleFrom(
                            backgroundColor: colorScheme.error,
                            foregroundColor: colorScheme.onError,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 16),
              ],

              // ── WiFi Credentials Form ───────────────────────────
              if (!_isProvisioning || isFailed) ...[
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(20),
                    child: Form(
                      key: _formKey,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Icon(Icons.wifi_rounded,
                                  size: 20, color: colorScheme.primary),
                              const SizedBox(width: 8),
                              Text(
                                'WiFi Configuration',
                                style: textTheme.titleSmall?.copyWith(
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 16),

                          TextFormField(
                            controller: _ssidController,
                            decoration: InputDecoration(
                              labelText: 'WiFi Network Name (SSID)',
                              prefixIcon:
                                  const Icon(Icons.router_rounded, size: 20),
                              border: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(14),
                              ),
                            ),
                            textInputAction: TextInputAction.next,
                            validator: (v) {
                              if (v == null || v.trim().isEmpty) {
                                return 'WiFi name is required';
                              }
                              return null;
                            },
                          ),
                          const SizedBox(height: 14),

                          TextFormField(
                            controller: _passwordController,
                            decoration: InputDecoration(
                              labelText: 'WiFi Password',
                              prefixIcon: const Icon(
                                  Icons.lock_outline_rounded,
                                  size: 20),
                              suffixIcon: IconButton(
                                icon: Icon(
                                  _obscurePassword
                                      ? Icons.visibility_off_outlined
                                      : Icons.visibility_outlined,
                                  size: 20,
                                ),
                                onPressed: () => setState(
                                    () => _obscurePassword = !_obscurePassword),
                              ),
                              border: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(14),
                              ),
                            ),
                            obscureText: _obscurePassword,
                            textInputAction: TextInputAction.done,
                            onFieldSubmitted: (_) => _startProvisioning(),
                            validator: (v) {
                              if (v == null || v.isEmpty) {
                                return 'WiFi password is required';
                              }
                              return null;
                            },
                          ),
                          const SizedBox(height: 6),
                          Text(
                            'Your ESP32 will use these credentials to connect '
                            'to WiFi and communicate with Firebase.',
                            style: textTheme.bodySmall?.copyWith(
                              color: colorScheme.onSurfaceVariant,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 20),

                // ── Connect Button ────────────────────────────────
                SizedBox(
                  width: double.infinity,
                  height: 52,
                  child: FilledButton.icon(
                    onPressed: _provisioningInProgress
                        ? null
                        : _startProvisioning,
                    icon: const Icon(Icons.link_rounded),
                    label: Text(isFailed ? 'Retry' : 'Connect & Configure'),
                  ),
                ),
              ],

              // ── WiFi Awaiting Panel ─────────────────────────────
              if (isAwaitingWifi || isVerifying) ...[
                const SizedBox(height: 24),
                _WifiVerifyPanel(
                  message: _lastBleMessage,
                  isVerifying: isVerifying,
                ),
              ],

              // ── Provisioning Progress (other active states) ─────
              if (isActiveProgress) ...[
                const SizedBox(height: 24),
                const CircularProgressIndicator(),
                const SizedBox(height: 16),
                if (_lastBleMessage != null) ...[
                  Text(
                    _lastBleMessage!,
                    style: textTheme.bodySmall?.copyWith(
                      color: colorScheme.onSurfaceVariant,
                      fontStyle: FontStyle.italic,
                    ),
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 8),
                ],
                Text(
                  'Keep the app open and stay near your device.',
                  style: textTheme.bodySmall?.copyWith(
                    color: colorScheme.onSurfaceVariant,
                  ),
                  textAlign: TextAlign.center,
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

// ─── WiFi Verify Panel ────────────────────────────────────────────────────────

/// Dedicated panel shown during `provisionedAwaitingWifi` and `verifying` states.
///
/// Shows:
///   - WiFi icon with subtle glow
///   - Explanatory text for the user
///   - 30-second animated countdown bar
///   - Real-time message from BLE service (e.g. "24s remaining")
class _WifiVerifyPanel extends StatefulWidget {
  final String? message;
  final bool isVerifying;

  const _WifiVerifyPanel({
    this.message,
    this.isVerifying = false,
  });

  @override
  State<_WifiVerifyPanel> createState() => _WifiVerifyPanelState();
}

class _WifiVerifyPanelState extends State<_WifiVerifyPanel>
    with SingleTickerProviderStateMixin {
  late final AnimationController _progressController;

  @override
  void initState() {
    super.initState();
    _progressController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 30),
    )..forward();
  }

  @override
  void dispose() {
    _progressController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;

    return Card(
      elevation: 2,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          children: [
            // Icon
            Container(
              width: 64,
              height: 64,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: Colors.orange.withValues(alpha: 0.12),
              ),
              child: Icon(
                widget.isVerifying
                    ? Icons.cloud_sync_rounded
                    : Icons.wifi_rounded,
                size: 32,
                color: Colors.orange,
              ),
            ),
            const SizedBox(height: 16),

            Text(
              widget.isVerifying
                  ? 'Verifying Connection…'
                  : 'Connecting to WiFi…',
              style: textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 8),

            Text(
              widget.isVerifying
                  ? 'Waiting for your device to send its first heartbeat to Firebase.'
                  : 'Credentials sent successfully! Your device is now '
                      'switching from Bluetooth to WiFi. This is normal.',
              style: textTheme.bodySmall?.copyWith(
                color: colorScheme.onSurfaceVariant,
              ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 20),

            // Animated progress bar (30 seconds)
            AnimatedBuilder(
              animation: _progressController,
              builder: (context, _) {
                final remaining =
                    30 - (30 * _progressController.value).round();
                return Column(
                  children: [
                    ClipRRect(
                      borderRadius: BorderRadius.circular(4),
                      child: LinearProgressIndicator(
                        value: _progressController.value,
                        minHeight: 6,
                        backgroundColor: colorScheme.surfaceContainerHighest,
                        valueColor: AlwaysStoppedAnimation<Color>(
                          _progressController.value > 0.8
                              ? Colors.red.shade400
                              : Colors.orange,
                        ),
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      widget.message ??
                          'Waiting for device heartbeat (${remaining}s remaining)...',
                      style: textTheme.bodySmall?.copyWith(
                        color: colorScheme.onSurfaceVariant,
                        fontFeatures: const [FontFeature.tabularFigures()],
                      ),
                      textAlign: TextAlign.center,
                    ),
                  ],
                );
              },
            ),
          ],
        ),
      ),
    );
  }
}

// ─── Step Indicator ───────────────────────────────────────────────────────────

class _StepIndicator extends StatelessWidget {
  final int currentStep;

  const _StepIndicator({required this.currentStep});

  static const _labels = [
    'Connect',
    'Discover',
    'Send',
    'Verify',
    'Done',
  ];

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: List.generate(_labels.length, (i) {
        final isActive = currentStep >= i + 1;
        final isCurrent = currentStep == i + 1;
        final color = currentStep == -1
            ? kAlertColor
            : isActive
                ? kSafeColor
                : isCurrent
                    ? colorScheme.primary
                    : colorScheme.outline.withValues(alpha: 0.3);

        return Row(
          children: [
            Column(
              children: [
                Container(
                  width: 26,
                  height: 26,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: isActive ? color : color.withValues(alpha: 0.15),
                    border: Border.all(color: color, width: 1.5),
                  ),
                  child: isActive
                      ? const Icon(Icons.check_rounded,
                          size: 14, color: Colors.white)
                      : Center(
                          child: Text(
                            '${i + 1}',
                            style: TextStyle(
                              fontSize: 11,
                              fontWeight: FontWeight.w600,
                              color: color,
                            ),
                          ),
                        ),
                ),
                const SizedBox(height: 4),
                Text(
                  _labels[i],
                  style: TextStyle(
                    fontSize: 9,
                    color: isActive ? color : colorScheme.onSurfaceVariant,
                    fontWeight: isActive ? FontWeight.w600 : FontWeight.normal,
                  ),
                ),
              ],
            ),
            if (i < _labels.length - 1)
              Container(
                width: 18,
                height: 2,
                margin: const EdgeInsets.only(bottom: 16),
                color: isActive
                    ? color
                    : colorScheme.outline.withValues(alpha: 0.2),
              ),
          ],
        );
      }),
    );
  }
}
