/// CrashGuard — Reusable error banner widget.
///
/// Reads from [lastErrorProvider] and displays a Material banner
/// at the top of the screen. Color-coded by severity:
///   - info (blue) — auto-dismisses after 3s
///   - warning (orange) — stays until dismissed
///   - error (red) — stays until dismissed
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/error_provider.dart';

/// A banner that automatically reads from [lastErrorProvider] and
/// slides in/out when errors are emitted.
class ErrorBanner extends ConsumerStatefulWidget {
  const ErrorBanner({super.key});

  @override
  ConsumerState<ErrorBanner> createState() => _ErrorBannerState();
}

class _ErrorBannerState extends ConsumerState<ErrorBanner>
    with SingleTickerProviderStateMixin {
  Timer? _autoDismissTimer;

  late final AnimationController _slideController;
  late final Animation<Offset> _slideAnimation;

  @override
  void initState() {
    super.initState();
    _slideController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 300),
    );
    _slideAnimation = Tween<Offset>(
      begin: const Offset(0, -1),
      end: Offset.zero,
    ).animate(CurvedAnimation(
      parent: _slideController,
      curve: Curves.easeOutCubic,
    ));
  }

  @override
  void dispose() {
    _autoDismissTimer?.cancel();
    _slideController.dispose();
    super.dispose();
  }

  void _dismiss() {
    _autoDismissTimer?.cancel();
    _slideController.reverse().then((_) {
      if (mounted) {
        ref.read(lastErrorProvider.notifier).state = null;
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final error = ref.watch(lastErrorProvider);

    if (error != null) {
      _slideController.forward();

      // Auto-dismiss info messages after 3 seconds.
      _autoDismissTimer?.cancel();
      if (error.severity == ErrorSeverity.info) {
        _autoDismissTimer = Timer(const Duration(seconds: 3), _dismiss);
      }
    } else {
      _slideController.reverse();
      return const SizedBox.shrink();
    }

    final (color, icon) = switch (error.severity) {
      ErrorSeverity.info => (
          Colors.blue.shade700,
          Icons.info_outline_rounded,
        ),
      ErrorSeverity.warning => (
          Colors.orange.shade700,
          Icons.warning_amber_rounded,
        ),
      ErrorSeverity.error => (
          Colors.red.shade700,
          Icons.error_outline_rounded,
        ),
    };

    return SlideTransition(
      position: _slideAnimation,
      child: Material(
        elevation: 4,
        color: color.withValues(alpha: 0.95),
        child: SafeArea(
          bottom: false,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
            child: Row(
              children: [
                Icon(icon, color: Colors.white, size: 20),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        error.source,
                        style: const TextStyle(
                          color: Colors.white70,
                          fontSize: 10,
                          fontWeight: FontWeight.w600,
                          letterSpacing: 0.5,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        error.message,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 13,
                          fontWeight: FontWeight.w500,
                        ),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                GestureDetector(
                  onTap: _dismiss,
                  child: const Icon(
                    Icons.close_rounded,
                    color: Colors.white70,
                    size: 18,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
