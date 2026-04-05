/// CrashGuard — Firebase Cloud Messaging service.
///
/// Handles FCM token management, topic subscription, and
/// incoming message processing for both foreground and
/// background/killed states.
library;

import 'dart:developer' as dev;

import 'package:firebase_messaging/firebase_messaging.dart';

import '../core/constants.dart';

/// Top-level background message handler.
///
/// Must be a top-level function (not a class method) for FCM.
@pragma('vm:entry-point')
Future<void> firebaseMessagingBackgroundHandler(RemoteMessage message) async {
  dev.log('[FCM] Background message: ${message.messageId}');
  // The actual alert triggering happens via the Firebase RTDB listener
  // running in the background service. FCM just wakes the process.
}

/// Manages Firebase Cloud Messaging.
class FcmService {
  FcmService._();

  /// FCM topic for accident alerts from cloud functions.
  static const String _topic = 'accident_alerts';

  /// Callback to invoke when a notification is tapped (foreground/background).
  static void Function(RemoteMessage message)? onMessageTapped;

  /// Callback to invoke when a message arrives in foreground.
  static void Function(RemoteMessage message)? onForegroundMessage;

  // ---------------------------------------------------------------------------
  // Public API
  // ---------------------------------------------------------------------------

  /// Initializes FCM: requests permission, gets token, subscribes to topic,
  /// and sets up message handlers.
  static Future<void> initialize() async {
    final messaging = FirebaseMessaging.instance;

    // 1. Request notification permission (Android 13+).
    final settings = await messaging.requestPermission(
      alert: true,
      badge: true,
      sound: true,
      criticalAlert: true,
    );
    dev.log('[FCM] Permission: ${settings.authorizationStatus}');

    // 2. Get FCM token.
    try {
      final token = await messaging.getToken();
      dev.log('[FCM] Token: $token');
    } catch (e) {
      dev.log('[FCM] Token fetch failed: $e');
    }

    // 3. Subscribe to accident alerts topic.
    try {
      await messaging.subscribeToTopic(_topic);
      dev.log('[FCM] Subscribed to topic: $_topic');
    } catch (e) {
      dev.log('[FCM] Topic subscription failed: $e');
    }

    // 4. Register background handler.
    FirebaseMessaging.onBackgroundMessage(firebaseMessagingBackgroundHandler);

    // 5. Foreground message handler.
    FirebaseMessaging.onMessage.listen((message) {
      dev.log('[FCM] Foreground message: ${message.messageId}');
      dev.log('[FCM] Data: ${message.data}');

      // Check if this is an accident notification.
      final status = message.data['status']?.toString().toUpperCase();
      if (status == kStatusAccident) {
        onForegroundMessage?.call(message);
      }
    });

    // 6. Handle notification tap when app is in background (not killed).
    FirebaseMessaging.onMessageOpenedApp.listen((message) {
      dev.log('[FCM] Opened from background: ${message.messageId}');
      onMessageTapped?.call(message);
    });

    // 7. Check if app was launched from a notification.
    final initialMessage = await messaging.getInitialMessage();
    if (initialMessage != null) {
      dev.log('[FCM] Launched from notification: ${initialMessage.messageId}');
      // Delay slightly to let the UI build first.
      Future.delayed(const Duration(milliseconds: 500), () {
        onMessageTapped?.call(initialMessage);
      });
    }
  }
}
