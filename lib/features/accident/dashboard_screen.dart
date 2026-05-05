/// CrashGuard — Dashboard screen (Production UI v3).
///
/// Compact, information-first layout with:
///   - AppBar avatar + sign-out menu (replaces full profile card)
///   - Small status chip (● Active / ● Inactive)
///   - FAB for stop detection (bottom-right, red, circular)
///   - Compact secondary test buttons
///   - Simplified device card with subtle elevation
///   - Minimal dark theme, no excessive glows
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

class _DashboardScreenState extends ConsumerState<DashboardScreen> {
  Timer? _sessionTimer;

  @override
  void initState() {
    super.initState();
    // Timer to update session duration every second (only rebuilds text)
    _sessionTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _sessionTimer?.cancel();
    // FIX: Clear static callbacks to prevent leaked closures
    // that capture stale widget state / Riverpod ref after navigation.
    AlertService.onTick = null;
    AlertService.onTimeout = null;
    AlertService.onSmsStatus = null;
    super.dispose();
  }

  // ── Actions ──────────────────────────────────────────────────────────────

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
  Future<void> _startDetection() async {
    final isPaired = ref.read(isDevicePairedProvider);

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

  /// Stops accident detection monitoring (with confirmation dialog).
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

  Future<void> _signOut() async {
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

  // ── Helpers ──────────────────────────────────────────────────────────────

  String _formatDuration(Duration d) {
    final hours = d.inHours;
    final minutes = d.inMinutes % 60;
    final seconds = d.inSeconds % 60;
    return '${hours.toString().padLeft(2, '0')}:${minutes.toString().padLeft(2, '0')}:${seconds.toString().padLeft(2, '0')}';
  }

  // ── Build ────────────────────────────────────────────────────────────────

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
    final user = FirebaseAuth.instance.currentUser;

    final isSafe = status == AccidentStatus.safe;

    return Scaffold(
      appBar: AppBar(
        leading: Padding(
          padding: const EdgeInsets.only(left: 12),
          child: Center(
            child: _buildUserAvatar(user, colorScheme, theme),
          ),
        ),
        title: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.shield_rounded, size: 22, color: colorScheme.primary),
            const SizedBox(width: 8),
            const Text('CrashGuard'),
          ],
        ),
        actions: [
          if (user != null)
            PopupMenuButton<String>(
              icon: const Icon(Icons.more_vert_rounded, size: 22),
              onSelected: (value) {
                if (value == 'signout') _signOut();
              },
              itemBuilder: (ctx) => [
                PopupMenuItem(
                  value: 'signout',
                  child: Row(
                    children: [
                      Icon(Icons.logout_rounded,
                          size: 18, color: colorScheme.error),
                      const SizedBox(width: 8),
                      Text('Sign Out',
                          style: TextStyle(color: colorScheme.error)),
                    ],
                  ),
                ),
              ],
            ),
          IconButton(
            icon: const Icon(Icons.settings_rounded, size: 22),
            tooltip: 'Settings',
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const SettingsScreen()),
            ),
          ),
        ],
      ),

      // ── FAB: Stop Detection (only when monitoring) ───────────────────────
      floatingActionButton: isMonitoring
          ? SizedBox(
              width: 52,
              height: 52,
              child: FloatingActionButton(
                onPressed: _stopDetection,
                backgroundColor: const Color(0xFFE53935),
                foregroundColor: Colors.white,
                elevation: 4,
                shape: const CircleBorder(),
                tooltip: 'Stop Detection',
                child: const Icon(Icons.stop_rounded, size: 26),
              ),
            )
          : null,
      floatingActionButtonLocation: FloatingActionButtonLocation.endFloat,

      // ── Body ─────────────────────────────────────────────────────────────
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // ── Device / Unpaired Card ──────────────────────────────────
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
              const SizedBox(height: 12),

              // ── Status Chip + Session Timer ─────────────────────────────
              _StatusRow(
                isMonitoring: isMonitoring,
                isSafe: isSafe,
                statusText: switch (status) {
                  AccidentStatus.safe =>
                    isMonitoring ? 'Active' : 'Inactive',
                  AccidentStatus.alertActive => 'Alert Active',
                  AccidentStatus.sending => 'Sending SOS',
                  AccidentStatus.sent => 'SOS Sent',
                },
                duration: isMonitoring
                    ? _formatDuration(monitoringDuration)
                    : null,
              ),
              const SizedBox(height: 16),

              // ── Start Detection (only when NOT monitoring) ──────────────
              if (!isMonitoring) ...[
                SizedBox(
                  width: double.infinity,
                  height: 48,
                  child: FilledButton.icon(
                    onPressed: _startDetection,
                    icon: const Icon(Icons.play_arrow_rounded, size: 22),
                    label: const Text(
                      'Start Detection',
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    style: FilledButton.styleFrom(
                      backgroundColor: kSafeColor,
                      foregroundColor: Colors.white,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(14),
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 16),
              ],

              // ── Test Buttons (compact, secondary) ───────────────────────
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed:
                          (isMonitoring && isSafe) ? _triggerFirebaseTest : null,
                      icon:
                          const Icon(Icons.cloud_upload_rounded, size: 18),
                      label: const FittedBox(
                        fit: BoxFit.scaleDown,
                        child: Text('Cloud Test'),
                      ),
                      style: OutlinedButton.styleFrom(
                        minimumSize: const Size(0, 40),
                        padding: const EdgeInsets.symmetric(horizontal: 8),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(10),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed:
                          (isMonitoring && isSafe) ? _triggerLocalTest : null,
                      icon: const Icon(Icons.car_crash_rounded, size: 18),
                      label: const FittedBox(
                        fit: BoxFit.scaleDown,
                        child: Text('Local Test'),
                      ),
                      style: OutlinedButton.styleFrom(
                        minimumSize: const Size(0, 40),
                        padding: const EdgeInsets.symmetric(horizontal: 8),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(10),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 16),

              // ── Last Event ──────────────────────────────────────────────
              if (lastEvent != null) ...[
                _LastEventCard(event: lastEvent),
                const SizedBox(height: 16),
              ],

              // ── Emergency Contacts ──────────────────────────────────────
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
                    icon: const Icon(Icons.edit_rounded, size: 16),
                    label: const Text('Manage'),
                    style: TextButton.styleFrom(
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                      visualDensity: VisualDensity.compact,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 6),

              if (contacts.isEmpty)
                Card(
                  margin: EdgeInsets.zero,
                  child: Padding(
                    padding: const EdgeInsets.all(20),
                    child: Column(
                      children: [
                        Icon(Icons.person_add_rounded,
                            size: 40, color: colorScheme.onSurfaceVariant),
                        const SizedBox(height: 10),
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
                        const SizedBox(height: 12),
                        FilledButton.tonal(
                          onPressed: () => Navigator.of(context).push(
                            MaterialPageRoute(
                              builder: (_) => const ContactsScreen(),
                            ),
                          ),
                          style: FilledButton.styleFrom(
                            minimumSize: const Size(0, 40),
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
                    margin: const EdgeInsets.only(bottom: 6),
                    child: ListTile(
                      dense: true,
                      leading: CircleAvatar(
                        radius: 18,
                        backgroundColor: colorScheme.primaryContainer,
                        child: Text(
                          c.name.isNotEmpty ? c.name[0].toUpperCase() : '?',
                          style: TextStyle(
                            color: colorScheme.onPrimaryContainer,
                            fontWeight: FontWeight.w600,
                            fontSize: 14,
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
                        style: theme.textTheme.bodySmall,
                      ),
                      trailing: Icon(Icons.chevron_right_rounded,
                          size: 20, color: colorScheme.onSurfaceVariant),
                    ),
                  ),
                ),
              const SizedBox(height: 16),
            ],
          ),
        ),
      ),
    );
  }

  /// Builds the small avatar for the AppBar leading slot.
  Widget _buildUserAvatar(
      User? user, ColorScheme colorScheme, ThemeData theme) {
    if (user == null) {
      return Icon(Icons.account_circle_rounded,
          size: 32, color: colorScheme.onSurfaceVariant);
    }

    return GestureDetector(
      onTap: () {
        // Show a simple bottom sheet with user info
        showModalBottomSheet(
          context: context,
          shape: const RoundedRectangleBorder(
            borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
          ),
          builder: (ctx) => Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                CircleAvatar(
                  radius: 32,
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
                            fontSize: 24,
                            color: colorScheme.onPrimaryContainer,
                            fontWeight: FontWeight.w600,
                          ),
                        )
                      : null,
                ),
                const SizedBox(height: 12),
                Text(
                  user.displayName ?? 'Unknown User',
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  user.email ?? 'No email',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: colorScheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 16),
              ],
            ),
          ),
        );
      },
      child: CircleAvatar(
        radius: 16,
        backgroundColor: colorScheme.primaryContainer,
        backgroundImage:
            user.photoURL != null ? NetworkImage(user.photoURL!) : null,
        child: user.photoURL == null
            ? Text(
                user.displayName?.isNotEmpty == true
                    ? user.displayName![0].toUpperCase()
                    : 'U',
                style: TextStyle(
                  fontSize: 13,
                  color: colorScheme.onPrimaryContainer,
                  fontWeight: FontWeight.w600,
                ),
              )
            : null,
      ),
    );
  }
}

