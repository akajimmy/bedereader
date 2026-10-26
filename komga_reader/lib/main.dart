import 'dart:async';
import 'dart:io';
import 'dart:ui' show PlatformDispatcher;

import 'package:flutter/foundation.dart' show TargetPlatform, defaultTargetPlatform;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'api.dart';
import 'app_log.dart';
import 'book_title.dart';
import 'app_identity.dart';
import 'errors.dart';
import 'hidden_libraries.dart';
import 'key_store.dart';
import 'licences.dart';
import 'local/folder_komga.dart';
import 'local/missing_prompt.dart';
import 'local/mixed_komga.dart';
import 'local/storage.dart' show LocalNames;
import 'local/where.dart' show makeComicsFolder;
import 'night_schedule.dart';
import 'screens/app_settings.dart' show AppSettingsScreen;
import 'screens/home.dart';
import 'screens/login.dart';
import 'offline/connection.dart';
import 'offline/offline_komga.dart' show OfflineKomga;
import 'offline/downloads.dart';
import 'offline/sync.dart';
import 'ondeck_hidden.dart';
import 'synced_ids.dart';
import 'pins.dart';
import 'reader_keys.dart';
import 'remote_log.dart';
import 'settings.dart';
import 'screen.dart';
import 'side_menu.dart';
import 'update_check.dart';
import 'widgets/connection_prompt.dart';
import 'widgets/drawer.dart';
import 'widgets/refresh_on_return.dart';
import 'widgets/sync_alert.dart';
import 'widgets/focus_style.dart';
import 'widgets/night.dart';
import 'widgets/poster.dart' show HoldOkGuard;

void main() {
  registerLicences(); // our MIT licence and AMD's FSR notice on the licences page
  WidgetsFlutterBinding.ensureInitialized();
  focusHighlightFollowsInput(); // the focus highlight only while the keyboard / remote is in use (focus_style.dart)
  // errors nothing else caught go to Settings > Error log too (the EPUB reader stuck on a spinner on the PC left no
  // trace to go on - user, build 65); they're still reported as before
  final flutterError = FlutterError.onError;
  FlutterError.onError = (d) {
    // (a crash line in the app's log too)
    ErrorLog.instance.record('Unexpected error (${d.library ?? 'the app'})', d.exception, d.stack, LogLevel.crash);
    flutterError?.call(d);
  };
  PlatformDispatcher.instance.onError = (e, st) {
    ErrorLog.instance.record('Unexpected error', e, st, LogLevel.crash);
    return false; // not handled: reported as usual
  };
  HttpOverrides.global = LocalNames(); // a bare server name found as name.local, as the shares are (storage.dart)
  checkPcRotation(); // Windows: a rotation sensor or not (Settings' Rotation) - answered long before it's looked at
  if (defaultTargetPlatform == TargetPlatform.android) OrientationLock.instance.release(); // Auto, the app's own
  runApp(const KomgaReaderApp());
}

/// The screen turning between portrait and landscape, in the app's log (rotation and an eBook turned unchecked on iOS -
/// backlog). Phones and tablets only: on Windows it would be the window being resized.
class _ScreenTurns with WidgetsBindingObserver {
  bool? _landscape;

  @override
  void didChangeMetrics() {
    if (defaultTargetPlatform != TargetPlatform.iOS && defaultTargetPlatform != TargetPlatform.android) return;
    final views = WidgetsBinding.instance.platformDispatcher.views;
    if (views.isEmpty) return;
    final v = views.first, size = v.physicalSize / v.devicePixelRatio;
    if (size.isEmpty) return;
    final landscape = size.width > size.height;
    if (_landscape != null && landscape != _landscape) {
      AppLog.instance.info('rotation', 'the screen is now ${landscape ? 'landscape' : 'portrait'} '
          '(${size.width.round()} x ${size.height.round()})');
    }
    _landscape = landscape;
  }
}

