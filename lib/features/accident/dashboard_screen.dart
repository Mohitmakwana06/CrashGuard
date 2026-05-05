/// CrashGuard — Dashboard screen.
///
/// Displays: device status (online/offline), Firebase connection status,
/// last event info, "Test Accident" button (local + Firebase),
/// emergency contacts, and navigation to settings.
///
/// UI POLISH v2:
///   - Consistent 16px horizontal padding, 24px vertical spacing
///   - Cards: elevation 2, border radius 16px
///   - Online/offline colored dot indicator
///   - Clean visual hierarchy with generous whitespace
///   - All text uses theme styles — no hardcoded colors
library;

import 'dart:async';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/app_theme.dart';
import '../../core/constants.dart';
import '../../services/auth_service.dart';
import '../../services/alert_service.dart';
import '../../services/background_service.dart';
import '../../services/firebase_service.dart';
import '../alert/alert_provider.dart';
import '../alert/alert_screen.dart';
import '../ble/ble_provider.dart';
import '../ble/ble_scan_screen.dart';
import '../contacts/contacts_provider.dart';
import '../contacts/contacts_screen.dart';
import '../settings/settings_screen.dart';
import '../../models/accident_event.dart';
import 'accident_provider.dart';
import 'monitoring_provider.dart';

/// Main dashboard of the app.
class DashboardScreen extends ConsumerStatefulWidget {
  const DashboardScreen({super.key});

  @override
  ConsumerState<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends ConsumerState<DashboardScreen>
    with SingleTickerProviderStateMixin {
  late final AnimationController _pulseController;
  late final Animation<double> _pulseAnimation;
  late Timer _sessionTimer;

  @override
  void initState() {
    super.initState();
    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1500),
    )..repeat(reverse: true);
    _pulseAnimation = Tween<double>(begin: 0.95, end: 1.05).animate(
      CurvedAnimation(parent: _pulseController, curve: Curves.easeInOut),
    );

