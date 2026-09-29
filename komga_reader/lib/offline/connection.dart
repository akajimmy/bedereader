import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../api.dart';
import '../pins.dart';
import '../settings.dart';
import 'downloads.dart';
import 'offline_komga.dart';

/// Online or offline. Offline, the whole app runs on [OfflineKomga] - the downloaded books only - and nothing
/// talks to the server: downloads hold, settings and pins wait to sync. Switched by hand (side menu / App settings;
/// remembered across restarts); phase 4 adds switching automatically when Komga can't be reached.
class Connection extends ChangeNotifier {
  Connection._();
  static final Connection instance = Connection._();

  static const _key = 'offline.forced';

  Komga? online;
  bool forcedOffline = false;
  OfflineKomga? _offline;

  /// Offline mode needs somewhere to have downloaded to (not on web).
  bool get available => Downloads.instance.ready;
  bool get offline => forcedOffline && available;

  /// The connection every screen should use right now.
  Komga get api {
    final store = Downloads.instance.store;
    if (!offline || store == null) return online!;
    if (_offline == null || _offline!.store != store) _offline = OfflineKomga(store, baseUrl: online?.baseUrl ?? 'offline');
    return _offline!;
  }

  Future<void> load(Komga onlineApi) async {
    online = onlineApi;
    forcedOffline = (await SharedPreferences.getInstance()).getBool(_key) ?? false;
    _apply();
    notifyListeners();
  }

  Future<void> setForcedOffline(bool value) async {
    forcedOffline = value;
    await (await SharedPreferences.getInstance()).setBool(_key, value);
    _apply();
    notifyListeners();
  }

  /// Point the background users of the server at the current connection.
  void _apply() {
    Downloads.instance.hold = offline; // no downloading while offline
    AppSettings.instance.useApi(api); // offline: sync attempts fail and retry later
    Pins.instance.useApi(api);
  }
}