/// The app's log (Settings > About > App log), kept with the app's files, and the remote log's settings; the first
/// line says what's running where.
Future<void> _startLog() async {
  final dir = await appStorageDir();
  if (dir != null) await AppLog.instance.load(Directory('$dir${Platform.pathSeparator}logs'));
  await RemoteLog.instance.load();
  final v = await appVersionInfo();
  AppLog.instance.info('app', 'started: ${v?.$1 ?? '?'} (build ${v?.$2 ?? '?'}) on ${defaultTargetPlatform.name} '
      '${Platform.operatingSystemVersion}');
  // iOS: the app's folder shown in the Files app, with somewhere to copy books to (experimental/sources)
  final comics = await makeComicsFolder();
  if (comics != null) AppLog.instance.info('local', 'made $comics (the Files app hides an empty folder)');
}

/// Minimal dark theme in the chosen accent colour (Settings > Look). Focus is made clearly visible because the
/// app is driven by a D-pad remote as well as touch.
ThemeData buildTheme([Accent choice = Accent.blue]) {
  final accent = choice.colour;
  final base = ThemeData(brightness: Brightness.dark, useMaterial3: true);
  return base.copyWith(
    scaffoldBackgroundColor: const Color(0xFF0B0B0C),
    colorScheme: ColorScheme.dark(primary: accent, secondary: accent, onPrimary: choice.onColour,
        onSecondary: choice.onColour, surface: const Color(0xFF141416)),
    appBarTheme: const AppBarTheme(backgroundColor: Color(0xFF0B0B0C), elevation: 0, centerTitle: false),
    focusColor: choice.focus.withValues(alpha: 0.4), // list rows (side menu, sheets) under the remote
    iconButtonTheme: IconButtonThemeData(style: strongFocusStyle(choice.focus)),
    textButtonTheme: TextButtonThemeData(style: strongFocusStyle(choice.focus)),
    filledButtonTheme: FilledButtonThemeData(style: strongFocusStyle(choice.focus)),
    outlinedButtonTheme: OutlinedButtonThemeData(style: strongFocusStyle(choice.focus)),
    // a bar's unfilled part in grey: left to Material, it is the scheme's secondary container - the accent here, the
    // same as the filled part - so a bar looked full whatever it showed (Downloads' storage bar at 10% - user,
    // build 83)
    progressIndicatorTheme: const ProgressIndicatorThemeData(linearTrackColor: Color(0xFF34343A)),
    // a text box's sample value faded: left to Material, a hint takes the scheme's onSurfaceVariant - white in this
    // scheme, the same as text typed in - so "nick-nas" looked filled in (user, 2026-10-26)
    inputDecorationTheme: const InputDecorationTheme(hintStyle: TextStyle(color: Color(0x61E6E6E6))),
    splashFactory: NoSplash.splashFactory,
    textTheme: base.textTheme.apply(bodyColor: const Color(0xFFE6E6E6), displayColor: const Color(0xFFE6E6E6)),
  );
}

class KomgaReaderApp extends StatefulWidget {
  const KomgaReaderApp({super.key});
  @override
  State<KomgaReaderApp> createState() => _KomgaReaderAppState();
}

class _KomgaReaderAppState extends State<KomgaReaderApp> {
  Komga? _api; // the server (online) connection
  bool _loaded = false;
  final _nav = GlobalKey<NavigatorState>();
  bool _wasOffline = false;
  late final AppLifecycleListener _lifecycle;
  final _turns = _ScreenTurns();

