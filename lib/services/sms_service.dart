/// CrashGuard — SMS service (Twilio REST API).
///
/// Sends emergency SMS messages to a list of phone numbers
/// using the Twilio Messages API. Features exponential-backoff
/// retry and duplicate-send prevention. Credentials are loaded
/// from [EnvConfig] (backed by `.env`).
///
/// KEY FIXES v4:
///   1. Message length validation after {location} substitution.
///   2. Logs exact character count and warns if over 150 chars.
///   3. Intelligent truncation: keeps URL intact, truncates body.
///   4. All logging uses print() with [SmsService] prefix.
///   5. Twilio response status and body logged on every call.
library;

import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../core/constants.dart';
import '../core/env_config.dart';

/// Result of an SMS send attempt.
class SmsResult {
  final bool success;
  final String? error;
  const SmsResult({required this.success, this.error});

  @override
  String toString() => 'SmsResult(ok: $success${error != null ? ', err: $error' : ''})';
}

/// Sends SMS via the Twilio REST API with retry logic.
class SmsService {
  /// Track the last SMS timestamp per recipient to prevent duplicates.
  static final Map<String, DateTime> _lastSentMap = {};

  /// Minimum gap between SMS to the same number (prevents duplicates).
  static const Duration _duplicateWindow = Duration(seconds: 60);

  // ---------------------------------------------------------------------------
  // Public API
  // ---------------------------------------------------------------------------

  /// Validates Twilio credentials by making a lightweight API call.
  ///
  /// Returns `null` if credentials are valid, or an error string if not.
  static Future<String?> testCredentials() async {
    // First check if credentials look valid locally.
    if (!EnvConfig.isTwilioConfiguredProperly) {
      final error = EnvConfig.twilioValidationError ??
          'Twilio credentials are not configured';
      print('[SmsService] testCredentials FAILED: $error');
      return error;
    }

    // Try a lightweight Twilio API call to verify credentials.
    final sid = EnvConfig.twilioAccountSid;
    final url = Uri.parse(
      'https://api.twilio.com/2010-04-01/Accounts/$sid.json',
    );

    print('[SmsService] Testing credentials against Twilio API...');
    try {
      final response = await http
          .get(
            url,
            headers: {
              'Authorization':
                  'Basic ${base64Encode(utf8.encode('$sid:${EnvConfig.twilioAuthToken}'))}',
            },
          )
          .timeout(const Duration(seconds: 10));

      if (response.statusCode == 200) {
        print('[SmsService] Twilio credentials verified OK');
        return null; // Valid
      } else if (response.statusCode == 401) {
        print('[SmsService] Twilio returned 401 -- bad credentials');
        print('[SmsService] Response body: ${response.body}');
        return 'Twilio authentication failed - check your Account SID and Auth Token';
      } else {
        print('[SmsService] Twilio returned HTTP ${response.statusCode}');
        print('[SmsService] Response body: ${response.body}');
        return 'Twilio API returned HTTP ${response.statusCode}';
      }
    } catch (e) {
      print('[SmsService] Could not reach Twilio API: $e');
      return 'Could not reach Twilio API: $e';
    }
  }

