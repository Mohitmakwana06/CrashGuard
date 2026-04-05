/// CrashGuard — Accident event model.
///
/// Represents a single accident event received from Firebase
/// Realtime Database, written by the ESP32 device.
///
/// Path: `accidents/{device_id}/{timestamp}`
library;

/// Data structure matching the ESP32 -> Firebase payload.
class AccidentEvent {
  /// The Firebase auto-generated push ID key.
  final String id;

  /// Status string: "ACCIDENT", "HANDLED", or "SAFE".
  final String status;

  /// GPS latitude from the ESP32 sensor / module.
  final double latitude;

  /// GPS longitude from the ESP32 sensor / module.
  final double longitude;

  /// ISO-8601 timestamp string from the ESP32.
  final String timestamp;

  /// Unique identifier for the ESP32 device.
  final String deviceId;

  const AccidentEvent({
    required this.id,
    required this.status,
    required this.latitude,
    required this.longitude,
    required this.timestamp,
    required this.deviceId,
  });

  /// Parses a Firebase snapshot [map] into an [AccidentEvent].
  /// [key] is the Firebase Database `.push().key` string.
  /// Returns `null` if the data is invalid or incomplete.
  factory AccidentEvent.fromMap(Map<dynamic, dynamic> map, {String key = ''}) {
    return AccidentEvent(
      id: key.isNotEmpty ? key : (map['timestamp'] as String? ?? ''),
      status: (map['status'] as String?)?.toUpperCase() ?? '',
      latitude: _toDouble(map['latitude']),
      longitude: _toDouble(map['longitude']),
      timestamp: (map['timestamp'] as String?) ?? '',
      deviceId: (map['device_id'] as String?) ?? '',
    );
  }

  /// Tries to safely parse a dynamic value to double.
  static double _toDouble(dynamic value) {
    if (value is double) return value;
    if (value is int) return value.toDouble();
    if (value is String) return double.tryParse(value) ?? 0.0;
    return 0.0;
  }

  /// Returns `true` if this event represents a valid accident trigger.
  bool get isAccident => status == 'ACCIDENT';

  /// Builds a Google Maps link from the coordinates.
  String get googleMapsLink =>
      'https://maps.google.com/?q=$latitude,$longitude';

  /// Returns `true` if the coordinates are the hardcoded Delhi test values
  /// written by the ESP32 firmware (28.6139, 77.209).
  bool get isHardcodedTestLocation =>
      latitude == 28.6139 && longitude == 77.209;

  /// Returns `true` if the coordinates are valid (non-zero AND not the
  /// hardcoded Delhi test coordinates from the ESP32 firmware).
  ///
  /// FIX: Changed from `||` to `&&`, and added Delhi test rejection.
  bool get hasValidLocation =>
      latitude != 0.0 &&
      longitude != 0.0 &&
      !isHardcodedTestLocation;

  /// Converts to a map for writing back to Firebase.
  Map<String, dynamic> toMap() => {
        'status': status,
        'latitude': latitude,
        'longitude': longitude,
        'timestamp': timestamp,
        'device_id': deviceId,
      };

  @override
  String toString() =>
      'AccidentEvent(id: $id, status: $status, lat: $latitude, lng: $longitude, '
      'ts: $timestamp, device: $deviceId)';
}