    // Timer to update session duration every second
    _sessionTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) {
        setState(() {});
      }
    });
  }

  @override
  void dispose() {
    _pulseController.dispose();
    _sessionTimer.cancel();
    super.dispose();
  }

  /// Simulates an accident detection event via Firebase.
  Future<void> _triggerFirebaseTest() async {
    try {
      await FirebaseService.writeTestAccident();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Test accident sent to Firebase'),
            duration: Duration(seconds: 2),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Firebase write failed: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  /// Simulates a local accident (no Firebase).
  Future<void> _triggerLocalTest() async {
    ref.read(accidentStatusProvider.notifier).state =
        AccidentStatus.alertActive;
    ref.read(alertCountdownProvider.notifier).state = kAlertTimeoutSeconds;

    AlertService.onTick = (seconds) {
      if (mounted) {
        ref.read(alertCountdownProvider.notifier).state = seconds;
      }
    };
    AlertService.onTimeout = () {
      if (mounted) {
        ref.read(accidentStatusProvider.notifier).state = AccidentStatus.sent;
        Future.delayed(const Duration(seconds: 3), () {
          if (mounted) {
            ref.read(accidentStatusProvider.notifier).state =
                AccidentStatus.safe;
          }
        });
      }
    };

    await AlertService.trigger();

    if (mounted) {
      _navigateToAlert();
    }
  }

  /// Starts accident detection monitoring.
  /// Checks prerequisites and shows dialogs as needed.
  Future<void> _startDetection() async {
    final isPaired = ref.read(isDevicePairedProvider);
    
    // Check if device is paired
    if (!isPaired) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Pair your ESP32 device first'),
            duration: Duration(seconds: 3),
          ),
        );
      }
      return;
    }

    final contacts = ref.read(contactsProvider);
    
    // Check if there are emergency contacts
    if (contacts.isEmpty && mounted) {
      final shouldContinue = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('No Emergency Contacts'),
          content: const Text(
            'SMS won\'t be sent in an emergency. Continue anyway?',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Continue'),
            ),
          ],
        ),
      );
      
      if (shouldContinue != true) return;
    }

    // Start monitoring
    try {
      await BackgroundService.startDetection();
      ref.read(isMonitoringProvider.notifier).state = true;
      ref.read(monitoringStartTimeProvider.notifier).state = DateTime.now();
      
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Monitoring started'),
            duration: Duration(seconds: 2),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Failed to start monitoring: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  /// Stops accident detection monitoring.
  /// Shows confirmation dialog before stopping.
  Future<void> _stopDetection() async {
    if (!mounted) return;
    
    final shouldStop = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Stop Monitoring?'),
        content: const Text(
          'You won\'t be alerted if an accident is detected.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.error,
            ),
            child: const Text('Stop'),
          ),
        ],
      ),
    );

    if (shouldStop != true) return;

    try {
      await BackgroundService.stopDetection();
      ref.read(isMonitoringProvider.notifier).state = false;
      ref.read(monitoringStartTimeProvider.notifier).state = null;
      
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Monitoring stopped'),
            duration: Duration(seconds: 2),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Failed to stop monitoring: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  void _navigateToAlert() {
    Navigator.of(context).push(
      PageRouteBuilder(
        opaque: true,
        pageBuilder: (_, animation, secondaryAnimation) =>
            const AlertScreen(),
        transitionsBuilder: (_, animation, secondaryAnimation, child) {
          return FadeTransition(opacity: animation, child: child);
        },
        transitionDuration: const Duration(milliseconds: 300),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final status = ref.watch(accidentStatusProvider);
    final contacts = ref.watch(contactsProvider);
    final isConnected = ref.watch(firebaseConnectedProvider);
    final lastEvent = ref.watch(lastAccidentEventProvider);
    final isDeviceOnline = ref.watch(deviceOnlineProvider);
    final deviceName = ref.watch(pairedDeviceNameProvider);
    final deviceId = ref.watch(pairedDeviceIdProvider);
    final isPaired = ref.watch(isDevicePairedProvider);
    final isMonitoring = ref.watch(isMonitoringProvider);
    final monitoringDuration = ref.watch(monitoringDurationProvider);
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    final isSafe = status == AccidentStatus.safe;
    final statusColor = isSafe ? kSafeColor : kAlertColor;
    final statusText = switch (status) {
      AccidentStatus.safe => 'System Active',
      AccidentStatus.alertActive => 'Alert Active',
      AccidentStatus.sending => 'Sending SOS...',
      AccidentStatus.sent => 'SOS Sent',
    };

    // Format session duration as HH:MM:SS
    String formatDuration(Duration d) {
      final hours = d.inHours;
      final minutes = d.inMinutes % 60;
      final seconds = d.inSeconds % 60;
      return '${hours.toString().padLeft(2, '0')}:${minutes.toString().padLeft(2, '0')}:${seconds.toString().padLeft(2, '0')}';
    }

    return Scaffold(
      appBar: AppBar(
        title: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.shield_rounded, size: 24, color: colorScheme.primary),
            const SizedBox(width: 8),
            const Text('CrashGuard'),
          ],
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.settings_rounded),
            tooltip: 'Settings',
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const SettingsScreen()),
            ),
          ),
        ],
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
          child: Column(
            children: [
              // ── User Profile & Logout ───────────────────────────────
              const _UserProfileCard(),
              const SizedBox(height: 16),

              // ── Device & Cloud Status ───────────────────────────────
              if (!isPaired)
                const _UnpairedCard()
              else
                _PairedStatusCard(
                  isConnected: isConnected,
                  isOnline: isDeviceOnline,
                  deviceName: deviceName,
                  deviceId: deviceId,
                  isMonitoring: isMonitoring,
                ),
              const SizedBox(height: 32),

              // ── Start/Stop Detection Button ──────────────────────────
              if (isMonitoring)
                // STOP button (transparent with red border)
                Column(
                  children: [
                    SizedBox(
                      width: double.infinity,
                      height: 64,
                      child: FilledButton.icon(
                        onPressed: _stopDetection,
                        icon: const Icon(Icons.stop_rounded, size: 24),
                        label: const Text(
                          'Stop Detection',
                          style: TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        style: FilledButton.styleFrom(
                          backgroundColor: Colors.transparent,
                          foregroundColor: colorScheme.error,
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(16),
                            side: BorderSide(
                              color: colorScheme.error,
                              width: 2,
                            ),
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(height: 16),
                    // Session timer
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 12,
                      ),
                      decoration: BoxDecoration(
                        color: colorScheme.primaryContainer,
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Container(
                            width: 8,
                            height: 8,
                            decoration: const BoxDecoration(
                              shape: BoxShape.circle,
                              color: kSafeColor,
                            ),
                          ),
                          const SizedBox(width: 8),
                          Text(
                            'Monitoring for ${formatDuration(monitoringDuration)}',
                            style: theme.textTheme.labelMedium?.copyWith(
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                )
              else
                // START button (red filled)
                SizedBox(
                  width: double.infinity,
                  height: 64,
                  child: FilledButton.icon(
                    onPressed: _startDetection,
                    icon: const Icon(Icons.play_arrow_rounded, size: 24),
                    label: const Text(
                      'Start Detection',
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    style: FilledButton.styleFrom(
                      backgroundColor: const Color(0xFFE53935),
                      foregroundColor: Colors.white,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(16),
                      ),
                    ),
                  ),
                ),
              const SizedBox(height: 32),

              // ── Status Indicator ────────────────────────────────────
              ScaleTransition(
                scale: _pulseAnimation,
                child: Container(
                  width: 140,
                  height: 140,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: statusColor.withValues(alpha: 0.12),
                    border: Border.all(color: statusColor, width: 3),
                    boxShadow: [
                      BoxShadow(
                        color: statusColor.withValues(alpha: 0.25),
                        blurRadius: 28,
                        spreadRadius: 4,
                      ),
                    ],
                  ),
                  child: Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          isSafe
                              ? Icons.shield_rounded
                              : Icons.warning_amber_rounded,
                          size: 40,
                          color: statusColor,
                        ),
                        const SizedBox(height: 4),
                        Text(
                          statusText,
                          style: theme.textTheme.titleMedium?.copyWith(
                            color: statusColor,
                            fontWeight: FontWeight.w700,
                          ),
                          textAlign: TextAlign.center,
                        ),
                      ],
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 32),

              // ── Test Buttons (only enabled when monitoring) ─────────
              Row(
                children: [
                  Expanded(
                    child: FilledButton.icon(
                      onPressed: (isMonitoring && isSafe) ? _triggerFirebaseTest : null,
                      icon: const Icon(Icons.cloud_upload_rounded, size: 20),
                      label: const FittedBox(
                        fit: BoxFit.scaleDown,
                        child: Text('Cloud Test'),
                      ),
                      style: FilledButton.styleFrom(
                        backgroundColor: colorScheme.error,
                        foregroundColor: colorScheme.onError,
                        minimumSize: const Size(0, 52),
                        padding: const EdgeInsets.symmetric(horizontal: 8),
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: FilledButton.tonal(
                      onPressed: (isMonitoring && isSafe) ? _triggerLocalTest : null,
                      style: FilledButton.styleFrom(
                        minimumSize: const Size(0, 52),
                        padding: const EdgeInsets.symmetric(horizontal: 8),
                      ),
                      child: const FittedBox(
                        fit: BoxFit.scaleDown,
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Icon(Icons.car_crash_rounded, size: 20),
                            SizedBox(width: 8),
                            Text('Local Test'),
                          ],
                        ),
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Text(
                'Only available when monitoring is active',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: colorScheme.onSurfaceVariant,
                ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 24),

              // ── Last Event Info ─────────────────────────────────────
              if (lastEvent != null) ...[
                _LastEventCard(event: lastEvent),
                const SizedBox(height: 24),
              ],

              // ── Emergency Contacts ──────────────────────────────────
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    'Emergency Contacts',
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  TextButton.icon(
                    onPressed: () => Navigator.of(context).push(
                      MaterialPageRoute(
                        builder: (_) => const ContactsScreen(),
                      ),
                    ),
                    icon: const Icon(Icons.edit_rounded, size: 18),
                    label: const Text('Manage'),
                  ),
                ],
              ),
              const SizedBox(height: 8),

              if (contacts.isEmpty)
                Card(
                  margin: EdgeInsets.zero,
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Column(
                      children: [
                        Icon(Icons.person_add_rounded,
                            size: 48, color: colorScheme.onSurfaceVariant),
                        const SizedBox(height: 12),
                        Text(
                          'No emergency contacts yet',
                          style: theme.textTheme.titleSmall?.copyWith(
                            color: colorScheme.onSurfaceVariant,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          'Add someone who should be notified in an emergency.',
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: colorScheme.onSurfaceVariant,
                          ),
                          textAlign: TextAlign.center,
                        ),
                        const SizedBox(height: 16),
                        FilledButton.tonal(
                          onPressed: () => Navigator.of(context).push(
                            MaterialPageRoute(
                              builder: (_) => const ContactsScreen(),
                            ),
                          ),
                          child: const Text('Add Contact'),
                        ),
                      ],
                    ),
                  ),
                )
              else
                ...contacts.map(
                  (c) => Card(
                    margin: const EdgeInsets.only(bottom: 8),
                    child: ListTile(
                      leading: CircleAvatar(
                        backgroundColor: colorScheme.primaryContainer,
                        child: Text(
                          c.name.isNotEmpty ? c.name[0].toUpperCase() : '?',
                          style: TextStyle(
                            color: colorScheme.onPrimaryContainer,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                      title: Text(
                        c.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      subtitle: Text(
                        c.phone,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      trailing: Icon(Icons.chevron_right_rounded,
                          color: colorScheme.onSurfaceVariant),
                    ),
                  ),
                ),
              const SizedBox(height: 24),
            ],
          ),
        ),
      ),
    );
  }
}

// ─── Unpaired Card ────────────────────────────────────────────────────────────

class _UnpairedCard extends StatelessWidget {
  const _UnpairedCard();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return Card(
      elevation: 0,
      margin: EdgeInsets.zero,
      color: colorScheme.surfaceContainerHighest.withValues(alpha: 0.4),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(
            color: colorScheme.outlineVariant.withValues(alpha: 0.5)),
      ),
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: colorScheme.surfaceContainerHighest,
                shape: BoxShape.circle,
              ),
              child: Icon(Icons.bluetooth_disabled_rounded,
                  color: colorScheme.onSurfaceVariant),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'No Device Paired',
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    'Pair your ESP32 device to enable features.',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            FilledButton(
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const BleScanScreen()),
              ),
              style: FilledButton.styleFrom(
                visualDensity: VisualDensity.compact,
                padding: const EdgeInsets.symmetric(horizontal: 16),
                minimumSize: Size.zero,
              ),
              child: const Text('Pair Now'),
            ),
          ],
        ),
      ),
    );
  }
}

