/// CrashGuard — Alarm sound service.
///
/// Plays a loud, looping alarm sound when an accident is detected.
/// Uses [audioplayers] to play a bundled WAV asset.
///
/// KEY FIXES:
///   1. Proper audio player lifecycle with null-safe disposal.
///   2. Timeout protection on play() to prevent audio thread deadlocks.
///   3. Graceful degradation if asset is missing or corrupted.
library;

import 'dart:async';
import 'dart:developer' as dev;

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/services.dart';

import '../core/constants.dart';

/// Manages the alarm audio playback.
class AlarmService {
  AlarmService._();

  static AudioPlayer? _player;

  /// Whether the alarm is currently playing.
  static bool get isPlaying => _player != null;

  /// Starts the alarm sound in a continuous loop at max volume.
  ///
  /// If the audio asset is missing or playback fails, the error is
  /// logged and the player is cleaned up. The alarm state remains
  /// consistent regardless of failure.
  static Future<void> start() async {
    // Don't start if already playing.
    if (_player != null) return;

    try {
      final player = AudioPlayer();
      _player = player;

      // Set to max volume.
      await player.setVolume(1.0);

      // Set release mode to loop so the alarm repeats.
      await player.setReleaseMode(ReleaseMode.loop);

      // Play the asset with a timeout to prevent audio thread deadlocks.
      // The replaceFirst removes the 'assets/' prefix because audioplayers
      // expects paths relative to the assets folder.
      await player
          .play(AssetSource(kAlarmSoundAsset.replaceFirst('assets/', '')))
          .timeout(
        const Duration(seconds: 5),
        onTimeout: () {
          dev.log('[AlarmService] play() timed out — asset may be missing');
        },
      );

      dev.log('[AlarmService] Alarm started');
    } on PlatformException catch (e) {
      // Specific catch for platform-level audio errors:
      // missing asset, unsupported codec, audio focus failure, etc.
      dev.log('[AlarmService] Platform audio error (asset may be missing or corrupted): $e');
      await _forceCleanup();
    } catch (e) {
      dev.log('[AlarmService] Failed to start alarm: $e');
      // Clean up on failure — ensure consistent state.
      await _forceCleanup();
    }
  }

  /// Stops the alarm sound and releases resources.
  static Future<void> stop() async {
    if (_player == null) return;

    try {
      await _player!.stop().timeout(
            const Duration(seconds: 2),
            onTimeout: () {
              dev.log('[AlarmService] stop() timed out');
            },
          );
    } catch (e) {
      dev.log('[AlarmService] Error stopping alarm: $e');
    }

    await _forceCleanup();
    dev.log('[AlarmService] Alarm stopped');
  }

  /// Force-cleans the player reference, ensuring no dangling state.
  static Future<void> _forceCleanup() async {
    try {
      await _player?.dispose();
    } catch (e) {
      dev.log('[AlarmService] dispose error: $e');
    }
    _player = null;
  }
}
