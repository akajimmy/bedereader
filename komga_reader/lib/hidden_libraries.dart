import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Komga's libraries this device doesn't show (Settings > Libraries > Komga - moved there from Library & Home, user,
/// 2026-10-27; first 2026-09-30): kept on this device only. Local and network libraries aren't hidden - one that isn't
/// wanted isn't added (LocalSource.visibleLibraries). The Komga client leaves them out of every list that spans libraries (api.dart), and
/// out of the side menu, Home and the library picker. Komga's own user permissions are the real control; this is a
/// per-device tidy-up (a shared tablet, say).
class HiddenLibraries extends ChangeNotifier {
  HiddenLibraries._();
  static final HiddenLibraries instance = HiddenLibraries._();

  static const _key = 'libraries.hidden';
  Set<String> ids = {};

  bool isHidden(String? id) => id != null && ids.contains(id);

  Future<void> load() async {
    ids = ((await SharedPreferences.getInstance()).getStringList(_key) ?? const []).toSet();
    notifyListeners();
  }

  Future<void> setHidden(String id, bool hidden) async {
    hidden ? ids.add(id) : ids.remove(id);
    notifyListeners();
    await (await SharedPreferences.getInstance()).setStringList(_key, ids.toList());
  }

  /// Every library shown again (Reset this device's settings).
  Future<void> clear() async {
    ids = {};
    notifyListeners();
    await (await SharedPreferences.getInstance()).remove(_key);
  }
}
