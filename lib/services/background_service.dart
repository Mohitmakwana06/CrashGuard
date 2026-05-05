library;

import 'dart:async';
import 'dart:ui';

import 'package:flutter_background_service/flutter_background_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/constants.dart';
import 'notification_service.dart';

class BackgroundService {
  static Future<void> initialize() async {
    final service = FlutterBackgroundService();

    await service.configure(
      androidConfiguration: AndroidConfiguration(
        onStart: onStartBackground,
        autoStart: false,
        isForegroundMode: true,
        foregroundServiceNotificationId: kForegroundNotificationId,
        initialNotificationTitle: 'CrashGuard Active',
        initialNotificationContent: 'Monitoring for accidents...',
        notificationChannelId: 'crash_guard_bg',
        foregroundServiceTypes: [AndroidForegroundType.dataSync],
      ),
      iosConfiguration: IosConfiguration(
        autoStart: false,
        onForeground: onStartBackground,
        onBackground: onIosBackground,
      ),
    );
  }

  /// Starts accident detection monitoring.
  ///
  /// This method:
  ///   1. Initializes the background service (if not already done)
  ///   2. Starts the service
  ///   3. Shows the persistent monitoring notification
  ///   4. Persists monitoring state to SharedPreferences
  static Future<void> startDetection() async {
    try {
      print('[BackgroundService] Starting detection...');
      
      // Initialize the service if not already done
      await initialize();
      
      final service = FlutterBackgroundService();
      
      // Start the service
      await service.startService();
      print('[BackgroundService] Service started');
      
      // Show the persistent monitoring notification
      await NotificationService.showMonitoringNotification();
      
      // Persist monitoring state
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(kPrefIsMonitoringActive, true);
      await prefs.setInt(kPrefMonitoringStartMs, DateTime.now().millisecondsSinceEpoch);
      
      print('[BackgroundService] Monitoring session started and persisted');
    } catch (e) {
      print('[BackgroundService] Error starting detection: $e');
      rethrow;
    }
  }

  /// Stops accident detection monitoring.
  ///
  /// This method:
  ///   1. Stops the background service
  ///   2. Cancels the persistent monitoring notification
  ///   3. Clears monitoring state from SharedPreferences
  static Future<void> stopDetection() async {
    try {
      print('[BackgroundService] Stopping detection...');
      
      final service = FlutterBackgroundService();
      
      // Stop the service
      service.invoke('stopService');
      print('[BackgroundService] Service stopped');
      
      // Cancel the persistent notification
      await NotificationService.cancelMonitoringNotification();
      
      // Clear monitoring state
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(kPrefIsMonitoringActive);
      await prefs.remove(kPrefMonitoringStartMs);
      
      print('[BackgroundService] Monitoring session stopped and cleared');
    } catch (e) {
      print('[BackgroundService] Error stopping detection: $e');
      rethrow;
    }
  }


}

@pragma('vm:entry-point')
Future<void> onStartBackground(ServiceInstance service) async {
  DartPluginRegistrant.ensureInitialized();

  print('[BG] ============================================');
  print('[BG] Background service started');
  print('[BG] ============================================');

  if (service is AndroidServiceInstance) {
    service.on('setAsForeground').listen((_) {
      service.setAsForegroundService();
    });
    service.on('setAsBackground').listen((_) {
      service.setAsBackgroundService();
    });
  }

  service.on('stopService').listen((_) {
    print('[BG] Received stopService -- shutting down');
    service.stopSelf();
  });

  Timer.periodic(const Duration(seconds: 30), (timer) {
    if (service is AndroidServiceInstance) {
      service.setForegroundNotificationInfo(
        title: 'CrashGuard Active',
        content: 'Monitoring for accidents...',
      );
    }
    service.invoke('heartbeat');
  });
}

@pragma('vm:entry-point')
Future<bool> onIosBackground(ServiceInstance service) async {
  DartPluginRegistrant.ensureInitialized();
  return true;
}