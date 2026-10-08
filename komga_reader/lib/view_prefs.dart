import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import 'view_filter.dart';

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

  /// The key of a view's filters (the filter panel's), next to its read 'filter'.
  static const filtersKey = 'filters';

  /// The filters saved in a view's loaded prefs (none if there are none).
  static ViewFilter filtersOf(Map<String, dynamic> view) => ViewFilter.fromJson(view[filtersKey]);

  /// A view's prefs to save, with its filters ([filters] none: the key left out).
  static Map<String, dynamic> withFilters(Map<String, dynamic> view, ViewFilter filters) => {
        for (final e in view.entries) if (e.key != filtersKey) e.key: e.value,
        if (filters.isNotEmpty) filtersKey: filters.toJson(),
      };

  /// A view's saved filters.
  static Future<ViewFilter> loadFilters(String key) async => filtersOf(await load(key));

  /// Saves a view's filters, keeping the rest of what it saved (mode, read filter, sort).
  static Future<void> saveFilters(String key, ViewFilter filters) async =>
      save(key, withFilters(await load(key), filters));

  /// Every screen back to its default mode, filter and sort (Settings > Reset this device's settings).
  static Future<void> clearAll() async {
    final p = await SharedPreferences.getInstance();
    for (final k in p.getKeys().where((k) => k.startsWith('view.'))) {
      await p.remove(k);
    }
  }
}