  /// Sends [body] to each number in [recipients].
  ///
  /// Returns a list of [SmsResult] — one per recipient.
  /// Retries up to [kSmsMaxRetries] times with exponential backoff.
  static Future<List<SmsResult>> sendToAll({
    required String body,
    required List<String> recipients,
  }) async {
    print('');
    print('[SmsService] ================================================');
    print('[SmsService] sendToAll() called');
    print('[SmsService] Recipients: ${recipients.length}');
    print('[SmsService] Message length: ${body.length} chars (limit: $kSmsMaxLength)');

    // Length validation and truncation.
    String finalBody = body;
    if (body.length > kSmsWarningLength) {
      print('[SmsService] WARNING: Message is ${body.length} chars (over $kSmsWarningLength warning threshold)');

      if (body.length > kSmsMaxLength) {
        print('[SmsService] Message exceeds $kSmsMaxLength chars -- truncating intelligently');
        finalBody = _truncateKeepingUrl(body, kSmsWarningLength);
        print('[SmsService] Truncated message: ${finalBody.length} chars');
      }
    }
    print('[SmsService] Final message (${finalBody.length} chars): $finalBody');

    // Check proper configuration (detects placeholder credentials).
    if (!EnvConfig.isTwilioConfiguredProperly) {
      final error = EnvConfig.twilioValidationError ??
          'Twilio credentials not configured in .env';
      print('[SmsService] TWILIO CONFIG CHECK FAILED: $error');
      print('[SmsService]   Raw SID: "${EnvConfig.twilioAccountSid}"');
      print('[SmsService]   Raw Token length: ${EnvConfig.twilioAuthToken.length}');
      print('[SmsService]   Raw Phone: "${EnvConfig.twilioPhoneNumber}"');
      return recipients
          .map((_) => SmsResult(success: false, error: error))
          .toList();
    }
    print('[SmsService] Twilio credentials validated OK');

    // NOTE: Removed connectivity_plus check. It has known false negatives
    // on Android 14 where it reports ConnectivityResult.none even when WiFi
    // is connected. Instead, we just try to send and let HTTP timeout handle
    // real network failures.
    print('[SmsService] Skipping connectivity check (known Android 14 bug)');

    if (recipients.isEmpty) {
      const error = 'No emergency contacts to send to';
      print('[SmsService] $error');
      return [];
    }

    final results = <SmsResult>[];
    int successCount = 0;
    int failCount = 0;

    for (final to in recipients) {
      // Validate phone number format.
      if (!to.startsWith('+')) {
        print('[SmsService] SKIP "$to" -- does not start with "+"');
        print('[SmsService]    Numbers must be E.164 format (e.g. +919876543210)');
        results.add(SmsResult(
          success: false,
          error: 'Invalid format: "$to" (must start with +)',
        ));
        failCount++;
        continue;
      }

      if (to.length < 10) {
        print('[SmsService] SKIP "$to" -- too short (${to.length} chars)');
        results.add(SmsResult(
          success: false,
          error: 'Phone number too short: "$to"',
        ));
        failCount++;
        continue;
      }

      // Duplicate prevention.
      if (_isDuplicateSend(to)) {
        print('[SmsService] Skipped duplicate to ${_maskPhone(to)} (sent within last 60s)');
        results.add(const SmsResult(
          success: true,
          error: 'Already sent recently (duplicate prevented)',
        ));
        successCount++;
        continue;
      }

      print('[SmsService] Attempting SMS to ${_maskPhone(to)}...');
      final result = await _sendWithRetry(body: finalBody, to: to);
      results.add(result);

      if (result.success) {
        successCount++;
        print('[SmsService] SMS SENT to ${_maskPhone(to)}');
      } else {
        failCount++;
        print('[SmsService] SMS FAILED to ${_maskPhone(to)}: ${result.error}');
      }
    }

    print('[SmsService] ================================================');
    print('[SmsService] FINAL: $successCount sent, $failCount failed');
    print('[SmsService] ================================================');

    return results;
  }

  // ---------------------------------------------------------------------------
  // Internals
  // ---------------------------------------------------------------------------

  /// Truncates the message body to [maxLength] while keeping any URL intact.
  ///
  /// Finds the Google Maps URL in the body and ensures it is never cut.
  /// Truncates the text portion before the URL if needed.
  static String _truncateKeepingUrl(String body, int maxLength) {
    // Find Google Maps URL in the body.
    final urlPattern = RegExp(r'https?://maps\.google\.com/\S+');
    final match = urlPattern.firstMatch(body);

    if (match == null) {
      // No URL found — just truncate and add ellipsis.
      return '${body.substring(0, maxLength - 3)}...';
    }

    final url = match.group(0)!;
    final beforeUrl = body.substring(0, match.start);
    final afterUrl = body.substring(match.end);

    // Calculate how much space we have for the text portions.
    final availableForText = maxLength - url.length - 4; // 4 for "... "
    if (availableForText <= 0) {
      // URL alone exceeds limit — just return URL.
      return url;
    }

    // Truncate the before-URL text, keep URL and after-URL text.
    final truncatedBefore = beforeUrl.length > availableForText
        ? '${beforeUrl.substring(0, availableForText)}... '
        : beforeUrl;

    final result = '$truncatedBefore$url$afterUrl';
    return result.length > maxLength
        ? result.substring(0, maxLength)
        : result;
  }

  /// Masks a phone number for logging (e.g., +919167517997 -> +919****997).
  static String _maskPhone(String phone) {
    if (phone.length < 7) return phone;
    return '${phone.substring(0, 4)}****${phone.substring(phone.length - 3)}';
  }

  /// Checks if we've already sent an SMS to [to] within the duplicate window.
  static bool _isDuplicateSend(String to) {
    final lastSent = _lastSentMap[to];
    if (lastSent == null) return false;
    return DateTime.now().difference(lastSent) < _duplicateWindow;
  }

