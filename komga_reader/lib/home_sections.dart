import 'package:flutter/foundation.dart';

import 'settings.dart';

/// Home's sections: which are shown and in what order - synced through Komga since 2026-10-22 ([LibraryPrefs]; user's
/// quiz: "Home sections + order" follow the account - they were this device's). Shared by Home's ⋮ menu and Settings,
/// so both always agree; tells its listeners only when the sections change, not every setting.
class HomeSections extends ChangeNotifier {
  HomeSections._() {
    _seen = _key();
    _settings.addListener(() {
      final now = _key();
      if (now == _seen) return;
      _seen = now;
      notifyListeners();
    });
  }
  static final HomeSections instance = HomeSections._();

  AppSettings get _settings => AppSettings.instance;
  LibraryPrefs get _prefs => _settings.library;
  late String _seen;
  String _key() => '${_prefs.homeShown}|${_prefs.homeOrder}';

  /// Every section, in the default order.
  static const names = {
    'continue': 'Continue reading',
    'ondeck': 'On deck',
    'recentlyRead': 'Recently read',
    'recentBooks': 'Recently added books',
    'recentSeries': 'Recently added series',
    'releases': 'Recent releases',
    'pinned': 'Pinned',
    'libraries': 'Libraries',
  };

  /// The rows added later start hidden.
  static const _hiddenByDefault = {'recentlyRead', 'recentBooks', 'recentSeries', 'releases'};

  bool operator [](String key) => _prefs.homeShown[key] ?? (names.containsKey(key) && !_hiddenByDefault.contains(key));

  /// Every section, shown or not.
  Map<String, bool> get show => {for (final k in names.keys) k: this[k]};

  /// The saved order first (sections that still exist), then any others in their default place at the end.
  List<String> get order {
    final saved = _prefs.homeOrder;
    return [...saved.where(names.containsKey), ...names.keys.where((k) => !saved.contains(k))];
  }

  /// (The sections come with the settings - [AppSettings.load]; kept so Home can wait on it as before.)
  Future<void> load() async {}

  Future<void> toggle(String key) => set(key, !this[key]);

  Future<void> set(String key, bool value) async =>
      _settings.setLibrary(_prefs.copyWith(homeShown: {..._prefs.homeShown, key: value}));

  /// Move a section up (-1) or down (+1).
  Future<void> move(String key, int delta) async {
    final o = order, i = o.indexOf(key), j = i + delta;
    if (i < 0 || j < 0 || j >= o.length) return;
    o
      ..removeAt(i)
      ..insert(j, key);
    _settings.setLibrary(_prefs.copyWith(homeOrder: o));
  }

  /// Drag-and-drop reorder (onReorderItem: [to] is already the index after removing the dragged item).
  Future<void> reorder(int from, int to) async {
    final o = order;
    final key = o.removeAt(from);
    o.insert(to, key);
    _settings.setLibrary(_prefs.copyWith(homeOrder: o));
  }
}
