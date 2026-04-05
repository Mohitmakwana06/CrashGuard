/// CrashGuard — Alert state provider (Riverpod).
///
/// Tracks the countdown seconds remaining during an active alert.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/constants.dart';

/// Holds the countdown seconds remaining.
final alertCountdownProvider = StateProvider<int>(
  (ref) => kAlertTimeoutSeconds,
);
