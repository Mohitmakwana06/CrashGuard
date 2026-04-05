/// CrashGuard — Full-screen alert screen.
///
/// Overlays the entire screen with a red emergency alert:
/// - Loud alarm sound + vibration.
/// - 56px bold countdown timer, centered.
/// - Pulsing warning icon for urgency.
/// - Auto-sends SMS when countdown reaches zero.
/// - Real-time SMS status messages (sent, failed, retrying).
///
/// STATE MACHINE:
///   1. COUNTDOWN — "I'm Safe" button visible, countdown running.
///   2. TIMEOUT COMPLETE — "I'm Safe" hidden, "Emergency contacts notified"
///      message shown, "Close" button replaces it.
///
/// The transition uses AnimatedSwitcher for a smooth fade.
///
/// NOTIFICATION LAUNCH:
///   When opened from a background notification, the screen works normally
///   because main.dart triggers AlertService.trigger() before pushing this.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/app_theme.dart';
import '../../core/constants.dart';
import '../../services/alert_service.dart';
import '../accident/accident_provider.dart';
import 'alert_provider.dart';

/// Full-screen accident alert overlay.
class AlertScreen extends ConsumerStatefulWidget {
  const AlertScreen({super.key});

  @override
  ConsumerState<AlertScreen> createState() => _AlertScreenState();
}

