/// CrashGuard — Theme mode provider (Riverpod).
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Holds the current [ThemeMode]. Defaults to dark for minimal dark UI.
final themeModeProvider = StateProvider<ThemeMode>(
  (ref) => ThemeMode.dark,
);
