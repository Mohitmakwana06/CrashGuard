/// CrashGuard — BLE device scanning screen.
///
/// Displays a modern dark UI with animated scanning indicator (circular
/// ripple), list of discovered ESP32 devices filtered by name prefix,
/// signal strength, and a "Scan Again" button.
///
/// Before scanning, checks that Bluetooth is ON and all required
/// permissions are granted. If Bluetooth is off, shows the system
/// dialog to turn it on.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/app_theme.dart';
import '../../services/ble_service.dart';
import '../../services/permission_service.dart';
import 'package:permission_handler/permission_handler.dart';
import 'ble_pairing_screen.dart';
import 'ble_provider.dart';

/// BLE device discovery screen.
class BleScanScreen extends ConsumerStatefulWidget {
  const BleScanScreen({super.key});

  @override
  ConsumerState<BleScanScreen> createState() => _BleScanScreenState();
}

class _BleScanScreenState extends ConsumerState<BleScanScreen> {
  StreamSubscription<List<ScanResult>>? _scanSub;
  bool _hasStartedScan = false;

  @override
  void dispose() {
    _scanSub?.cancel();
    BleService.stopScan();
    super.dispose();
  }

  Future<void> _startScan() async {
    // ── Ensure Bluetooth is ON and permissions are granted ──
    final bleReady = await PermissionService.ensureBleReady();
    if (!bleReady.ready) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(bleReady.reason ?? 'Bluetooth is not available'),
            backgroundColor: Colors.orange.shade800,
            duration: const Duration(seconds: 4),
            action: SnackBarAction(
              label: 'SETTINGS',
              textColor: Colors.white,
              onPressed: () => openAppSettings(),
            ),
          ),
        );
      }
      return;
    }

    setState(() => _hasStartedScan = true);
    ref.read(bleScanResultsProvider.notifier).state = [];
    ref.read(bleScanningProvider.notifier).state = true;

    _scanSub?.cancel();
    _scanSub = BleService.startScan().listen((results) {
      if (mounted) {
        ref.read(bleScanResultsProvider.notifier).state = results;
      }
    });

    // Wait for scan to complete.
    await Future.delayed(const Duration(seconds: 11));
    if (mounted) {
      ref.read(bleScanningProvider.notifier).state = false;
    }
  }

  void _navigateToPairing(BluetoothDevice device) {
    BleService.stopScan();
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => BlePairingScreen(device: device),
      ),
    );
  }

  Widget _buildIntroScreen(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final textTheme = theme.textTheme;

    return Scaffold(
      appBar: AppBar(title: const Text('Pair Device')),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 32),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Container(
                width: 120,
                height: 120,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: colorScheme.primaryContainer,
                ),
                child: Icon(Icons.bluetooth_connected_rounded, size: 64, color: colorScheme.onPrimaryContainer),
              ),
              const SizedBox(height: 32),
              Text(
                'Connect Your ESP32',
                style: textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.bold),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 16),
              Text(
                'Pair your CrashGuard device to enable real-time accident detection and emergency cloud connectivity.',
                style: textTheme.bodyMedium?.copyWith(color: colorScheme.onSurfaceVariant),
                textAlign: TextAlign.center,
              ),
              const Spacer(),
              SizedBox(
                width: double.infinity,
                height: 52,
                child: FilledButton.icon(
                  onPressed: _startScan,
                  icon: const Icon(Icons.bluetooth_searching_rounded),
                  label: const Text('Pair Now'),
                ),
              ),
              const SizedBox(height: 16),
              SizedBox(
                width: double.infinity,
                height: 52,
                child: OutlinedButton(
                  onPressed: () => Navigator.of(context).maybePop(),
                  child: const Text('I\'ll Pair Later'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (!_hasStartedScan) {
      return _buildIntroScreen(context);
    }
    final isScanning = ref.watch(bleScanningProvider);
    final results = ref.watch(bleScanResultsProvider);
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Find Your Device'),
      ),
      body: SafeArea(
        child: Column(
          children: [
            const SizedBox(height: 16),

            // ── Scanning Indicator ────────────────────────────────
            SizedBox(
              height: 180,
              child: Center(
                child: Stack(
                  alignment: Alignment.center,
                  children: [
                    // Scanning indicator.
                    if (isScanning)
                      SizedBox(
                        width: 140,
                        height: 140,
                        child: CircularProgressIndicator(
                          strokeWidth: 3,
                          color: colorScheme.primary.withValues(alpha: 0.3),
                        ),
                      ),
                    // Center icon.
                    Container(
                      width: 72,
                      height: 72,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: isScanning
                            ? colorScheme.primary
                            : colorScheme.surfaceContainerHighest,
                        boxShadow: isScanning
                            ? [
                                BoxShadow(
                                  color:
                                      colorScheme.primary.withValues(alpha: 0.4),
                                  blurRadius: 16,
                                  spreadRadius: 2,
                                ),
                              ]
                            : null,
                      ),
                      child: Icon(
                        Icons.bluetooth_searching_rounded,
                        size: 32,
                        color: isScanning
                            ? Colors.white
                            : colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
            ),

            // ── Status Text ───────────────────────────────────────
            Text(
              isScanning ? 'Searching for devices…' : 'Scan complete',
              style: textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              isScanning
                  ? 'Make sure your ESP32 device is powered on'
                  : '${results.length} device${results.length == 1 ? '' : 's'} found',
              style: textTheme.bodySmall?.copyWith(
                color: colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 16),

            // ── Device List ───────────────────────────────────────
            Expanded(
              child: results.isEmpty
                  ? Center(
                      child: isScanning
                          ? const SizedBox.shrink()
                          : Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(
                                  Icons.bluetooth_disabled_rounded,
                                  size: 48,
                                  color: colorScheme.onSurfaceVariant,
                                ),
                                const SizedBox(height: 12),
                                Text(
                                  'No devices found',
                                  style: textTheme.bodyLarge?.copyWith(
                                    color: colorScheme.onSurfaceVariant,
                                  ),
                                ),
                                const SizedBox(height: 4),
                                Text(
                                  'Ensure your ESP32 is powered on\nand in pairing mode',
                                  textAlign: TextAlign.center,
                                  style: textTheme.bodySmall?.copyWith(
                                    color: colorScheme.onSurfaceVariant,
                                  ),
                                ),
                              ],
                            ),
                    )
                  : ListView.separated(
                      padding: const EdgeInsets.symmetric(horizontal: 24),
                      itemCount: results.length,
                      separatorBuilder: (_, index) => const SizedBox(height: 8),
                      itemBuilder: (context, index) {
                        final result = results[index];
                        return _DeviceCard(
                          result: result,
                          onTap: () => _navigateToPairing(result.device),
                        );
                      },
                    ),
            ),

            // ── Scan Again Button ─────────────────────────────────
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
              child: SizedBox(
                width: double.infinity,
                height: 52,
                child: FilledButton.tonal(
                  onPressed: isScanning ? null : _startScan,
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      const Icon(Icons.refresh_rounded),
                      const SizedBox(width: 8),
                      Text(isScanning ? 'Scanning...' : 'Scan Again'),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ─── Device Card ──────────────────────────────────────────────────────────────

class _DeviceCard extends StatelessWidget {
  final ScanResult result;
  final VoidCallback onTap;

  const _DeviceCard({required this.result, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final name = result.device.platformName;
    final rssi = result.rssi;
    final signalIcon = _signalIcon(rssi);

    return Card(
      margin: EdgeInsets.zero,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(16),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            children: [
              // BLE icon.
              Container(
                width: 48,
                height: 48,
                decoration: BoxDecoration(
                  color: colorScheme.primaryContainer,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Icon(
                  Icons.memory_rounded,
                  color: colorScheme.onPrimaryContainer,
                ),
              ),
              const SizedBox(width: 14),

              // Device info.
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      name,
                      style: textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      'ID: ${result.device.remoteId.str}',
                      style: textTheme.bodySmall?.copyWith(
                        color: colorScheme.onSurfaceVariant,
                        fontSize: 11,
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),

              // Signal strength.
              Column(
                children: [
                  Icon(signalIcon, size: 20, color: _signalColor(rssi)),
                  const SizedBox(height: 2),
                  Text(
                    '$rssi dBm',
                    style: textTheme.labelSmall?.copyWith(
                      color: colorScheme.onSurfaceVariant,
                      fontSize: 10,
                    ),
                  ),
                ],
              ),
              const SizedBox(width: 4),
              Icon(Icons.chevron_right_rounded,
                  color: colorScheme.onSurfaceVariant),
            ],
          ),
        ),
      ),
    );
  }

  IconData _signalIcon(int rssi) {
    if (rssi >= -60) return Icons.signal_cellular_alt_rounded;
    if (rssi >= -75) return Icons.signal_cellular_alt_2_bar_rounded;
    return Icons.signal_cellular_alt_1_bar_rounded;
  }

  Color _signalColor(int rssi) {
    if (rssi >= -60) return kSafeColor;
    if (rssi >= -75) return Colors.orange;
    return Colors.red;
  }
}