class _AlertScreenState extends ConsumerState<AlertScreen>
    with TickerProviderStateMixin {
  late final AnimationController _flashController;
  late final AnimationController _iconPulseController;
  late final Animation<double> _iconPulseAnimation;

  /// Real-time SMS status message from AlertService.
  String? _smsStatus;

  /// Whether the countdown has expired and SMS has been sent/attempted.
  /// When true, the "I'm Safe" button is hidden and replaced with
  /// a "Close" button and completion message.
  bool _timeoutCompleted = false;

  @override
  void initState() {
    super.initState();
    print('[AlertScreen] initState() -- wiring callbacks');

    // Background flash animation.
    _flashController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 600),
    )..repeat(reverse: true);

    // Pulsing icon animation.
    _iconPulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 800),
    )..repeat(reverse: true);
    _iconPulseAnimation = Tween<double>(begin: 0.85, end: 1.15).animate(
      CurvedAnimation(parent: _iconPulseController, curve: Curves.easeInOut),
    );

    // Set up AlertService callbacks for this screen.
    AlertService.onTimeout = () {
      print('[AlertScreen] onTimeout fired -- mounted=$mounted');
      if (mounted) {
        setState(() {
          _timeoutCompleted = true;
        });
        ref.read(accidentStatusProvider.notifier).state = AccidentStatus.sent;
        // DO NOT auto-pop — let user read the completion message and tap Close.
      }
    };

    AlertService.onTick = (seconds) {
      if (mounted) {
        ref.read(alertCountdownProvider.notifier).state = seconds;
      }
    };

    AlertService.onSmsStatus = (message) {
      if (mounted) {
        setState(() => _smsStatus = message);
      }
    };
  }

  @override
  void dispose() {
    print('[AlertScreen] dispose() -- clearing UI callbacks only');
    _flashController.dispose();
    _iconPulseController.dispose();
    // CRITICAL: Clear ONLY UI callbacks to prevent setState-after-dispose.
    AlertService.onTick = null;
    AlertService.onTimeout = null;
    AlertService.onSmsStatus = null;
    super.dispose();
  }

  /// User taps "I'm Safe" — cancel everything.
  Future<void> _dismiss() async {
    print('[AlertScreen] _dismiss() -- user tapped I\'m Safe');
    try {
      await AlertService.dismiss();
    } catch (e) {
      print('[AlertScreen] Dismiss error: $e');
    }
    if (mounted) {
      ref.read(accidentStatusProvider.notifier).state = AccidentStatus.safe;
      ref.read(alertCountdownProvider.notifier).state = kAlertTimeoutSeconds;
      Navigator.of(context).pop();
    }
  }

  /// User taps "Close" after timeout completes — just pop the screen.
  void _close() {
    print('[AlertScreen] _close() -- user tapping Close after timeout');
    if (mounted) {
      ref.read(accidentStatusProvider.notifier).state = AccidentStatus.safe;
      ref.read(alertCountdownProvider.notifier).state = kAlertTimeoutSeconds;
      Navigator.of(context).pop();
    }
  }

  @override
  Widget build(BuildContext context) {
    final seconds = ref.watch(alertCountdownProvider);
    final event = AlertService.currentEvent;

    return PopScope(
      canPop: false,
      child: Scaffold(
        body: AnimatedBuilder(
          animation: _flashController,
          builder: (context, child) {
            final flashValue = _flashController.value;
            // After timeout, stop flashing — use static dark gradient
            final effectiveFlash = _timeoutCompleted ? 0.0 : flashValue;
            return Container(
              width: double.infinity,
              height: double.infinity,
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [
                    Color.lerp(
                      const Color(0xFFB91C1C),
                      const Color(0xFFDC2626),
                      effectiveFlash,
                    )!,
                    const Color(0xFF450A0A),
                  ],
                ),
              ),
              child: child,
            );
          },
          child: SafeArea(
            child: Column(
              children: [
                // ── Scrollable content area ──────────────────────────
                Expanded(
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.symmetric(horizontal: 32),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        const SizedBox(height: 40),

                        // Pulsing warning icon (stops pulsing after timeout).
                        ScaleTransition(
                          scale: _timeoutCompleted
                              ? const AlwaysStoppedAnimation(1.0)
                              : _iconPulseAnimation,
                          child: Icon(
                            _timeoutCompleted
                                ? Icons.check_circle_rounded
                                : Icons.warning_amber_rounded,
                            size: 80,
                            color: _timeoutCompleted
                                ? Colors.greenAccent
                                : Colors.white,
                          ),
                        ),
                        const SizedBox(height: 20),

                        // Title — changes after timeout.
                        AnimatedSwitcher(
                          duration: const Duration(milliseconds: 400),
                          child: Text(
                            _timeoutCompleted
                                ? 'Emergency Contacts Notified'
                                : 'Accident Detected!',
                            key: ValueKey(_timeoutCompleted ? 'done' : 'active'),
                            style: const TextStyle(
                              fontSize: 28,
                              fontWeight: FontWeight.w800,
                              color: Colors.white,
                            ),
                            textAlign: TextAlign.center,
                          ),
                        ),
                        const SizedBox(height: 12),

                        // Subtitle.
                        AnimatedSwitcher(
                          duration: const Duration(milliseconds: 400),
                          child: Text(
                            _timeoutCompleted
                                ? 'Emergency SMS has been sent to your contacts.\nHelp is on the way.'
                                : 'Emergency SMS will be sent in',
                            key: ValueKey(
                                _timeoutCompleted ? 'sub_done' : 'sub_active'),
                            style: const TextStyle(
                              fontSize: 16,
                              color: Colors.white70,
                              height: 1.4,
                            ),
                            textAlign: TextAlign.center,
                          ),
                        ),
                        const SizedBox(height: 28),

                        // ── Countdown (only shown before timeout) ──────
                        if (!_timeoutCompleted) ...[
                          // Countdown circle with 56px number.
                          SizedBox(
                            width: 140,
                            height: 140,
                            child: Stack(
                              alignment: Alignment.center,
                              children: [
                                SizedBox(
                                  width: 140,
                                  height: 140,
                                  child: CircularProgressIndicator(
                                    value: seconds.toDouble() /
                                        kAlertTimeoutSeconds.toDouble(),
                                    strokeWidth: 6,
                                    backgroundColor: Colors.white24,
                                    valueColor:
                                        const AlwaysStoppedAnimation<Color>(
                                      Colors.white,
                                    ),
                                  ),
                                ),
                                Text(
                                  '$seconds',
                                  style: const TextStyle(
                                    fontSize: 56,
                                    fontWeight: FontWeight.w800,
                                    color: Colors.white,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(height: 8),
                          const Text(
                            'seconds',
                            style:
                                TextStyle(fontSize: 14, color: Colors.white60),
                          ),
                          const SizedBox(height: 20),

                          // What happens message.
                          Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 16, vertical: 10),
                            decoration: BoxDecoration(
                              color: Colors.white.withValues(alpha: 0.1),
                              borderRadius: BorderRadius.circular(10),
                            ),
                            child: const Text(
                              'When timer reaches 0, an emergency SMS with your '
                              'GPS location will be sent to all your contacts.',
                              style: TextStyle(
                                fontSize: 13,
                                color: Colors.white70,
                                height: 1.4,
                              ),
                              textAlign: TextAlign.center,
                            ),
                          ),

                          // Location info from ESP32.
                          if (event != null && event.hasValidLocation) ...[
                            const SizedBox(height: 12),
                            Container(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 12, vertical: 6),
                              decoration: BoxDecoration(
                                color: Colors.white.withValues(alpha: 0.08),
                                borderRadius: BorderRadius.circular(8),
                              ),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  const Icon(Icons.location_on_rounded,
                                      size: 14, color: Colors.white70),
                                  const SizedBox(width: 4),
                                  Text(
                                    '${event.latitude.toStringAsFixed(4)}, '
                                    '${event.longitude.toStringAsFixed(4)}',
                                    style: const TextStyle(
                                      fontSize: 12,
                                      color: Colors.white70,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ],

                          const SizedBox(height: 16),

                          // Sound indicator.
                          Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Icon(Icons.volume_up_rounded,
                                  size: 16,
                                  color: Colors.white.withValues(alpha: 0.5)),
                              const SizedBox(width: 4),
                              Text(
                                'Alarm active',
                                style: TextStyle(
                                  fontSize: 12,
                                  color: Colors.white.withValues(alpha: 0.5),
                                ),
                              ),
                            ],
                          ),
                        ],

                        // ── SMS Status Feedback ──────────────────────
                        if (_smsStatus != null) ...[
                          const SizedBox(height: 20),
                          AnimatedSwitcher(
                            duration: const Duration(milliseconds: 300),
                            child: Container(
                              key: ValueKey(_smsStatus),
                              width: double.infinity,
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 16, vertical: 10),
                              decoration: BoxDecoration(
                                color: Colors.white.withValues(alpha: 0.12),
                                borderRadius: BorderRadius.circular(10),
                                border: Border.all(
                                  color: Colors.white.withValues(alpha: 0.2),
                                ),
                              ),
                              child: Row(
                                children: [
                                  _smsStatusIcon(_smsStatus!),
                                  const SizedBox(width: 10),
                                  Expanded(
                                    child: Text(
                                      _smsStatus!,
                                      style: const TextStyle(
                                        fontSize: 13,
                                        color: Colors.white,
                                        fontWeight: FontWeight.w500,
                                      ),
                                      maxLines: 2,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ],
                        const SizedBox(height: 24),
                      ],
                    ),
                  ),
                ),

                // ── Bottom Button Area — animated transition ──────────
                AnimatedSwitcher(
                  duration: const Duration(milliseconds: 400),
                  switchInCurve: Curves.easeOut,
                  switchOutCurve: Curves.easeIn,
                  child: _timeoutCompleted
                      ? _buildCloseButton()
                      : _buildImSafeButton(),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// Builds the "I'm Safe" button (shown during countdown).
  Widget _buildImSafeButton() {
    return Padding(
      key: const ValueKey('imsafe'),
      padding: const EdgeInsets.fromLTRB(24, 0, 24, 12),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            width: double.infinity,
            height: 56,
            child: ElevatedButton.icon(
              onPressed: _dismiss,
              icon: const Icon(Icons.check_circle_outline_rounded),
              label: const Text(
                "I'm Safe",
                style: TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w700,
                ),
              ),
              style: ElevatedButton.styleFrom(
                backgroundColor: kSafeColor,
                foregroundColor: Colors.white,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(14),
                ),
                elevation: 4,
              ),
            ),
          ),
          const SizedBox(height: 8),
          const Text(
            'Tap if this was not a real accident',
            style: TextStyle(fontSize: 13, color: Colors.white54),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 8),
        ],
      ),
    );
  }

  /// Builds the "Close" button (shown after timeout completes).
  Widget _buildCloseButton() {
    return Padding(
      key: const ValueKey('close'),
      padding: const EdgeInsets.fromLTRB(24, 0, 24, 12),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            width: double.infinity,
            height: 56,
            child: OutlinedButton.icon(
              onPressed: _close,
              icon: const Icon(Icons.close_rounded),
              label: const Text(
                'Close',
                style: TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w600,
                ),
              ),
              style: OutlinedButton.styleFrom(
                foregroundColor: Colors.white,
                side: const BorderSide(color: Colors.white54, width: 1.5),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(14),
                ),
              ),
            ),
          ),
          const SizedBox(height: 8),
          const Text(
            'Your emergency contacts have been notified',
            style: TextStyle(fontSize: 13, color: Colors.white54),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 8),
        ],
      ),
    );
  }

  /// Returns an appropriate icon for the SMS status message.
  Widget _smsStatusIcon(String status) {
    if (status.contains('sent') || status.contains('Sent')) {
      return const Icon(Icons.check_circle_rounded,
          size: 18, color: Colors.greenAccent);
    }
    if (status.contains('failed') || status.contains('Failed')) {
      return const Icon(Icons.error_rounded,
          size: 18, color: Colors.redAccent);
    }
    if (status.contains('No emergency')) {
      return const Icon(Icons.warning_rounded,
          size: 18, color: Colors.orangeAccent);
    }
    // Default: in-progress spinner
    return const SizedBox(
      width: 16,
      height: 16,
      child: CircularProgressIndicator(
        strokeWidth: 2,
        color: Colors.white70,
      ),
    );
  }
}
