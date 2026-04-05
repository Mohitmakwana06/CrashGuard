/// CrashGuard — Device info model.
///
/// Represents a paired ESP32 device with its current status
/// as stored in Firebase Realtime Database.
library;

/// Data structure for `devices/{deviceId}` and `users/{userId}`.
class DeviceInfo {
  /// Unique device identifier (e.g. "ESP32_001").
  final String deviceId;

  /// Human-readable device name (e.g. "Accident_Device_01").
  final String deviceName;

  /// Firebase user ID that owns this device.
  final String userId;

  /// Whether the device is currently online (WiFi connected).
  final bool isOnline;

  /// Last time the device was seen online.
  final DateTime? lastSeen;

  /// Timestamp when the device was paired with the user.
  final DateTime? pairedAt;

  const DeviceInfo({
    required this.deviceId,
    required this.deviceName,
    required this.userId,
    this.isOnline = false,
    this.lastSeen,
    this.pairedAt,
  });

  /// Parses from a Firebase snapshot map.
  factory DeviceInfo.fromDeviceMap(String deviceId, Map<dynamic, dynamic> map) {
    return DeviceInfo(
      deviceId: deviceId,
      deviceName: (map['deviceName'] as String?) ?? deviceId,
      userId: (map['userId'] as String?) ?? '',
      isOnline: (map['status'] as String?) == 'online',
      lastSeen: _parseTimestamp(map['lastSeen']),
      pairedAt: _parseTimestamp(map['pairedAt']),
    );
  }

  /// Parses from the user's profile map.
  factory DeviceInfo.fromUserMap(String userId, Map<dynamic, dynamic> map) {
    return DeviceInfo(
      deviceId: (map['deviceId'] as String?) ?? '',
      deviceName: (map['deviceName'] as String?) ?? '',
      userId: userId,
      isOnline: false, // Resolved separately from devices/ path
      pairedAt: _parseTimestamp(map['pairedAt']),
    );
  }

  static DateTime? _parseTimestamp(dynamic value) {
    if (value == null) return null;
    if (value is int) return DateTime.fromMillisecondsSinceEpoch(value);
    if (value is String) return DateTime.tryParse(value);
    return null;
  }

  /// Converts to a map for writing to `users/{userId}`.
  Map<String, dynamic> toUserMap() => {
        'deviceId': deviceId,
        'deviceName': deviceName,
        'pairedAt': DateTime.now().millisecondsSinceEpoch,
      };

  /// Converts to a map for writing to `devices/{deviceId}`.
  Map<String, dynamic> toDeviceMap() => {
        'userId': userId,
        'deviceName': deviceName,
        'status': isOnline ? 'online' : 'offline',
        'lastSeen': DateTime.now().millisecondsSinceEpoch,
      };

  @override
  String toString() =>
      'DeviceInfo(id: $deviceId, name: $deviceName, online: $isOnline)';
}
