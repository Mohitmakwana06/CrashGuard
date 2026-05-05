/// CrashGuard — Application-wide constants.
///
/// Centralizes magic values so they can be tuned from one place.
library;

// ─── Alert Timing ────────────────────────────────────────────────────────────

/// Duration (in seconds) the alert popup waits before auto-triggering SMS.
const int kAlertTimeoutSeconds = 15;

/// Debounce window — ignore duplicate accidents within this many seconds.
/// Reduced from 30 to 10 to prevent filtering real MPU6050 events that
/// arrive shortly after a cloud test.
const int kDebounceWindowSeconds = 10;

// ─── Emergency SMS ───────────────────────────────────────────────────────────

/// Emergency SMS body template. `{location}` is replaced at send-time.
///
/// RULES:
///   - Plain ASCII only — no emojis, no unicode dashes, no special chars.
///   - Under 130 chars after {location} is substituted (Google Maps URL ~43 chars).
///   - Must contain word ACCIDENT or CRASH for urgency.
///   - 88 chars body + 43 URL = 131 total. Under 160. OK.
const String kEmergencyMessageTemplate =
    'ACCIDENT ALERT by CrashGuard. Location: {location} Please check on the rider immediately.';

/// Maximum SMS retry attempts on failure.
const int kSmsMaxRetries = 3;

/// Base delay (ms) for exponential backoff between SMS retries.
const int kSmsRetryBaseDelayMs = 2000;

// ─── Local Storage ───────────────────────────────────────────────────────────

/// Hive box name for emergency contacts.
const String kContactsBoxName = 'emergency_contacts';

// ─── Notification Channels ───────────────────────────────────────────────────

/// Notification channel details (Android).
const String kAlertChannelId = 'crash_guard_alert';
const String kAlertChannelName = 'Accident Alerts';
const String kAlertChannelDescription =
    'Full-screen alerts when an accident is detected';

/// Background service notification ID.
const int kForegroundNotificationId = 888;

/// Alert notification ID.
const int kAlertNotificationId = 999;

/// Monitoring session persistent notification ID (same as foreground service).
/// Using the same ID as the foreground service merges them into ONE notification.
const int kMonitoringNotificationId = kForegroundNotificationId;

// ─── SharedPreferences Keys (Monitoring) ────────────────────────────────────

/// Whether monitoring session is active (persisted across app launches).
const String kPrefIsMonitoringActive = 'is_monitoring_active';

/// Timestamp (milliseconds) when current monitoring session started.
const String kPrefMonitoringStartMs = 'monitoring_start_ms';

// ─── Firebase Realtime Database ──────────────────────────────────────────────

/// Root path for accident events: accidents/{device_id}/{timestamp}
const String kFirebaseAccidentsRoot = 'accidents';

/// Status values written by ESP32 / app.
const String kStatusAccident = 'ACCIDENT';
const String kStatusHandled = 'HANDLED';
const String kStatusSafe = 'SAFE';

// ─── Alarm Sound ─────────────────────────────────────────────────────────────

/// Asset path for the alarm sound.
const String kAlarmSoundAsset = 'assets/sounds/alarm.wav';

// ─── BLE Configuration ──────────────────────────────────────────────────────

/// Device name prefix used to filter BLE scan results (can be empty).
const String kBleDevicePrefix = '';

/// BLE service UUID exposed by the ESP32 provisioning server.
const String kBleServiceUuid = '12345678-1234-1234-1234-1234567890ab';

/// Single Characteristic UUID for writing WiFi credentials and reading responses.
const String kBleMainCharUuid = 'abcd1234-5678-1234-5678-abcdef123456';

/// BLE scan timeout duration.
const Duration kBleScanTimeout = Duration(seconds: 10);

// ─── Firebase Database Paths ─────────────────────────────────────────────────

/// Root path for user profiles.
const String kFirebaseUsersRoot = 'users';

/// Root path for device status documents.
const String kFirebaseDevicesRoot = 'devices';

// ─── SharedPreferences Keys ──────────────────────────────────────────────────

/// Locally cached device ID (set after successful BLE pairing).
const String kPrefDeviceId = 'linked_device_id';

/// Locally cached device name.
const String kPrefDeviceName = 'linked_device_name';

/// Whether a device is currently paired.
const String kPrefIsDevicePaired = 'is_device_paired';

// ─── SMS Validation ──────────────────────────────────────────────────────────

/// Maximum safe SMS length for Indian carriers (GSM-7 encoding).
const int kSmsMaxLength = 160;

/// Warning threshold — log a warning if message exceeds this.
const int kSmsWarningLength = 150;
