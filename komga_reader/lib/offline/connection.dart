import 'dart:async';

import 'package:clock/clock.dart';
import 'package:flutter/widgets.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../api.dart';
import '../errors.dart' show ErrorLog;
import '../ondeck_hidden.dart';
import '../synced_ids.dart';
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
/// - **when Komga can't be reached**: the app asks ([askPending] -> Retry / Go offline; user, 2026-10-21: the
///   automatic switch went). Once offline that way it checks every 30 s and on returning to the app, and when Komga
///   answers it asks whether to go back online ([reachableAgain]) - once no book is open; dismissed, it stays offline.
class Connection extends ChangeNotifier with WidgetsBindingObserver {
  Connection._();
  static final Connection instance = Connection._();

  static const _key = 'offline.forced';
  static const pollEvery = Duration(seconds: 30);

  int _readers = 0; // open reader screens
  int get readersOpen => _readers;

  Komga? online;
  bool forcedOffline = false; // switched on by hand
  bool autoOffline = false; // accepted the "can't reach Komga" prompt (this run only)
  bool askPending = false; // the prompt should be shown
  bool reachableAgain = false; // offline after the prompt, and Komga answers again: offer to go back

  /// Komga refuses this device's API key (deleted in Komga, say): nothing online works until signing in again. The
  /// app offers the downloaded books (which need no key) and Sign in again ([keyPromptPending]); while it lasts,
  /// Komga answering doesn't count as "reachable again" - it would only refuse the key again (user, 2026-09-29).
  bool keyRefused = false;
  bool keyPromptPending = false;
  OfflineKomga? _offline;
  Timer? _poll;
  bool _observing = false;

  /// Offline mode needs somewhere to have downloaded to (the downloads, once attached).
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
    keyRefused = keyPromptPending = false; // (signed in again: a new key)
    autoOffline = reachableAgain = false;
    Komga.onReachability = _onReachability;
    Komga.onKeyRefused = _onKeyRefused;
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

  /// The reader tells us it opened / closed (the "reachable again" question waits for it to close: going online
  /// returns to Home).
  void readerOpened() => _readers++;
  void readerClosed() {
    if (_readers > 0) _readers--;
    if (reachableAgain && _readers == 0) Timer.run(notifyListeners); // now it can ask (not from inside a dispose)
  }

  /// The prompt was answered.
  void useDownloads() {
    askPending = false;
    keyPromptPending = false;
    autoOffline = true;
    reachableAgain = false;
    _apply();
    notifyListeners();
  }

  /// "Stay offline" in the "reachable again" question (or closed): offline it stays, and not asked again until Komga
  /// goes and comes back.
  void stayOffline() {
    reachableAgain = false;
    _apply(); // (no polling: it was answered)
    notifyListeners();
  }

