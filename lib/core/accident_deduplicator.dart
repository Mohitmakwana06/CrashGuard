library;

import 'package:shared_preferences/shared_preferences.dart';

class AccidentDeduplicator {
  static const String _prefix = 'processed_accident_';
  static const int _maxAgeSeconds = 60;

  static Future<bool> isAlreadyProcessed(String key) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final stored = prefs.getString('$_prefix$key');
      if (stored == null) return false;
      final timestamp = int.tryParse(stored) ?? 0;
      final age = DateTime.now().millisecondsSinceEpoch - timestamp;
      return age < _maxAgeSeconds * 1000;
    } catch (e) {
      return false;
    }
  }

  static Future<void> markAsProcessed(String key) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        '$_prefix$key',
        DateTime.now().millisecondsSinceEpoch.toString(),
      );
    } catch (e) {
      print('[Deduplicator] Error: $e');
    }
  }

  static Future<void> cleanOldKeys() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final now = DateTime.now().millisecondsSinceEpoch;
      final keys = prefs.getKeys()
          .where((k) => k.startsWith(_prefix))
          .toList();
      for (final key in keys) {
        final val = int.tryParse(prefs.getString(key) ?? '') ?? 0;
        if (now - val > _maxAgeSeconds * 1000) {
          await prefs.remove(key);
        }
      }
    } catch (e) {
      print('[Deduplicator] Clean error: $e');
    }
  }
}
