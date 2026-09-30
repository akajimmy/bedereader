import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

/// Remembers each screen's browse mode / filter / sort on this device (e.g. Events opens as "Unread, series" if that
/// is how it was left). Keys: `view.library.<id|all>`, `view.series.<id>`, `view.readlist.<id>`, `view.collection.<id>`.
class ViewPrefs {
  static Future<Map<String, dynamic>> load(String key) async {
    final raw = (await SharedPreferences.getInstance()).getString(key);
    if (raw == null) return {};
    try {
      return jsonDecode(raw) as Map<String, dynamic>;
    } catch (_) {
      return {};
    }
  }

  static Future<void> save(String key, Map<String, dynamic> value) async =>
      (await SharedPreferences.getInstance()).setString(key, jsonEncode(value));

  /// Every screen back to its default mode, filter and sort (Settings > Reset this device's settings).
  static Future<void> clearAll() async {
    final p = await SharedPreferences.getInstance();
    for (final k in p.getKeys().where((k) => k.startsWith('view.'))) {
      await p.remove(k);
    }
  }
}