  /// "Go online" (Home banner / the "reachable again" question).
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
    _checks++;
    try {
      await api.me();
      return true;
    } catch (e) {
      // the check's own failure decides, not another request's that fails meanwhile (code review, 2026-10-24: one
      // failing during a check asked at once, though the check itself was answered)
      if (identical(api, online) && (e is KomgaUnreachable || e is KomgaNotKomga || e is KomgaCertificate)) _gone();
      return false;
    } finally {
      _checks--;
    }
  }

  // A request that failed asks only once Komga is clearly gone (user, 2026-10-24: on a flaky connection the prompt
  // came "every few seconds" - each failed request asked, each one that got through closed it): first a check of its
  // own ([check] - a failed check is the answer); and after the question closed because Komga answered, none for
  // [quietAfterBack].
  int _checks = 0; // checks under way: a request failing meanwhile waits for their answer
  bool _confirming = false;
  DateTime? _quietUntil;
  static const quietAfterBack = Duration(seconds: 30);

  Future<void> _confirmGone() async {
    if (_confirming) return;
    _confirming = true;
    final failure = Komga.lastFailure; // the request's
    try {
      // (its answer comes back through [_onReachability]; answering, a request failed on a connection that works:
      // noted in the error log - at most once a minute - so a flaky one shows there)
      if (await check()) {
        final now = clock.now(), last = _flakyNoted;
        if (last == null || now.difference(last) >= const Duration(minutes: 1)) {
          _flakyNoted = now;
          ErrorLog.instance.record('A request to Komga failed, but Komga answered right after (a flaky connection?)',
              failure ?? 'not known');
        }
      }
    } finally {
      _confirming = false;
    }
  }

  DateTime? _flakyNoted;

  void _onKeyRefused(Komga api) {
    if (!identical(api, online) || keyRefused) return; // a sign-in attempt says so itself
    keyRefused = true;
    keyPromptPending = true;
    askPending = false; // this prompt instead of "can't reach Komga"
    _apply();
    notifyListeners();
  }

  /// The key prompt was closed without going offline (Sign in again).
  void keyPromptAnswered() {
    keyPromptPending = false;
    notifyListeners();
  }

  void _onReachability(Komga api, bool reachable) {
    if (!identical(api, online)) return; // the offline source, or a sign-in attempt at another server
    if (keyRefused) return; // answering or not, the key is refused: the key prompt covers it
    if (reachable) {
      if (askPending) {
        askPending = false;
        _quietUntil = clock.now().add(quietAfterBack); // back: not asked again straight away
        notifyListeners();
      }
      // offline by hand stays offline: no offer to go back (missing-tests audit, 2026-09-30: the switch after the
      // prompt left autoOffline set, and a late answer offered "Go online")
      if (autoOffline && !forcedOffline && !reachableAgain) {
        reachableAgain = true;
        _apply();
        notifyListeners();
      }
    } else if (!offline && !forcedOffline && !askPending && available && _checks == 0) {
      // a request failed: asked only if a check fails too ([check] asks), and not just after Komga came back
      final quiet = _quietUntil;
      if (quiet == null || !clock.now().isBefore(quiet)) unawaited(_confirmGone());
    }
  }

  /// A check couldn't reach Komga: ask (or, with nothing downloaded, just say Komga can't be reached).
  void _gone() {
    if (keyRefused || offline || forcedOffline || askPending || !available) return;
    askPending = true;
    ErrorLog.instance.record("Can't reach Komga (asked whether to go offline)", Komga.lastFailure ?? 'not known');
    notifyListeners();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) return;
    online?.forgetLibraries(); // the side menu's kept library list is fetched again (code review 2026-10-05, #43)
    if (!forcedOffline) unawaited(check()); // back in the app: look again
  }

  /// Point the background users of the server at the current connection, and poll while offline by the prompt.
  void _apply() {
    Downloads.instance.hold = offline; // no downloading while offline
    AppSettings.instance.useApi(api); // offline: sync attempts fail and retry later
    Pins.instance.useApi(api);
    OnDeckHidden.instance.useApi(api);
    PairShift.instance.useApi(api);
    final poll = autoOffline && !forcedOffline && !reachableAgain && !keyRefused; // a refused key won't come back
    if (poll && _poll == null) {
      _poll = Timer.periodic(pollEvery, (_) => check());
    } else if (!poll) {
      _poll?.cancel();
      _poll = null;
    }
  }

  /// Signed out: the old key is forgotten here - nothing more is sent with it (no check on returning to the app, no
  /// polling) until [load] with the next sign-in (missing-tests audit, 2026-09-30).
  void signedOut() {
    _poll?.cancel();
    _poll = null;
    online = null;
    autoOffline = askPending = reachableAgain = false;
    keyRefused = keyPromptPending = false;
  }

  /// Tests: back to a clean state.
  @visibleForTesting
  void reset() {
    _poll?.cancel();
    _poll = null;
    online = null;
    forcedOffline = autoOffline = askPending = reachableAgain = false;
    keyRefused = keyPromptPending = false;
    _quietUntil = null;
    _readers = 0;
    Komga.onReachability = null;
    Komga.onKeyRefused = null;
  }
}
