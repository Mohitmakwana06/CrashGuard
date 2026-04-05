/// CrashGuard — Accident detection providers (Riverpod).
///
/// Manages the app-wide accident detection state, Firebase connection
/// status, and last event tracking.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../models/accident_event.dart';

/// Possible states of the detection system.
enum AccidentStatus {
  /// Normal — no accident detected.
  safe,

  /// An accident was detected; alert popup is showing.
  alertActive,

  /// Countdown expired; SMS is being sent.
  sending,

  /// SMS was sent successfully.
  sent,
}

/// Simple state provider for accident status.
final accidentStatusProvider = StateProvider<AccidentStatus>(
  (ref) => AccidentStatus.safe,
);

/// Tracks the last received accident event for home-screen display.
final lastAccidentEventProvider = StateProvider<AccidentEvent?>(
  (ref) => null,
);

/// Firebase RTDB connection state (true = connected to cloud).
final firebaseConnectedProvider = StateProvider<bool>(
  (ref) => false,
);
