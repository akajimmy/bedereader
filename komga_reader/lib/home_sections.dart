import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Which Home sections are shown (this device). Shared by Home's ⋮ menu and App settings, so both always agree.
class HomeSections extends ChangeNotifier {
  HomeSections._();
  static final HomeSections instance = HomeSections._();

  static const names = {
    'continue': 'Continue reading', 'ondeck': 'On deck', 'pinned': 'Pinned', 'libraries': 'Libraries',
  };

  final Map<String, bool> show = {for (final k in names.keys) k: true};
  bool loaded = false;

  bool operator [](String key) => show[key] ?? true;

  Future<void> load() async {
    final p = await SharedPreferences.getInstance();
    for (final k in names.keys) {
      // 'showOnDeck' was the only toggle up to build 15
      show[k] = p.getBool('home.show.$k') ?? (k == 'ondeck' ? p.getBool('showOnDeck') : null) ?? true;
    }
    loaded = true;
    notifyListeners();
  }

  Future<void> toggle(String key) => set(key, !this[key]);

  Future<void> set(String key, bool value) async {
    show[key] = value;
    notifyListeners();
    await (await SharedPreferences.getInstance()).setBool('home.show.$key', value);
  }
}
