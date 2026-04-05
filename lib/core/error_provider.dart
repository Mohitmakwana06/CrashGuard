/// CrashGuard — Centralized error state management.
///
/// Provides app-wide error tracking via Riverpod. Each error has a
/// source, severity, and timestamp. The UI reads from these providers
/// to display banners, snackbars, or log entries.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Severity levels for app errors.
enum ErrorSeverity { info, warning, error }

/// A single error/status entry.
class AppError {
  final String message;
  final String source;
  final ErrorSeverity severity;
  final DateTime timestamp;

  const AppError({
    required this.message,
    required this.source,
    this.severity = ErrorSeverity.error,
    required this.timestamp,
  });

  @override
  String toString() => '[$source] $message';
}

/// The most recent error — displayed as a banner/snackbar in the UI.
/// Set to `null` to dismiss.
final lastErrorProvider = StateProvider<AppError?>((ref) => null);

/// Rolling list of the last 20 errors for debugging.
final errorHistoryProvider =
    StateNotifierProvider<ErrorHistoryNotifier, List<AppError>>(
  (ref) => ErrorHistoryNotifier(),
);

/// Manages a bounded list of recent errors.
class ErrorHistoryNotifier extends StateNotifier<List<AppError>> {
  ErrorHistoryNotifier() : super([]);

  static const _maxEntries = 20;

  void add(AppError error) {
    state = [error, ...state].take(_maxEntries).toList();
  }

  void clear() {
    state = [];
  }
}

/// Reports an error to the global Riverpod error state.
///
/// Call from anywhere (including static services) by passing the
/// global [ProviderContainer] created in `main.dart`.
void reportAppError(
  ProviderContainer container, {
  required String message,
  required String source,
  ErrorSeverity severity = ErrorSeverity.error,
}) {
  final error = AppError(
    message: message,
    source: source,
    severity: severity,
    timestamp: DateTime.now(),
  );
  container.read(lastErrorProvider.notifier).state = error;
  container.read(errorHistoryProvider.notifier).add(error);
}