// ─── Status Row ───────────────────────────────────────────────────────────────

/// Compact status chip + session timer row.
class _StatusRow extends StatelessWidget {
  final bool isMonitoring;
  final bool isSafe;
  final String statusText;
  final String? duration;

  const _StatusRow({
    required this.isMonitoring,
    required this.isSafe,
    required this.statusText,
    this.duration,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final statusColor = isMonitoring && isSafe
        ? kSafeColor
        : (!isSafe ? kAlertColor : theme.colorScheme.onSurfaceVariant);

    return Row(
      children: [
        // Status chip
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
          decoration: BoxDecoration(
            color: statusColor.withValues(alpha: 0.12),
            borderRadius: BorderRadius.circular(20),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 7,
                height: 7,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: statusColor,
                ),
              ),
              const SizedBox(width: 6),
              Text(
                statusText,
                style: theme.textTheme.labelMedium?.copyWith(
                  color: statusColor,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        ),

        // Session duration (when monitoring)
        if (duration != null) ...[
          const SizedBox(width: 10),
          Icon(Icons.timer_outlined,
              size: 15, color: theme.colorScheme.onSurfaceVariant),
          const SizedBox(width: 4),
          Text(
            duration!,
            style: theme.textTheme.labelMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
              fontWeight: FontWeight.w500,
              fontFeatures: [const FontFeature.tabularFigures()],
            ),
          ),
        ],
      ],
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
        borderRadius: BorderRadius.circular(14),
        side: BorderSide(
            color: colorScheme.outlineVariant.withValues(alpha: 0.5)),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: colorScheme.surfaceContainerHighest,
                shape: BoxShape.circle,
              ),
              child: Icon(Icons.bluetooth_disabled_rounded,
                  size: 22, color: colorScheme.onSurfaceVariant),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'No Device Paired',
                    style: theme.textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 2),
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
                padding: const EdgeInsets.symmetric(horizontal: 14),
                minimumSize: const Size(0, 36),
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

