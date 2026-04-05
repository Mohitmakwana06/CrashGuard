/// CrashGuard — Environment configuration loader.
///
/// Reads Twilio credentials from `.env` via flutter_dotenv.
/// Device ID is now resolved dynamically: SharedPreferences → .env → fallback.
///
/// KEY FIXES:
///   1. Added `isTwilioConfiguredProperly` that detects placeholder values.
///   2. Added `twilioValidationError` for user-facing diagnostics.
///   3. All dotenv values are `.trim()`'d to prevent space-around-equals bugs.
///   4. Added `logTwilioStatus()` for startup diagnostics (uses print()).
///   5. Strips surrounding quotes from env values (handles KEY="value").
library;

import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'constants.dart';

/// Provides typed access to environment variables and persisted settings.
class EnvConfig {
  EnvConfig._();

  /// Reads a dotenv value, trims whitespace, and strips surrounding quotes.
  static String _readEnv(String key) {
    var value = (dotenv.env[key] ?? '').trim();
    // Strip surrounding double quotes (handles TWILIO_SID="ACxxx")
    if (value.length >= 2 && value.startsWith('"') && value.endsWith('"')) {
      value = value.substring(1, value.length - 1);
    }
    // Strip surrounding single quotes
    if (value.length >= 2 && value.startsWith("'") && value.endsWith("'")) {
      value = value.substring(1, value.length - 1);
    }
    return value;
  }

  // ─── Twilio ──────────────────────────────────────────────────────────────

  /// Twilio Account SID.
  static String get twilioAccountSid => _readEnv('TWILIO_ACCOUNT_SID');

  /// Twilio Auth Token.
  static String get twilioAuthToken => _readEnv('TWILIO_AUTH_TOKEN');

  /// Twilio sender phone number (E.164 format).
  static String get twilioPhoneNumber => _readEnv('TWILIO_PHONE_NUMBER');

  /// Returns `true` if all Twilio credentials are populated (non-empty).
  /// WARNING: This does NOT verify they are real credentials.
  /// Use [isTwilioConfiguredProperly] for production checks.
  static bool get isTwilioConfigured =>
      twilioAccountSid.isNotEmpty &&
      twilioAuthToken.isNotEmpty &&
      twilioPhoneNumber.isNotEmpty;

  /// Returns `true` only if Twilio credentials appear to be real (not placeholders).
  ///
  /// Checks:
  ///   - Account SID starts with "AC" (Twilio standard)
  ///   - Auth Token is 32+ characters (Twilio standard)
  ///   - Phone number starts with "+" (E.164 format)
  ///   - None of the values contain "your_" or "here" (placeholder markers)
  static bool get isTwilioConfiguredProperly {
    if (!isTwilioConfigured) return false;

    final sid = twilioAccountSid;
    final token = twilioAuthToken;
    final phone = twilioPhoneNumber;

    // Detect common placeholder patterns.
    final isPlaceholder = sid.contains('your_') ||
        sid.contains('_here') ||
        token.contains('your_') ||
        token.contains('_here') ||
        phone == '+1234567890';

    if (isPlaceholder) return false;

    // Validate Twilio SID format: starts with "AC", 34 chars total.
    if (!sid.startsWith('AC') || sid.length < 30) return false;

    // Validate auth token length (32 hex chars).
    if (token.length < 32) return false;

    // Validate phone number starts with "+".
    if (!phone.startsWith('+')) return false;

    return true;
  }

  /// Returns a human-readable error describing why Twilio is not configured.
  /// Returns `null` if properly configured.
  static String? get twilioValidationError {
    if (isTwilioConfiguredProperly) return null;

    if (twilioAccountSid.isEmpty) return 'Twilio Account SID is missing in .env';
    if (twilioAuthToken.isEmpty) return 'Twilio Auth Token is missing in .env';
    if (twilioPhoneNumber.isEmpty) return 'Twilio Phone Number is missing in .env';

    if (twilioAccountSid.contains('your_') || twilioAccountSid.contains('_here')) {
      return 'Twilio Account SID is still a placeholder — replace with your real SID from console.twilio.com';
    }
    if (twilioAuthToken.contains('your_') || twilioAuthToken.contains('_here')) {
      return 'Twilio Auth Token is still a placeholder — replace with your real token';
    }
    if (twilioPhoneNumber == '+1234567890') {
      return 'Twilio Phone Number is still the default — replace with your purchased Twilio number';
    }
    if (!twilioAccountSid.startsWith('AC')) {
      final preview = twilioAccountSid.substring(0, twilioAccountSid.length.clamp(0, 10));
      return 'Twilio Account SID must start with "AC" — got "$preview..." — check console.twilio.com';
    }
    if (twilioAccountSid.length < 30) {
      return 'Twilio Account SID is too short (${twilioAccountSid.length} chars, need 34)';
    }
    if (twilioAuthToken.length < 32) {
      return 'Twilio Auth Token is too short (${twilioAuthToken.length} chars, need 32)';
    }
    if (!twilioPhoneNumber.startsWith('+')) {
      return 'Twilio Phone Number must be in E.164 format (start with +)';
    }

    return 'Twilio credentials are incomplete or invalid';
  }

