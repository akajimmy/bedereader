import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Home's sections: which are shown and in what order (this device). Shared by Home's ⋮ menu and Settings, so
/// both always agree.
class HomeSections extends ChangeNotifier {
  HomeSections._();
  static final HomeSections instance = HomeSections._();

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

  final Map<String, bool> show = {for (final k in names.keys) k: !_hiddenByDefault.contains(k)};
  List<String> order = names.keys.toList();
  bool loaded = false;

  bool operator [](String key) => show[key] ?? false;

  Future<void> load() async {
    final p = await SharedPreferences.getInstance();
    for (final k in names.keys) {
      // 'showOnDeck' was the only toggle up to build 15
      show[k] = p.getBool('home.show.$k') ?? (k == 'ondeck' ? p.getBool('showOnDeck') : null) ?? !_hiddenByDefault.contains(k);
    }
    // saved order first (sections that still exist), then any new ones in their default place at the end
    final saved = p.getStringList('home.order') ?? const [];
    order = [...saved.where(names.containsKey), ...names.keys.where((k) => !saved.contains(k))];
    loaded = true;
    notifyListeners();
  }

  Future<void> toggle(String key) => set(key, !this[key]);

  Future<void> set(String key, bool value) async {
    show[key] = value;
    notifyListeners();
    await (await SharedPreferences.getInstance()).setBool('home.show.$key', value);
  }

  /// Move a section up (-1) or down (+1).
  Future<void> move(String key, int delta) async {
    final i = order.indexOf(key), j = i + delta;
    if (i < 0 || j < 0 || j >= order.length) return;
    order
      ..removeAt(i)
      ..insert(j, key);
    await _saveOrder();
  }

  /// Drag-and-drop reorder (onReorderItem: [to] is already the index after removing the dragged item).
  Future<void> reorder(int from, int to) async {
    final key = order.removeAt(from);
    order.insert(to, key);
    await _saveOrder();
  }

  Future<void> _saveOrder() async {
    notifyListeners();
    await (await SharedPreferences.getInstance()).setStringList('home.order', order);
  }
}
