/// CrashGuard — Alert orchestration service.
///
/// When an accident is detected this service:
/// 1. Starts loud alarm sound (looping).
/// 2. Starts continuous vibration.
/// 3. Shows a full-screen notification.
/// 4. Runs a countdown (default 15 s).
/// 5. If the user does NOT dismiss, fetches GPS & sends SMS.
/// 6. On dismiss, marks event as HANDLED in Firebase.
///
/// KEY FIXES v4:
///   1. Location priority REVERSED: phone GPS first, ESP32 fallback second.
///   2. Phone GPS has 8s timeout — cannot hang SMS flow.
///   3. ESP32 coords used ONLY if phone GPS fails AND coords are valid.
///   4. Delhi test coords (28.6139, 77.209) are rejected.
///   5. Detailed print() logging at every step with source attribution.
library;

import 'dart:async';

import 'package:hive/hive.dart';
import 'package:vibration/vibration.dart';

import '../core/constants.dart';
import '../models/accident_event.dart';
import '../models/contact_model.dart';
import 'alarm_service.dart';
import 'firebase_service.dart';
import 'location_service.dart';
import 'notification_service.dart';
import 'sms_service.dart';

/// Orchestrates the accident alert lifecycle.
class AlertService {
  /// Active countdown timer (null when idle).
  static Timer? _countdownTimer;

  /// Remaining seconds exposed so the UI can display a countdown.
  static int remainingSeconds = kAlertTimeoutSeconds;

  /// Whether an alert is currently active.
  static bool isActive = false;

  /// Whether SMS has already been sent for the current event.
  static bool _smsSent = false;

  /// The current accident event (from Firebase / simulator).
  static AccidentEvent? currentEvent;

  /// Callback fired every second so the UI can rebuild.
  static void Function(int secondsLeft)? onTick;

  /// Callback fired when the countdown expires (SMS sent).
  static void Function()? onTimeout;

  /// Callback for SMS status updates — lets the UI show progress.
  static void Function(String message)? onSmsStatus;

  /// Internal: fire SMS status to both console AND UI.
  static void _emitSmsStatus(String message) {
    print('[AlertService] SMS Status: $message');
    onSmsStatus?.call(message);
  }

  // ---------------------------------------------------------------------------
  // Public API
  // ---------------------------------------------------------------------------