  /// Logs the complete Twilio configuration status to the debug console.
  /// Call this at app startup to immediately see what's wrong.
  /// Uses print() so it appears clearly in flutter run output.
  static void logTwilioStatus() {
    final sid = twilioAccountSid;
    final token = twilioAuthToken;
    final phone = twilioPhoneNumber;

    // Build masked values
    final sidMasked = sid.isEmpty
        ? '(empty)'
        : '${sid.substring(0, sid.length.clamp(0, 6))}...${sid.substring((sid.length - 4).clamp(0, sid.length))}';
    final tokenMasked = token.isEmpty
        ? '(empty)'
        : '${token.substring(0, token.length.clamp(0, 4))}...(hidden)';
    final sidPrefix = sid.isEmpty
        ? '(empty)'
        : sid.substring(0, sid.length.clamp(0, 4));

    print('╔══════════════════════════════════════════════════════════════');
    print('║ TWILIO CONFIGURATION STATUS');
    print('╠══════════════════════════════════════════════════════════════');
    print('║ SID:   "$sidMasked" (${sid.length} chars)');
    print('║ Token: "$tokenMasked" (${token.length} chars)');
    print('║ Phone: "$phone"');
    print('║');
    print('║ Checks:');
    print('║   SID not empty:       ${sid.isNotEmpty ? "✅" : "❌"}');
    print('║   Token not empty:     ${token.isNotEmpty ? "✅" : "❌"}');
    print('║   Phone not empty:     ${phone.isNotEmpty ? "✅" : "❌"}');
    print('║   SID starts with AC:  ${sid.startsWith("AC") ? "✅" : "❌ (starts with $sidPrefix)"}');
    print('║   SID length >= 30:    ${sid.length >= 30 ? "✅" : "❌"} (${sid.length})');
    print('║   Token length >= 32:  ${token.length >= 32 ? "✅" : "❌"} (${token.length})');
    print('║   Phone starts with +: ${phone.startsWith("+") ? "✅" : "❌"}');
    print('║   No placeholders:     ${!sid.contains("your_") && !token.contains("your_") ? "✅" : "❌"}');
    print('║');
    print('║ RESULT: ${isTwilioConfiguredProperly ? "✅ TWILIO CONFIGURED" : "❌ TWILIO NOT CONFIGURED"}');
    if (!isTwilioConfiguredProperly) {
      print('║ REASON: ${twilioValidationError ?? "Unknown"}');
    }
    print('╚══════════════════════════════════════════════════════════════');
  }

  // ─── ESP32 Device (dynamic) ──────────────────────────────────────────────

  /// Synchronous fallback: reads from `.env` only.
  static String get linkedDeviceIdSync => _readEnv('LINKED_DEVICE_ID').isEmpty
      ? 'CrashGuard_ESP32'
      : _readEnv('LINKED_DEVICE_ID');

  /// Returns the linked device ID.
  ///
  /// Priority: SharedPreferences → .env → hardcoded fallback.
  static Future<String> getLinkedDeviceId() async {
    final prefs = await SharedPreferences.getInstance();
    final stored = prefs.getString(kPrefDeviceId);
    if (stored != null && stored.isNotEmpty) return stored;
    return linkedDeviceIdSync;
  }

  /// Persists the linked device ID locally.
  static Future<void> setLinkedDeviceId(String deviceId) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(kPrefDeviceId, deviceId);
  }

  /// Returns the linked device name (locally cached).
  static Future<String?> getLinkedDeviceName() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(kPrefDeviceName);
  }

  /// Persists the linked device name.
  static Future<void> setLinkedDeviceName(String name) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(kPrefDeviceName, name);
  }

  /// Returns whether a device is currently paired.
  static Future<bool> isDevicePaired() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(kPrefIsDevicePaired) ?? false;
  }

  /// Sets the paired flag.
  static Future<void> setDevicePaired(bool paired) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(kPrefIsDevicePaired, paired);
  }

  /// Clears all persisted device info (used on device reset).
  static Future<void> clearDeviceInfo() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(kPrefDeviceId);
    await prefs.remove(kPrefDeviceName);
    await prefs.remove(kPrefIsDevicePaired);
  }
}
