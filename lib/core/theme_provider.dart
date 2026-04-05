/// CrashGuard — Theme mode provider (Riverpod).
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Holds the current [ThemeMode]. Defaults to system.
final themeModeProvider = StateProvider<ThemeMode>(
  (ref) => ThemeMode.system,
);