    return Card(
      elevation: 1,
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: BorderSide(
          color: colorScheme.outlineVariant.withValues(alpha: 0.3),
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Device name row
            Row(
              children: [
                Icon(Icons.memory_rounded,
                    color: colorScheme.primary, size: 22),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    deviceName ?? deviceId ?? 'Unknown Device',
                    style: theme.textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                // Live chip (when monitoring)
                if (isMonitoring)
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 3,
                    ),
                    decoration: BoxDecoration(
                      color: kSafeColor.withValues(alpha: 0.12),
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
            ),
            const SizedBox(height: 10),
            // Status chips row
            Row(
              children: [
                Expanded(
                  child: _MiniStatusChip(
                    icon: isConnected
                        ? Icons.cloud_done_rounded
                        : Icons.cloud_off_rounded,
                    label: isConnected ? 'Cloud Sync' : 'Cloud Offline',
                    isOk: isConnected,
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: _MiniStatusChip(
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

/// Small colored status chip for the device card.
class _MiniStatusChip extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool isOk;

  const _MiniStatusChip({
    required this.icon,
    required this.label,
    required this.isOk,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = isOk ? kSafeColor : Colors.orange;

    return Container(
      padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 10),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Container(
            width: 6,
            height: 6,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: color,
            ),
          ),
          const SizedBox(width: 5),
          Icon(icon, size: 14, color: color),
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
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.history_rounded,
                    size: 16, color: colorScheme.onSurfaceVariant),
                const SizedBox(width: 6),
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
                        ? kSafeColor.withValues(alpha: 0.12)
                        : kAlertColor.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(6),
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
            const SizedBox(height: 10),
            _infoRow(Icons.access_time_rounded, 'Time', timeAgo),
            const SizedBox(height: 4),
            _infoRow(Icons.memory_rounded, 'Device', event.deviceId),
            if (event.hasValidLocation) ...[
              const SizedBox(height: 4),
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
          Icon(icon, size: 13, color: theme.colorScheme.onSurfaceVariant),
          const SizedBox(width: 5),
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
