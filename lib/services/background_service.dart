library;

import 'dart:async';
import 'dart:ui';

import 'package:flutter_background_service/flutter_background_service.dart';

import '../core/constants.dart';

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

    await service.startService();
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