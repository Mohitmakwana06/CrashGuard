/// CrashGuard — Monitoring session state providers (Riverpod).
///
/// Manages the state of active monitoring sessions:
///   - Whether monitoring is currently running
///   - When the session started (for timer calculation)
///   - Duration provider for computed elapsed time
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Whether accident detection monitoring is currently active.
///
/// True = service is running, notification is visible, monitoring is live.
/// False = service is stopped, no notification, not monitoring.
final isMonitoringProvider = StateProvider<bool>(
  (ref) => false,
);

/// The timestamp when the current monitoring session started.
///
/// Used to calculate elapsed time for the session timer.
/// Set to current time when monitoring starts.
/// Cleared to null when monitoring stops.
final monitoringStartTimeProvider = StateProvider<DateTime?>(
  (ref) => null,
);

/// Computed duration of the current monitoring session.
///
/// Returns Duration(0) if monitoring is not active.
/// Otherwise calculates elapsed time from monitoringStartTimeProvider to now.
final monitoringDurationProvider = Provider<Duration>((ref) {
  final isMonitoring = ref.watch(isMonitoringProvider);
  final startTime = ref.watch(monitoringStartTimeProvider);

  if (!isMonitoring || startTime == null) {
    return Duration.zero;
  }

  return DateTime.now().difference(startTime);
});