  /// Triggers the full alert sequence.
  ///
  /// If [event] is provided (from Firebase), its coordinates are used
  /// as a FALLBACK for the emergency SMS. Phone GPS is always tried first.
  static Future<void> trigger({AccidentEvent? event}) async {
    print("ALERT TRIGGERED"); // STEP 1: Confirm Trigger Execution
    
    if (isActive) {
      print('[AlertService] Alert already active -- ignoring duplicate trigger');
      return; // Prevent double-trigger.
    }
    isActive = true;
    _smsSent = false;
    currentEvent = event;
    remainingSeconds = kAlertTimeoutSeconds;

    print('');
    print('[AlertService] ================================================');
    print('[AlertService] ALERT TRIGGERED'
        '${event != null ? ' from device ${event.deviceId}' : ' (simulated)'}');
    print('[AlertService] Countdown: ${kAlertTimeoutSeconds}s');
    print('[AlertService] _smsSent=$_smsSent isActive=$isActive');
    print('[AlertService] ================================================');

    // 1. Start alarm sound.
    try {
      await AlarmService.start();
      print('[AlertService] Alarm started');
    } catch (e) {
      print('[AlertService] Alarm start error: $e');
    }

    // 2. Vibrate continuously (pattern repeats).
    try {
      _startVibration();
      print('[AlertService] Vibration started');
    } catch (e) {
      print('[AlertService] Vibration start error: $e');
    }

    // 3. Show full-screen notification with event payload.
    try {
      String? payload;
      if (event != null) {
        payload = '{"type":"accident_alert",'
            '"key":"${event.id}",'
            '"status":"${event.status}",'
            '"latitude":${event.latitude},'
            '"longitude":${event.longitude},'
            '"timestamp":"${event.timestamp}",'
            '"device_id":"${event.deviceId}"}';
      }
      await NotificationService.showAlertNotification(payload: payload);
    } catch (e) {
      print('[AlertService] Notification error: $e');
    }

    // 4. Start countdown — MUST be the last thing so nothing blocks it.
    print('[AlertService] Starting ${kAlertTimeoutSeconds}s countdown timer...');
    _countdownTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      remainingSeconds--;
      print('[AlertService] Tick: ${remainingSeconds}s remaining');
      onTick?.call(remainingSeconds);

      if (remainingSeconds <= 0) {
        print('[AlertService] Countdown reached ZERO -- calling _handleTimeout()');
        timer.cancel();
        _countdownTimer = null;
        _handleTimeout();
      }
    });
  }

  /// User pressed "I'm Safe" — cancel everything.
  static Future<void> dismiss() async {
    print('[AlertService] User dismissed (I\'m Safe) -- _smsSent=$_smsSent isActive=$isActive');

    // Cancel timer FIRST to prevent race with _handleTimeout
    final timer = _countdownTimer;
    _countdownTimer = null;
    timer?.cancel();

    isActive = false;
    remainingSeconds = kAlertTimeoutSeconds;

    // Stop alarm sound.
    try {
      await AlarmService.stop();
    } catch (e) {
      print('[AlertService] Alarm stop error: $e');
    }

    // Stop vibration.
    try {
      await Vibration.cancel();
    } catch (e) {
      print('[AlertService] Vibration cancel error: $e');
    }

    // Cancel notification.
    try {
      await NotificationService.cancelAlertNotification();
    } catch (e) {
      print('[AlertService] Notification cancel error: $e');
    }

    // Mark event as handled in Firebase.
    if (currentEvent != null) {
      try {
        await FirebaseService.markAsHandled(currentEvent!);
      } catch (e) {
        print('[AlertService] Mark as handled error: $e');
      }
    }

    currentEvent = null;
  }

  // ---------------------------------------------------------------------------
  // Internals
  // ---------------------------------------------------------------------------

  /// Starts a repeating vibration pattern.
  static void _startVibration() {
    // Vibrate 1 s on, 0.5 s off — repeated for the full timeout.
    final pattern = <int>[];
    for (var i = 0; i < kAlertTimeoutSeconds; i++) {
      pattern.addAll([0, 1000, 500]);
    }
    Vibration.vibrate(pattern: pattern);
  }

  /// Called when the countdown reaches zero.
  static Future<void> _handleTimeout() async {
    print('');
    print('[AlertService] ================================================');
    print('[AlertService] _handleTimeout() CALLED');
    print('[AlertService] _smsSent=$_smsSent, isActive=$isActive');
    print('[AlertService] ================================================');

    // Prevent duplicate SMS.
    if (_smsSent) {
      print('[AlertService] _smsSent=true -- skipping duplicate SMS');
      return;
    }

    // Guard: if dismiss() was called right as timer fired
    if (!isActive) {
      print('[AlertService] isActive=false -- dismiss() won the race, skipping SMS');
      return;
    }

    _smsSent = true;

    print('[AlertService] Preparing emergency SMS...');
    _emitSmsStatus('Countdown expired - preparing emergency SMS...');

    // Stop alarm & vibration first (non-critical, don't let failures block SMS).
    try {
      await AlarmService.stop();
    } catch (e) {
      print('[AlertService] Alarm stop error during timeout: $e');
    }
    try {
      await Vibration.cancel();
    } catch (e) {
      print('[AlertService] Vibration cancel error during timeout: $e');
    }

    // ── STEP 1: Get location ──
    // PRIORITY: Phone GPS first -> ESP32 coords fallback -> "Location unavailable"
    String link;
    try {
      // ALWAYS try phone GPS first with 8 second timeout.
      print('[AlertService] [Location] Trying phone GPS first (8s timeout)...');
      _emitSmsStatus('Getting GPS location...');

      final position = await LocationService.getCurrentPosition().timeout(
        const Duration(seconds: 8),
        onTimeout: () {
          print('[AlertService] [Location] Phone GPS timed out after 8s');
          return null;
        },
      );

      if (position != null) {
        // Phone GPS succeeded — use it.
        link = LocationService.toGoogleMapsLink(position);
        print('[AlertService] [Location] SOURCE: Phone GPS');
        print('[AlertService] [Location] Result: $link');
      } else {
        // Phone GPS failed — try ESP32 coords as fallback.
        print('[AlertService] [Location] Phone GPS returned null, trying ESP32 fallback...');

        if (currentEvent != null && currentEvent!.hasValidLocation) {
          link = currentEvent!.googleMapsLink;
          print('[AlertService] [Location] SOURCE: ESP32 device');
          print('[AlertService] [Location] Result: $link');
        } else {
          // ESP32 coords are also invalid (0,0 or Delhi test coords).
          link = 'Location unavailable';
          if (currentEvent != null) {
            print('[AlertService] [Location] ESP32 coords rejected: '
                '${currentEvent!.latitude}, ${currentEvent!.longitude} '
                '(isHardcoded=${currentEvent!.isHardcodedTestLocation})');
          }
          print('[AlertService] [Location] SOURCE: None (unavailable)');
        }
      }
    } catch (e) {
      print('[AlertService] [Location] Error: $e -- using fallback');
      link = 'Location unavailable';
    }

    // ── STEP 2: Get contacts ──
    final phones = _getContactPhones();
    print('[AlertService] Emergency contacts found: ${phones.length}');

    if (phones.isEmpty) {
      print('');
      print('[AlertService] ================================================');
      print('[AlertService] NO EMERGENCY CONTACTS CONFIGURED!');
      print('[AlertService] SMS will NOT be sent.');
      print('[AlertService] Add contacts in: Dashboard -> Manage -> Add Contact');
      print('[AlertService] ================================================');
      _emitSmsStatus('No emergency contacts configured - please add contacts in Settings');
      _finishAlert();
      return;
    }

    for (var i = 0; i < phones.length; i++) {
      final p = phones[i];
      final masked = p.length > 4
          ? '...${p.substring(p.length - 4)}'
          : p;
      print('[AlertService] Contact ${i + 1}: $masked');
    }

    // ── STEP 3: Build SMS body ──
    final body = kEmergencyMessageTemplate.replaceAll('{location}', link);
    print('[AlertService] SMS body (${body.length} chars): '
        '${body.substring(0, body.length.clamp(0, 100))}...');

    // ── STEP 4: Send SMS ──
    try {
      _emitSmsStatus('Sending emergency SMS to ${phones.length} contact(s)...');

      print("CALLING SMS SERVICE"); // STEP 2: Confirm SMS Function Call
      final results = await SmsService.sendToAll(body: body, recipients: phones);

      int successCount = 0;
      int failCount = 0;
      for (var i = 0; i < results.length; i++) {
        final status = results[i].success ? 'SENT' : 'FAILED';
        print('[AlertService] SMS result [${i + 1}/${results.length}]: $status ${results[i].error ?? ""}');
        if (results[i].success) {
          successCount++;
        } else {
          failCount++;
        }
      }

      // Report summary to UI.
      if (failCount == 0) {
        _emitSmsStatus('Emergency SMS sent to all $successCount contact(s)');
      } else if (successCount == 0) {
        _emitSmsStatus('SMS failed for all contacts: ${results.first.error}');
      } else {
        _emitSmsStatus('SMS sent to $successCount, failed for $failCount contact(s)');
      }
    } catch (e) {
      print('[AlertService] SMS sending exception: $e');
      _emitSmsStatus('Failed to send emergency SMS: $e');
    }

    _finishAlert();
  }

  /// Cleanup after alert is complete (after SMS sent or skipped).
  static Future<void> _finishAlert() async {
    // Cancel notification.
    try {
      await NotificationService.cancelAlertNotification();
    } catch (e) {
      print('[AlertService] Notification cancel error: $e');
    }

    // Mark event as handled.
    if (currentEvent != null) {
      try {
        await FirebaseService.markAsHandled(currentEvent!);
      } catch (e) {
        print('[AlertService] Mark handled error: $e');
      }
    }

    // NOW it's safe to mark inactive (after SMS is done).
    isActive = false;
    currentEvent = null;
    print('[AlertService] Alert lifecycle complete -- isActive=false');
    onTimeout?.call();
  }

  /// Returns phone numbers from all saved emergency contacts.
  static List<String> _getContactPhones() {
    try {
      final box = Hive.box<EmergencyContact>(kContactsBoxName);
      print('[AlertService] Hive box "$kContactsBoxName": ${box.length} entries');
      final phones = box.values.map((c) => c.phone).toList();
      for (var i = 0; i < phones.length; i++) {
        final p = phones[i];
        final last4 = p.length >= 4 ? p.substring(p.length - 4) : p;
        print('[AlertService] Contact $i phone: ...$last4');
      }
      return phones;
    } catch (e) {
      print('[AlertService] Error reading contacts box: $e');
      return [];
    }
  }
}
