/// CrashGuard — Location service.
///
/// Uses [Geolocator] to fetch the device's current GPS position
/// and formats it as a Google Maps link.
///
/// KEY FIXES v2:
///   1. Inner timeout reduced to 8 seconds to match alert_service outer timeout.
///   2. Explicit fallback chain: getCurrentPosition -> getLastKnownPosition -> null.
///   3. All logging uses print() for flutter run visibility.
///   4. No permission requests — relies on PermissionService for that.
library;

import 'package:geolocator/geolocator.dart';

/// Provides GPS location utilities.
class LocationService {
  /// Returns the current [Position], or `null` on failure.
  ///
  /// Only CHECKS permission status — does NOT request.
  /// Permission must be granted via [PermissionService] before calling.
  ///
  /// Timeout: 8 seconds. Falls back to last known position on failure.
  static Future<Position?> getCurrentPosition() async {
    try {
      final serviceEnabled = await Geolocator.isLocationServiceEnabled();
      if (!serviceEnabled) {
        print('[Location] Location services disabled -- trying last known');
        return _getLastKnown();
      }

      final permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied ||
          permission == LocationPermission.deniedForever) {
        print('[Location] Permission not granted: $permission -- trying last known');
        // DO NOT request permission here — that's PermissionService's job.
        return _getLastKnown();
      }

      print('[Location] Getting current position (8s timeout)...');
      final position = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.high,
          timeLimit: Duration(seconds: 8),
        ),
      );
      print('[Location] Got position: ${position.latitude}, ${position.longitude}');
      return position;
    } catch (e) {
      print('[Location] getCurrentPosition error: $e -- trying last known');
      // Fall back to last known position.
      return _getLastKnown();
    }
  }

  /// Returns the last known position (cached by the OS). Fast and doesn't
  /// require active GPS, so it works even when getCurrentPosition fails.
  static Future<Position?> _getLastKnown() async {
    try {
      final position = await Geolocator.getLastKnownPosition();
      if (position != null) {
        print('[Location] Last known position: ${position.latitude}, ${position.longitude}');
      } else {
        print('[Location] No last known position available');
      }
      return position;
    } catch (e) {
      print('[Location] getLastKnownPosition error: $e');
      return null;
    }
  }

  /// Builds a Google Maps link from [position].
  ///
  /// Falls back to a readable string if [position] is null.
  static String toGoogleMapsLink(Position? position) {
    if (position == null) return 'Location unavailable';
    return 'https://maps.google.com/?q=${position.latitude},${position.longitude}';
  }
}