// ─── Paired Status Card ───────────────────────────────────────────────────────

class _PairedStatusCard extends StatelessWidget {
  final bool isConnected;
  final bool isOnline;
  final String? deviceName;
  final String? deviceId;
  final bool isMonitoring;

  const _PairedStatusCard({
    required this.isConnected,
    required this.isOnline,
    required this.isMonitoring,
    this.deviceName,
    this.deviceId,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    final isFullyOperational = isConnected && isOnline;
    final statusColor = isFullyOperational ? kSafeColor : Colors.orange;

    return Card(
      elevation: 0,
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(color: statusColor.withValues(alpha: 0.3)),
      ),
      color: statusColor.withValues(alpha: 0.05),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                Icon(Icons.memory_rounded, color: statusColor, size: 28),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              deviceName ?? deviceId ?? 'Unknown Device',
                              style: theme.textTheme.titleMedium?.copyWith(
                                fontWeight: FontWeight.bold,
                              ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          if (isMonitoring) ...[
                            const SizedBox(width: 8),
                            Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 8,
                                vertical: 2,
                              ),
                              decoration: BoxDecoration(
                                color: kSafeColor.withValues(alpha: 0.15),
                                borderRadius: BorderRadius.circular(6),
                              ),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Container(
                                    width: 6,
                                    height: 6,
                                    decoration: const BoxDecoration(
                                      shape: BoxShape.circle,
                                      color: kSafeColor,
                                    ),
                                  ),
                                  const SizedBox(width: 4),
                                  Text(
                                    'Live',
                                    style: theme.textTheme.labelSmall?.copyWith(
                                      color: kSafeColor,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ],
                      ),
                      const SizedBox(height: 2),
                      Text(
                        'Paired device',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(
                  child: _StatusChip(
                    icon: isConnected
                        ? Icons.cloud_done_rounded
                        : Icons.cloud_off_rounded,
                    label: isConnected ? 'Cloud Sync' : 'Cloud Offline',
                    isOk: isConnected,
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: _StatusChip(
                    icon: isOnline
                        ? Icons.wifi_rounded
                        : Icons.wifi_off_rounded,
                    label: isOnline ? 'Online' : 'Offline',
                    isOk: isOnline,
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// Colored dot + icon + label chip for status indicators.
class _StatusChip extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool isOk;

  const _StatusChip({
    required this.icon,
    required this.label,
    required this.isOk,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = isOk ? kSafeColor : Colors.orange;

    return Container(
      padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 12),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          // Colored dot indicator
          Container(
            width: 8,
            height: 8,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: color,
            ),
          ),
          const SizedBox(width: 6),
          Icon(icon, size: 16, color: color),
          const SizedBox(width: 4),
          Flexible(
            child: Text(
              label,
              style: theme.textTheme.labelSmall?.copyWith(
                color: color,
                fontWeight: FontWeight.w600,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }
}

// ─── Last Event Card ──────────────────────────────────────────────────────────

class _LastEventCard extends StatelessWidget {
  final AccidentEvent event;
  const _LastEventCard({required this.event});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    String timeAgo;
    try {
      final eventTime = DateTime.parse(event.timestamp);
      final diff = DateTime.now().toUtc().difference(eventTime);
      if (diff.inSeconds < 60) {
        timeAgo = '${diff.inSeconds}s ago';
      } else if (diff.inMinutes < 60) {
        timeAgo = '${diff.inMinutes}m ago';
      } else if (diff.inHours < 24) {
        timeAgo = '${diff.inHours}h ago';
      } else {
        timeAgo = '${diff.inDays}d ago';
      }
    } catch (_) {
      timeAgo = event.timestamp;
    }

    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.history_rounded,
                    size: 18, color: colorScheme.onSurfaceVariant),
                const SizedBox(width: 8),
                Text(
                  'Last Event',
                  style: theme.textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const Spacer(),
                Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 8, vertical: 2),
                  decoration: BoxDecoration(
                    color: event.status == kStatusHandled
                        ? kSafeColor.withValues(alpha: 0.15)
                        : kAlertColor.withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(
                    event.status,
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: event.status == kStatusHandled
                          ? kSafeColor
                          : kAlertColor,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            _infoRow(Icons.access_time_rounded, 'Time', timeAgo),
            const SizedBox(height: 6),
            _infoRow(Icons.memory_rounded, 'Device', event.deviceId),
            if (event.hasValidLocation) ...[
              const SizedBox(height: 6),
              _infoRow(
                Icons.location_on_rounded,
                'Location',
                '${event.latitude.toStringAsFixed(4)}, ${event.longitude.toStringAsFixed(4)}',
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _infoRow(IconData icon, String label, String value) {
    return Builder(builder: (context) {
      final theme = Theme.of(context);
      return Row(
        children: [
          Icon(icon, size: 14, color: theme.colorScheme.onSurfaceVariant),
          const SizedBox(width: 6),
          Text(
            '$label: ',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          Flexible(
            child: Text(
              value,
              style: theme.textTheme.bodySmall?.copyWith(
                fontWeight: FontWeight.w600,
              ),
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      );
    });
  }
}

// ─── User Profile Card ──────────────────────────────────────────────────────

class _UserProfileCard extends StatelessWidget {
  const _UserProfileCard();

  Future<void> _signOut(BuildContext context) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Sign Out'),
        content: const Text('Are you sure you want to sign out?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.error,
            ),
            child: const Text('Sign Out'),
          ),
        ],
      ),
    );

    if (confirmed == true) {
      await AuthService.signOut();
    }
  }

  @override
  Widget build(BuildContext context) {
    final user = FirebaseAuth.instance.currentUser;
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    if (user == null) return const SizedBox.shrink();

    return Card(
      elevation: 0,
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(
            color: colorScheme.outlineVariant.withValues(alpha: 0.5)),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Row(
          children: [
            CircleAvatar(
              radius: 20,
              backgroundColor: colorScheme.primaryContainer,
              backgroundImage: user.photoURL != null
                  ? NetworkImage(user.photoURL!)
                  : null,
              child: user.photoURL == null
                  ? Text(
                      user.displayName?.isNotEmpty == true
                          ? user.displayName![0].toUpperCase()
                          : 'U',
                      style: TextStyle(
                        color: colorScheme.onPrimaryContainer,
                        fontWeight: FontWeight.w600,
                      ),
                    )
                  : null,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    user.displayName ?? 'Unknown User',
                    style: theme.textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                    overflow: TextOverflow.ellipsis,
                    maxLines: 1,
                  ),
                  Text(
                    user.email ?? 'No email',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: colorScheme.onSurfaceVariant,
                      fontSize: 11,
                    ),
                    overflow: TextOverflow.ellipsis,
                    maxLines: 1,
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            TextButton.icon(
              onPressed: () => _signOut(context),
              icon: const Icon(Icons.logout_rounded, size: 18),
              label: const Text('Sign Out'),
              style: TextButton.styleFrom(
                foregroundColor: colorScheme.error,
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(8),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