  /// Sends a single SMS to [to] with exponential-backoff retry.
  static Future<SmsResult> _sendWithRetry({
    required String body,
    required String to,
  }) async {
    SmsResult? lastResult;

    for (var attempt = 0; attempt < kSmsMaxRetries; attempt++) {
      if (attempt > 0) {
        // Exponential backoff: 0s, 2s, 4s
        final delay = Duration(
          milliseconds: kSmsRetryBaseDelayMs * attempt,
        );
        print('[SmsService] Retry ${attempt + 1}/$kSmsMaxRetries for ${_maskPhone(to)} in ${delay.inSeconds}s');
        await Future.delayed(delay);
      }

      lastResult = await _send(body: body, to: to);

      if (lastResult.success) {
        // Record successful send to prevent duplicates.
        _lastSentMap[to] = DateTime.now();
        return lastResult;
      }

      print('[SmsService] Attempt ${attempt + 1}/$kSmsMaxRetries failed: ${lastResult.error}');
    }

    print('[SmsService] All $kSmsMaxRetries attempts exhausted for ${_maskPhone(to)}');
    return lastResult ??
        const SmsResult(success: false, error: 'All retry attempts failed');
  }

  /// Sends a single SMS to [to] via Twilio REST API (no retry).
  static Future<SmsResult> _send({
    required String body,
    required String to,
  }) async {
    final sid = EnvConfig.twilioAccountSid;
    final token = EnvConfig.twilioAuthToken;
    final from = EnvConfig.twilioPhoneNumber;

    final url = Uri.parse(
      'https://api.twilio.com/2010-04-01/Accounts/$sid/Messages.json',
    );

    final credentials = base64Encode(utf8.encode('$sid:$token'));

    print('[SmsService] -- HTTP Request --');
    print('[SmsService]   POST ${url.toString()}');
    print('[SmsService]   From: $from');
    print('[SmsService]   To:   $to');
    print('[SmsService]   Body: ${body.length} chars');
    print('[SmsService]   Timeout: 30s');

    try {
      final response = await http
          .post(
            url,
            headers: {
              'Authorization': 'Basic $credentials',
              'Content-Type': 'application/x-www-form-urlencoded',
            },
            body: {
              'From': from,
              'To': to,
              'Body': body,
            },
          )
          .timeout(const Duration(seconds: 30));

      print('[SmsService] -- HTTP Response --');
      print('[SmsService]   Status: ${response.statusCode}');
      print('[SmsService]   Body: ${response.body}');

      if (response.statusCode == 201 || response.statusCode == 200) {
        print('[SmsService] Twilio accepted message');
        return const SmsResult(success: true);
      } else {
        // Parse Twilio error for clear diagnostics
        String errorMsg;
        try {
          final decoded = jsonDecode(response.body);
          errorMsg = decoded['message'] as String? ??
              'HTTP ${response.statusCode}';
          final errorCode = decoded['code'];
          if (errorCode != null) {
            errorMsg = '[$errorCode] $errorMsg';
          }
        } catch (_) {
          errorMsg =
              'HTTP ${response.statusCode}: ${response.body.substring(0, response.body.length.clamp(0, 300))}';
        }
        print('[SmsService] Twilio error: $errorMsg');

        // Common Twilio error codes
        if (response.statusCode == 401) {
          print('[SmsService] FIX: Check Account SID and Auth Token at console.twilio.com');
        } else if (response.body.contains('21608') || response.body.contains('unverified')) {
          print('[SmsService] FIX: On trial accounts, you must verify the recipient number at:');
          print('[SmsService]    console.twilio.com -> Phone Numbers -> Verified Caller IDs');
          print('[SmsService]    Add and verify: $to');
        } else if (response.body.contains('21211')) {
          print('[SmsService] FIX: Invalid "To" phone number format: $to');
        } else if (response.body.contains('21612') || response.body.contains('21408')) {
          print('[SmsService] FIX: Cannot send SMS to this region from your Twilio number');
        } else if (response.body.contains('30044')) {
          print('[SmsService] FIX: Message too long for carrier. Current: ${body.length} chars');
        }

        return SmsResult(success: false, error: errorMsg);
      }
    } on TimeoutException {
      print('[SmsService] HTTP request timed out after 30s');
      return const SmsResult(
          success: false, error: 'HTTP request timed out (30s)');
    } catch (e) {
      print('[SmsService] HTTP request exception: $e');
      return SmsResult(success: false, error: e.toString());
    }
  }
}