  @override
  void initState() {
    super.initState();
    SideMenu.instance.load();
    AppDrawer.appSignOut = _signOut; // the side menu on screens not handed it
    AppSettingsScreen.appAddKomga = _addKomga; // No server mode's Add a Komga server
    // pins to a library removed go (user, 2026-10-26): one removed in Settings, or deleted on a Komga that answered -
    // the server's own list, not the offline source's (only the libraries with downloads) nor the folders'
    FolderKomga.onRemoved = Pins.instance.removeFor;
    Komga.onLibraries = (api, ids) {
      if (api is! OfflineKomga && identical(api, Connection.instance.online)) unawaited(Pins.instance.librariesNow(ids));
    };
    ErrorLog.instance.load(); // the last errors, from earlier runs too (Settings > About > Error log)
    _startLog();
    WidgetsBinding.instance.addObserver(_turns);
    // left (another app, the home screen, locked): the log kept, and what's queued sent while it still can be
    _lifecycle = AppLifecycleListener(
      onPause: () {
        AppLog.instance.lifecycle('to the background');
        RemoteLog.instance.sendNow();
      },
      onResume: () => AppLog.instance.lifecycle('back'),
    );
    NightSchedule.instance.start(); // night mode on a schedule, once the settings are in
    restoreFullscreen(); // desktop: left in full screen last time
    if (isDesktop) HardwareKeyboard.instance.addHandler(_onF11);
    HardwareKeyboard.instance.addHandler(_onMenuKey);
    Connection.instance.addListener(_onConnection);
    ProgressSync.instance.addListener(_onSync);
    Downloads.instance.addListener(_onDownloads); // Delete once read, Ask: the question
    _restore();
  }

  /// F11 anywhere (desktop): full screen is app-wide (lib/screen.dart). A keyboard-level handler, so it works on
  /// any screen whether or not something has focus.
  bool _onF11(KeyEvent e) {
    if (e is! KeyDownEvent || e.logicalKey != LogicalKeyboardKey.f11) return false;
    toggleFullscreen();
    return true;
  }

  /// The "Open the side menu" key (Settings > Remote and keys; none by default - user, 2026-10-12): from the keyboard
  /// itself, as F11, so it works whether or not anything has the focus (with the mouse on Windows, often nothing).
  bool _onMenuKey(KeyEvent e) {
    if (e is! KeyDownEvent || ReaderKeys.instance.actionFor(e.logicalKey) != ReaderAction.openMenu) return false;
    return DrawerEdgeState.toggleOnTop();
  }

