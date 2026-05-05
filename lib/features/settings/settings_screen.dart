/// CrashGuard — Settings screen.
///
/// Provides device management (reset, reconfigure WiFi), emergency contacts
/// navigation, theme toggle (light/dark/system), account info, and
/// sign-out functionality.
///
/// UI POLISH v2:
///   - Added dark/light/system theme toggle using themeModeProvider
///   - Minor spacing, consistency cleanup
library;

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/app_theme.dart';
import '../../core/env_config.dart';
import '../../core/theme_provider.dart';
import '../../services/auth_service.dart';
import '../../services/device_service.dart';
import '../../services/firebase_service.dart';
import '../../services/sms_service.dart';
import '../ble/ble_provider.dart';
import '../ble/ble_scan_screen.dart';
import '../contacts/contacts_screen.dart';

/// Settings screen with device, contacts, theme, and account management.
class SettingsScreen extends ConsumerStatefulWidget {
  const SettingsScreen({super.key});

  @override
  ConsumerState<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends ConsumerState<SettingsScreen> {
  bool _isResetting = false;

  Future<void> _resetDevice() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Reset Device'),
        content: const Text(
          'This will unpair your ESP32 device. You will need to scan '
          'and pair it again.\n\nAre you sure?',
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
            child: const Text('Reset'),
          ),
        ],
      ),
    );

    if (confirmed != true || !mounted) return;

    setState(() => _isResetting = true);

    final userId = FirebaseAuth.instance.currentUser?.uid;
    final deviceId = ref.read(pairedDeviceIdProvider);

    if (userId != null && deviceId != null) {
      await DeviceService.unlinkDevice(userId: userId, deviceId: deviceId);
    }
    await EnvConfig.clearDeviceInfo();
    await FirebaseService.stopListening();

    ref.read(isDevicePairedProvider.notifier).state = false;
    ref.read(pairedDeviceIdProvider.notifier).state = null;
    ref.read(pairedDeviceNameProvider.notifier).state = null;
    ref.read(deviceOnlineProvider.notifier).state = false;

    if (mounted) {
      setState(() => _isResetting = false);
      Navigator.of(context).pushAndRemoveUntil(
        MaterialPageRoute(builder: (_) => const BleScanScreen()),
        (route) => route.isFirst,
      );
    }
  }

  Future<void> _reconfigureWifi() async {
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => const BleScanScreen()),
    );
  }

  Future<void> _signOut() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Sign Out'),
        content: const Text('You will need to sign in again to use the app.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Sign Out'),
          ),
        ],
      ),
    );

    if (confirmed != true) return;
    await FirebaseService.stopListening();
    await DeviceService.stopListening();
    await AuthService.signOut();
  }

  Future<void> _showTestSmsDialog(BuildContext context) async {
    final phoneController = TextEditingController();
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Test SMS (Step 7)'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('Enter a verified phone number:'),
            const SizedBox(height: 8),
            TextField(
              controller: phoneController,
              keyboardType: TextInputType.phone,
              decoration: const InputDecoration(
                hintText: '+919876543210',
                prefixIcon: Icon(Icons.phone_rounded),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(
            onPressed: () async {
              final to = phoneController.text.trim();
              Navigator.pop(ctx);
              if (to.isNotEmpty) {
                ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Sending Test SMS... check console logs.')));
                final result = await SmsService.sendTestSms(to: to);
                if (mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: Text(result.success ? 'Test SMS Sent!' : 'Failed: ${result.error}'),
                      duration: const Duration(seconds: 4),
                    ),
                  );
                }
              }
            },
            child: const Text('Send'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final user = FirebaseAuth.instance.currentUser;
    final deviceName = ref.watch(pairedDeviceNameProvider);
    final deviceId = ref.watch(pairedDeviceIdProvider);
    final isOnline = ref.watch(deviceOnlineProvider);
    final isPaired = ref.watch(isDevicePairedProvider);
    final themeMode = ref.watch(themeModeProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Settings'),
      ),
      body: ListView(
        padding: const EdgeInsets.symmetric(vertical: 8),
        children: [
          // ── Device Section ──────────────────────────────────────
          _SectionHeader(title: 'Device', icon: Icons.memory_rounded),

          if (isPaired) ...[
            Card(
              margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Row(
                  children: [
                    Container(
                      width: 48,
                      height: 48,
                      decoration: BoxDecoration(
                        color: (isOnline ? kSafeColor : kAlertColor)
                            .withValues(alpha: 0.15),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Icon(
                        Icons.memory_rounded,
                        color: isOnline ? kSafeColor : kAlertColor,
                      ),
                    ),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            deviceName ?? 'Unknown Device',
                            style: textTheme.titleSmall?.copyWith(
                              fontWeight: FontWeight.w600,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          const SizedBox(height: 2),
                          Text(
                            deviceId ?? '',
                            style: textTheme.bodySmall?.copyWith(
                              color: colorScheme.onSurfaceVariant,
                              fontSize: 11,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ],
                      ),
                    ),
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 10, vertical: 4),
                      decoration: BoxDecoration(
                        color: (isOnline ? kSafeColor : kAlertColor)
                            .withValues(alpha: 0.15),
                        borderRadius: BorderRadius.circular(20),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Container(
                            width: 8,
                            height: 8,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              color: isOnline ? kSafeColor : kAlertColor,
                            ),
                          ),
                          const SizedBox(width: 6),
                          Text(
                            isOnline ? 'Online' : 'Offline',
                            style: textTheme.labelSmall?.copyWith(
                              color: isOnline ? kSafeColor : kAlertColor,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 4),

            _SettingsTile(
              icon: Icons.wifi_rounded,
              title: 'Reconfigure WiFi',
              subtitle: 'Change WiFi credentials via BLE',
              onTap: _reconfigureWifi,
            ),
            _SettingsTile(
              icon: Icons.link_off_rounded,
              title: 'Reset Device',
              subtitle: 'Unpair and scan for a new device',
              onTap: _isResetting ? null : _resetDevice,
              trailing: _isResetting
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : null,
              isDestructive: true,
            ),
          ] else ...[
            _SettingsTile(
              icon: Icons.bluetooth_searching_rounded,
              title: 'Pair Device',
              subtitle: 'Scan and connect an ESP32 device',
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const BleScanScreen()),
              ),
            ),
          ],

          const SizedBox(height: 8),

          // ── Emergency Contacts Section ──────────────────────────
          _SectionHeader(
              title: 'Emergency Contacts', icon: Icons.contacts_rounded),

          _SettingsTile(
            icon: Icons.person_add_rounded,
            title: 'Manage Contacts',
            subtitle: 'Add, edit, or remove emergency contacts',
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const ContactsScreen()),
            ),
          ),
          _SettingsTile(
            icon: Icons.bug_report_rounded,
            title: 'Test SMS Pipeline (Step 7)',
            subtitle: 'Manually trigger Twilio API to verify network/config',
            onTap: () => _showTestSmsDialog(context),
          ),

          const SizedBox(height: 8),

          // ── Appearance Section ─────────────────────────────────
          _SectionHeader(
              title: 'Appearance', icon: Icons.palette_rounded),

          Card(
            margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(Icons.brightness_6_rounded,
                          size: 22, color: colorScheme.onSurface),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'Theme',
                              style: TextStyle(
                                color: colorScheme.onSurface,
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              'Choose light, dark, or system default',
                              style: textTheme.bodySmall?.copyWith(
                                color: colorScheme.onSurfaceVariant,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  SizedBox(
                    width: double.infinity,
                    child: SegmentedButton<ThemeMode>(
                      segments: const [
                        ButtonSegment(
                          value: ThemeMode.light,
                          icon: Icon(Icons.light_mode_rounded, size: 18),
                          label: Text('Light'),
                        ),
                        ButtonSegment(
                          value: ThemeMode.dark,
                          icon: Icon(Icons.dark_mode_rounded, size: 18),
                          label: Text('Dark'),
                        ),
                        ButtonSegment(
                          value: ThemeMode.system,
                          icon: Icon(Icons.settings_brightness_rounded, size: 18),
                          label: Text('System'),
                        ),
                      ],
                      selected: {themeMode},
                      onSelectionChanged: (selection) {
                        ref.read(themeModeProvider.notifier).state =
                            selection.first;
                      },
                      style: SegmentedButton.styleFrom(
                        visualDensity: VisualDensity.compact,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),

          const SizedBox(height: 8),

          // ── Account Section ─────────────────────────────────────
          _SectionHeader(title: 'Account', icon: Icons.person_rounded),

          Card(
            margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
            child: ListTile(
              leading: CircleAvatar(
                backgroundColor: colorScheme.primaryContainer,
                child: Icon(Icons.email_rounded,
                    color: colorScheme.onPrimaryContainer, size: 20),
              ),
              title: Text(
                user?.email ?? 'Not signed in',
                style: textTheme.bodyMedium,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              subtitle: Text(
                'User ID: ${user?.uid.substring(0, 8) ?? 'N/A'}...',
                style: textTheme.bodySmall?.copyWith(
                  color: colorScheme.onSurfaceVariant,
                  fontSize: 11,
                ),
              ),
            ),
          ),

          _SettingsTile(
            icon: Icons.logout_rounded,
            title: 'Sign Out',
            subtitle: 'Sign out of your account',
            onTap: _signOut,
            isDestructive: true,
          ),

          const SizedBox(height: 16),

          // ── App Info ────────────────────────────────────────────
          Center(
            child: Text(
              'CrashGuard v1.0.0',
              style: textTheme.bodySmall?.copyWith(
                color: colorScheme.onSurfaceVariant.withValues(alpha: 0.5),
              ),
            ),
          ),
          const SizedBox(height: 24),
        ],
      ),
    );
  }
}

// ─── Section Header ───────────────────────────────────────────────────────────

class _SectionHeader extends StatelessWidget {
  final String title;
  final IconData icon;

  const _SectionHeader({required this.title, required this.icon});

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 4),
      child: Row(
        children: [
          Icon(icon, size: 16, color: colorScheme.primary),
          const SizedBox(width: 8),
          Text(
            title,
            style: Theme.of(context).textTheme.labelLarge?.copyWith(
                  color: colorScheme.primary,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0.3,
                ),
          ),
        ],
      ),
    );
  }
}

// ─── Settings Tile ────────────────────────────────────────────────────────────

class _SettingsTile extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback? onTap;
  final Widget? trailing;
  final bool isDestructive;

  const _SettingsTile({
    required this.icon,
    required this.title,
    required this.subtitle,
    this.onTap,
    this.trailing,
    this.isDestructive = false,
  });

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final color = isDestructive ? colorScheme.error : colorScheme.onSurface;

    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      child: ListTile(
        leading: Icon(icon, color: color, size: 22),
        title: Text(
          title,
          style: TextStyle(
            color: color,
            fontWeight: FontWeight.w500,
          ),
        ),
        subtitle: Text(
          subtitle,
          style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: colorScheme.onSurfaceVariant,
              ),
        ),
        trailing: trailing ??
            Icon(Icons.chevron_right_rounded,
                color: colorScheme.onSurfaceVariant),
        onTap: onTap,
      ),
    );
  }
}
