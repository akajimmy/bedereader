import 'package:flutter/widgets.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Whether the side menu is docked open (this device). Docking needs a wide screen; on narrow ones the menu slides
/// out as usual whatever this says.
class SideMenu extends ChangeNotifier {
  SideMenu._();
  static final SideMenu instance = SideMenu._();

  static const _key = 'sidemenu.pinned';
  static const minWidth = 720.0; // docking needs at least this much room
  static const width = 300.0;

  bool pinned = false;

  Future<void> load() async {
    pinned = (await SharedPreferences.getInstance()).getBool(_key) ?? false;
    notifyListeners();
  }

  Future<void> setPinned(bool v) async {
    pinned = v;
    notifyListeners();
    await (await SharedPreferences.getInstance()).setBool(_key, v);
  }

  static bool roomFor(BuildContext context) => MediaQuery.sizeOf(context).width >= minWidth;

  /// Docked right now (pinned and there's room).
  static bool docked(BuildContext context) => instance.pinned && roomFor(context);
}
