import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../api.dart';
import '../ondeck_hidden.dart';
import '../pins.dart';
import '../settings.dart';
import 'downloads.dart';
import 'offline_komga.dart';

/// Online or offline. Offline, the whole app runs on [OfflineKomga] - the downloaded books only - and nothing
/// talks to the server: downloads hold, settings and pins wait to sync.
///
/// Two ways in (user's decisions, 2026-09-28):
/// - **by hand** (side menu / Settings, remembered across restarts). Manual wins: no checks, no prompts, until
///   switched off.
/// - **when Komga can't be reached**: by default the app *asks* first ([autoSwitch] makes it switch both ways by
///   itself) ([askPending] -> "Use downloaded books" / Retry / Stay
///   online). Once offline that way it checks every 30 s and on returning to the app, and when Komga answers it
///   *offers* to go back ([reachableAgain]) rather than switching by itself.
class Connection extends ChangeNotifier with WidgetsBindingObserver {
  Connection._();
  static final Connection instance = Connection._();

  static const _key = 'offline.forced';
  static const _autoKey = 'offline.autoSwitch';
  static const pollEvery = Duration(seconds: 30);

  /// App setting (per device): false = ask before going offline and offer to come back (the default); true = switch
  /// both ways by itself. Switching back waits until the reader is closed - going online returns to Home.
  bool autoSwitch = false;
  int _readers = 0; // open reader screens
  int get readersOpen => _readers;

  Komga? online;
  bool forcedOffline = false; // switched on by hand
  bool autoOffline = false; // accepted the "can't reach Komga" prompt (this run only)
  bool askPending = false; // the prompt should be shown
  bool reachableAgain = false; // offline after the prompt, and Komga answers again: offer to go back
  bool _declined = false; // "Stay online" for this outage: no more prompts until Komga answers
  OfflineKomga? _offline;
  Timer? _poll;
  bool _observing = false;

  /// Offline mode needs somewhere to have downloaded to (not on web).
  bool get available => Downloads.instance.ready;
  bool get offline => (forcedOffline || autoOffline) && available;

  /// Downloaded books to fall back on (the prompt only offers them if there are some).
  bool get hasDownloads => Downloads.instance.store?.books.values.any((e) => e['state'] == 'done') ?? false;

  /// The connection every screen should use right now.
  Komga get api {
    final store = Downloads.instance.store;
    if (!offline || store == null) return online!;
    if (_offline == null || _offline!.store != store) _offline = OfflineKomga(store, baseUrl: online?.baseUrl ?? 'offline');
    return _offline!;
  }

  Future<void> load(Komga onlineApi) async {
    online = onlineApi;
    final prefs = await SharedPreferences.getInstance();
    forcedOffline = prefs.getBool(_key) ?? false;
    autoSwitch = prefs.getBool(_autoKey) ?? false;
    Komga.onReachability = _onReachability;
    if (!_observing) {
      _observing = true;
      WidgetsBinding.instance.addObserver(this);
    }
    _apply();
    notifyListeners();
    unawaited(check()); // start-up check: a failure raises the prompt
  }

  Future<void> setForcedOffline(bool value) async {
    forcedOffline = value;
    if (!value) autoOffline = false; // "online" means online
    await (await SharedPreferences.getInstance()).setBool(_key, value);
    _apply();
    notifyListeners();
  }

  Future<void> setAutoSwitch(bool value) async {
    autoSwitch = value;
    await (await SharedPreferences.getInstance()).setBool(_autoKey, value);
    notifyListeners();
    if (value && reachableAgain) _autoBack();
  }

  /// The reader tells us it opened / closed (an automatic switch back waits for it to close).
  void readerOpened() => _readers++;
  void readerClosed() {
    if (_readers > 0) _readers--;
    if (reachableAgain) Timer.run(_autoBack); // not from inside the reader's dispose
  }

  void _autoBack() {
    if (autoSwitch && _readers == 0 && reachableAgain && !forcedOffline) unawaited(goOnline());
  }

  /// The prompt was answered.
  void useDownloads() {
    askPending = false;
    autoOffline = true;
    reachableAgain = false;
    _apply();
    notifyListeners();
  }

  void stayOnline() {
    askPending = false;
    _declined = true;
    notifyListeners();
  }

  /// "Go online" (Home banner / the "reachable again" message).
  Future<void> goOnline() async {
    reachableAgain = false;
    autoOffline = false;
    if (forcedOffline) {
      await setForcedOffline(false);
    } else {
      _apply();
      notifyListeners();
    }
  }

  /// Asks Komga whether it's there. The answer arrives through [_onReachability] (every server call reports it).
  /// Returns whether it answered. Skipped while offline by hand.
  Future<bool> check() async {
    final api = online;
    if (api == null || forcedOffline) return false;
    try {
      await api.me();
      return true;
    } catch (_) {
      return false;
    }
  }

  void _onReachability(Komga api, bool reachable) {
    if (!identical(api, online)) return; // the offline source, or a sign-in attempt at another server
    if (reachable) {
      _declined = false; // the outage is over
      if (askPending) {
        askPending = false;
        notifyListeners();
      }
      if (autoOffline && !reachableAgain) {
        reachableAgain = true;
        _apply();
        notifyListeners();
        _autoBack();
      }
    } else if (!offline && !forcedOffline && !_declined && !askPending && available) {
      if (autoSwitch && hasDownloads) {
        useDownloads(); // automatic: straight to the downloaded books
      } else {
        askPending = true; // ask (or, with nothing downloaded, just say Komga can't be reached)
        notifyListeners();
      }
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && !forcedOffline) unawaited(check()); // back in the app: look again
  }

  /// Point the background users of the server at the current connection, and poll while offline by the prompt.
  void _apply() {
    Downloads.instance.hold = offline; // no downloading while offline
    AppSettings.instance.useApi(api); // offline: sync attempts fail and retry later
    Pins.instance.useApi(api);
    OnDeckHidden.instance.useApi(api);
    final poll = autoOffline && !forcedOffline && !reachableAgain;
    if (poll && _poll == null) {
      _poll = Timer.periodic(pollEvery, (_) => check());
    } else if (!poll) {
      _poll?.cancel();
      _poll = null;
    }
  }

  /// Tests: back to a clean state.
  @visibleForTesting
  void reset() {
    _poll?.cancel();
    _poll = null;
    online = null;
    forcedOffline = autoOffline = askPending = reachableAgain = _declined = autoSwitch = false;
    _readers = 0;
    Komga.onReachability = null;
  }
}