  /// Esc on a full screen goes back one, like the remote's Back (user, 2026-09-30) - when nothing on the screen took
  /// it first (the reader has its own keys). Only from a full screen: a dialog or a menu closes itself (Flutter's
  /// Esc, further up), and the side menu is left to its own keys. Home has nowhere to go back to.
  KeyEventResult _onEsc(FocusNode _, KeyEvent e) {
    if (e is! KeyDownEvent || e.logicalKey != LogicalKeyboardKey.escape) return KeyEventResult.ignored;
    final ctx = FocusManager.instance.primaryFocus?.context;
    if (ctx == null || ModalRoute.of(ctx) is! PageRoute || ctx.findAncestorWidgetOfExactType<Drawer>() != null) {
      return KeyEventResult.ignored;
    }
    final n = Navigator.maybeOf(ctx); // the navigator the screen is in
    if (n == null || !n.canPop()) return KeyEventResult.ignored;
    unawaited(n.maybePop()); // maybePop: a screen that asks before leaving still asks
    return KeyEventResult.handled;
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_onF11);
    HardwareKeyboard.instance.removeHandler(_onMenuKey);
    Connection.instance.removeListener(_onConnection);
    ProgressSync.instance.removeListener(_onSync);
    Downloads.instance.removeListener(_onDownloads);
    _lifecycle.dispose();
    WidgetsBinding.instance.removeObserver(_turns);
    super.dispose();
  }

  /// Online <-> offline: back to Home, rebuilt on the other connection (open screens hold the old one). Also shows
  /// the "can't reach Komga" prompt and the messages about switching.
  void _onConnection() {
    final c = Connection.instance;
    if (c.keyPromptPending && !_prompting) {
      final ctx = _nav.currentContext;
      if (ctx != null) {
        _prompting = true;
        showKeyRefusedPrompt(ctx).then((signIn) {
          _prompting = false;
          if (signIn) {
            _nav.currentState?.popUntil((r) => r.isFirst);
            _signOut(); // to the sign-in screen, the server address kept
          }
        });
      }
    }
    if (c.askPending && !_prompting) {
      final ctx = _nav.currentContext;
      if (ctx != null) {
        _prompting = true;
        showUnreachablePrompt(ctx).then((toHome) {
          _prompting = false;
          if (toHome) _nav.currentState?.popUntil((r) => r.isFirst); // offline, nothing downloaded: Home
        }, onError: (Object _) { _prompting = false; });
      }
    }
    // reachable again: asked once no book is open (going online returns to Home)
    if (c.reachableAgain && !_askedBack && !_readerOpen && !_prompting) {
      final ctx = _nav.currentContext;
      if (ctx != null) {
        _askedBack = _prompting = true;
        showReachableAgainPrompt(ctx).whenComplete(() => _prompting = false);
      }
    }
    if (!c.reachableAgain) _askedBack = false;

    final now = c.offline;
    if (now == _wasOffline) return;
    AppLog.instance.info('connection', now ? 'offline (${c.forcedOffline ? 'switched by hand' : "Komga out of reach"})'
        : 'online');
    _wasOffline = now;
    if (!now && c.online != null) {
      // back online: the account's things from Komga again - changed on another device meanwhile, or never fetched
      // (an offline start loads them from this device only). What changed here is sent first, as at a start (user,
      // 2026-09-30)
      // (Home, rebuilt on the new connection, asks too: refresh asks once)
      unawaited(AppSettings.instance.refresh());
      unawaited(Pins.instance.refresh());
      unawaited(OnDeckHidden.instance.refresh());
      unawaited(PairShift.instance.refresh());
    }
    _nav.currentState?.popUntil((r) => r.isFirst);
    setState(() {});
  }

  bool _prompting = false, _askedBack = false;
  bool get _readerOpen => Connection.instance.readersOpen > 0;
  final _messenger = GlobalKey<ScaffoldMessengerState>();

  /// Offline progress reached Komga: an alert if Komga had changed too (further wins), else a short message.
  void _onSync() {
    final r = ProgressSync.instance.last;
    final ctx = _nav.currentContext;
    if (r == null || ctx == null) return;
    ProgressSync.instance.takeResult();
    if (r.conflicts.isNotEmpty) {
      showSyncConflicts(ctx, r);
    } else {
      _say(syncSummary(r));
    }
  }

  /// Delete once read = Ask: books finished (here, offline or elsewhere) are gathered; once no book is open, one
  /// question lists them all. Keep is the default answer (focused - OK on the remote keeps them).
  bool _asking = false;
  void _onDownloads() {
    final d = Downloads.instance;
    final ctx = _nav.currentContext;
    if (_asking || d.askPending.isEmpty || !d.noBookOpen || ctx == null) return;
    final ids = d.takeAskPending();
    if (ids.isEmpty) return;
    String title(String id) {
      final b = (d.store?.books[id]?['book'] as Map?) ?? const {};
      return bookTitle(b);
    }

    _asking = true;
    showDialog<bool>(
      context: ctx,
      builder: (c) => AlertDialog(
        title: Text(ids.length == 1 ? 'Delete the download of a book you\'ve read?' : 'Delete the downloads of '
            '${ids.length} books you\'ve read?'),
        content: Text([for (final id in ids.take(8)) title(id), if (ids.length > 8) 'and ${ids.length - 8} more']
            .join('\n')),
        actions: [
          TextButton(autofocus: true, onPressed: () => Navigator.pop(c, false), child: const Text('Keep')),
          TextButton(onPressed: () => Navigator.pop(c, true), child: const Text('Delete')),
        ],
      ),
    ).then((delete) async {
      if (delete == true) {
        await d.removeAll(ids);
      } else {
        await d.keep(ids); // Keep (or dismissed): not asked about these again
      }
      _asking = false;
      _onDownloads(); // more may have been finished meanwhile
    });
  }

  void _say(String text, {SnackBarAction? action}) => _messenger.currentState
    ?..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(text), action: action,
        duration: Duration(seconds: action == null ? 4 : 12), behavior: SnackBarBehavior.floating));

  Future<void> _restore() async {
    await HiddenLibraries.instance.load(); // before anything is fetched: lists leave those libraries out
    unawaited(ReaderKeys.instance.load()); // the reader's keys (Settings > Remote and keys)
    final p = await SharedPreferences.getInstance();
    final url = p.getString('server'), key = await KeyStore.read();
    final local = url == FolderKomga.address ? await _openLocal() : null; // no server: local libraries
    final api = local ?? (url != null && key != null && url != FolderKomga.address ? MixedKomga(url, key) : null);
    if (local != null) {
      await _startLocal(local);
    } else if (api != null) {
      await (api as MixedKomga).attachLocal(); // this device's local libraries, beside Komga's
      _watchMissing(api.local);
      // offline mode is applied first: with it on, the account's things load from this device and nothing is sent to
      // Komga (missing-tests audit, 2026-09-30: a forced-offline start still asked Komga for them, and for Home)
      await _startDownloads(api);
      final c = Connection.instance, online = !c.offline;
      unawaited(AppSettings.instance.load(c.api, fetch: online)); // c.api: the offline source while offline
      unawaited(Pins.instance.load(c.api, fetch: online));
      unawaited(OnDeckHidden.instance.load(c.api, fetch: online));
      unawaited(PairShift.instance.load(c.api, fetch: online));
    }
    // a newer release on GitHub? (at most once a day; Android, Windows) - not in offline mode: nothing is sent then
    if (!Connection.instance.forcedOffline) unawaited(UpdateCheck.instance.check());
    if (!mounted) return;
    setState(() {
      _api = api;
      _loaded = true;
    });
  }

  /// Local mode's libraries, scanned again (null: none saved, or this device's storage unknown).
  Future<FolderKomga?> _openLocal() async {
    final libraries = await FolderKomga.savedLibraries();
    final dir = await appStorageDir();
    if (libraries.isEmpty || dir == null) return null;
    try {
      return await FolderKomga.open(libraries, dataDir: Directory('$dir${Platform.pathSeparator}local'));
    } catch (_) {
      return null;
    }
  }

  /// The local libraries' scans: a library whose folder looks deleted is asked about (lib/local/missing_prompt.dart).
  void _watchMissing(FolderKomga? local) {
    _missingOf?.toAsk.removeListener(_onMissing);
    _missingOf = local?..toAsk.addListener(_onMissing);
    _onMissing();
  }

  FolderKomga? _missingOf;
  bool _askingMissing = false;

  void _onMissing() {
    final local = _missingOf;
    if (local == null || local.toAsk.value.isEmpty || _askingMissing) return;
    // after the frame: on start the navigator may not be built yet
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      final ctx = _nav.currentContext;
      if (ctx == null || _askingMissing || !identical(local, _missingOf)) return;
      _askingMissing = true;
      try {
        await askAboutMissing(ctx, local);
      } finally {
        _askingMissing = false;
      }
    });
  }

  /// No server: nothing to download from, no key; the connection only so the screens find their source. The
  /// settings, pins and the rest stay on this device ([FolderKomga.clientSettings]).
  Future<void> _startLocal(FolderKomga api) async {
    _watchMissing(api);
    await Connection.instance.load(api);
    unawaited(AppSettings.instance.load(api));
    unawaited(Pins.instance.load(api));
    unawaited(OnDeckHidden.instance.load(api));
    unawaited(PairShift.instance.load(api));
  }

  Future<void> _signIn(Komga api) async {
    final p = await SharedPreferences.getInstance();
    await p.setString('server', api.baseUrl);
    // the last Komga's own, kept through No server mode ('server' says 'local' then): the sign-in fills it in
    if (api is! FolderKomga) await p.setString(lastKomgaKey, api.baseUrl);
    if (api is FolderKomga) {
      setState(() => _api = api);
      await _startLocal(api);
      return;
    }
    await KeyStore.write(api.apiKey);
    if (api is MixedKomga) {
      await api.attachLocal(); // this device's local libraries, beside Komga's
      _watchMissing(api.local);
    }
    setState(() => _api = api);
    // in the background: each shows its local copy at once and its own sync problems
    unawaited(AppSettings.instance.load(api));
    unawaited(Pins.instance.load(api));
    unawaited(OnDeckHidden.instance.load(api));
    unawaited(PairShift.instance.load(api));
    unawaited(_startDownloads(api));
  }

  /// Downloads (1.1). Offline mode needs them, so it loads after.
  Future<void> _startDownloads(Komga api) async {
    // the queue starts once the connection has applied offline mode (a forced-offline start contacts nothing)
    await Downloads.instance.attach(api, start: false);
    await Connection.instance.load(api);
    ProgressSync.instance.start(); // offline reading -> Komga
  }

  /// No server mode -> Komga with the local libraries beside it (Settings > Server and sync, Add a Komga server), once
  /// its sign-in has worked: the screens over Home closed, No server mode left as signing out leaves it, then signed in
  /// as from the sign-in screen. (Cancelled, none of this happens: No server mode stays as it was.)
  Future<void> _addKomga(Komga api) async {
    _nav.currentState?.popUntil((r) => r.isFirst);
    await _signOut();
    await _signIn(api);
  }

  Future<void> _signOut() async {
    await KeyStore.delete();
    // local mode left: the next start asks again (the folders stay filled in)
    if (_api is FolderKomga) await (await SharedPreferences.getInstance()).remove('server');
    // nothing more goes to Komga with the old key (a return to the app used to check with it)
    Connection.instance.signedOut();
    Downloads.instance.detach();
    // the account's synced things go from this device - pins, reader settings, On deck hidden, anything unsent -
    // so they can't show under, or be sent to, the next account (code review, 2026-09-30). They come back from Komga
    // on signing in again; this device's own settings (display, keys, downloads) stay.
    await AppSettings.instance.clearAccount();
    await Pins.instance.clearAccount();
    await OnDeckHidden.instance.clearAccount();
    await PairShift.instance.clearAccount();
    final old = _api;
    if (mounted) setState(() => _api = null);
    // the old connection isn't used again (signing in makes a new one): its client goes once what's on its way has
    // finished (code review 2026-10-05, #50)
    old?.close();
  }

  // the theme is made again only when the accent colour changes, not on every settings change (a slider drag)
  Accent? _themeFor;
  ThemeData? _theme;
  ThemeData _themeOf(Accent a) {
    if (a != _themeFor || _theme == null) {
      _themeFor = a;
      _theme = buildTheme(a);
    }
    return _theme!;
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(listenable: AppSettings.instance, builder: (context, _) => _app());

  Widget _app() {
    final display = AppSettings.instance.display;
    return MaterialApp(
      title: appName,
      debugShowCheckedModeBanner: false,
      navigatorKey: _nav,
      navigatorObservers: [ReturnObserver.instance], // library views refresh when they're back on top
      scaffoldMessengerKey: _messenger,
      theme: _themeOf(display.accent),
      builder: (context, child) => appFrame(context, child!, textScale: display.textScale, onKey: _onEsc),
      home: !_loaded
          ? const Scaffold(body: SizedBox.shrink())
          : _api == null
              ? LoginScreen(onSignedIn: _signIn)
              : HomeScreen(
                  key: ValueKey(Connection.instance.offline), // a fresh Home when switching online/offline
                  api: Connection.instance.online == null ? _api! : Connection.instance.api,
                  onSignOut: _signOut,
                ),
    );
  }
}

/// What the app puts around every screen ([MaterialApp.builder]): this app's text size (Settings > Look) on top of
/// the device's own, [onKey] (Esc), the held-OK guard and the night overlay. A function of its own so the tests can
/// put the same frame around theirs (test audit, 2026-10-07).
Widget appFrame(BuildContext context, Widget child, {required double textScale,
    required KeyEventResult Function(FocusNode, KeyEvent) onKey}) {
  final mq = MediaQuery.of(context);
  return MediaQuery(
    data: textScale == 1.0 ? mq : mq.copyWith(textScaler: TextScaler.linear(mq.textScaler.scale(1) * textScale)),
    child: Focus(
      canRequestFocus: false,
      skipTraversal: true,
      onKeyEvent: onKey,
      child: HoldOkGuard(child: NightOverlay(child: child)), // a held OK's repeats don't press in its menu
    ),
  );
}
