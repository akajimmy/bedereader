import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'api.dart';
import 'app_identity.dart';
import 'errors.dart';
import 'hidden_libraries.dart';
import 'licences.dart';
import 'night_schedule.dart';
import 'screens/home.dart';
import 'screens/login.dart';
import 'offline/connection.dart';
import 'offline/downloads.dart';
import 'offline/sync.dart';
import 'ondeck_hidden.dart';
import 'pins.dart';
import 'reader_keys.dart';
import 'settings.dart';
import 'screen.dart';
import 'side_menu.dart';
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
  runApp(const KomgaReaderApp());
}

/// Minimal dark theme in the chosen accent colour (Settings > Display). Focus is made clearly visible because the
/// app is driven by a D-pad remote as well as touch.
ThemeData buildTheme([Accent choice = Accent.blue]) {
  final accent = choice.colour;
  final base = ThemeData(brightness: Brightness.dark, useMaterial3: true);
  return base.copyWith(
    scaffoldBackgroundColor: const Color(0xFF0B0B0C),
    colorScheme: ColorScheme.dark(primary: accent, secondary: accent, onPrimary: choice.onColour,
        onSecondary: choice.onColour, surface: const Color(0xFF141416)),
    appBarTheme: const AppBarTheme(backgroundColor: Color(0xFF0B0B0C), elevation: 0, centerTitle: false),
    focusColor: accent.withValues(alpha: 0.4), // list rows (side menu, sheets) under the remote
    iconButtonTheme: IconButtonThemeData(style: strongFocusStyle(accent)),
    textButtonTheme: TextButtonThemeData(style: strongFocusStyle(accent)),
    filledButtonTheme: FilledButtonThemeData(style: strongFocusStyle(accent)),
    outlinedButtonTheme: OutlinedButtonThemeData(style: strongFocusStyle(accent)),
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

  @override
  void initState() {
    super.initState();
    SideMenu.instance.load();
    AppDrawer.appSignOut = _signOut; // the side menu on screens not handed it
    ErrorLog.instance.load(); // the last errors, from earlier runs too (Settings > About > Error log)
    NightSchedule.instance.start(); // night mode on a schedule, once the settings are in
    restoreFullscreen(); // desktop: left in full screen last time
    if (isDesktop) HardwareKeyboard.instance.addHandler(_onF11);
    Connection.instance.addListener(_onConnection);
    ProgressSync.instance.addListener(_onSync);
    Downloads.instance.addListener(_onDownloads); // Delete once read, Ask: the question
    _restore();
  }

  /// Online <-> offline: back to Home, rebuilt on the other connection (open screens hold the old one). Also shows
  /// the "can't reach Komga" prompt and the messages about switching.
  /// F11 anywhere (desktop): full screen is app-wide (lib/screen.dart). A keyboard-level handler, so it works on
  /// any screen whether or not something has focus.
  bool _onF11(KeyEvent e) {
    if (e is! KeyDownEvent || e.logicalKey != LogicalKeyboardKey.f11) return false;
    toggleFullscreen();
    return true;
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_onF11);
    super.dispose();
  }

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
        showUnreachablePrompt(ctx).whenComplete(() => _prompting = false);
      }
    }
    if (c.reachableAgain && !_wasReachable && !(c.autoSwitch && !_readerOpen)) {
      _say('Komga is reachable again', action: SnackBarAction(label: 'Go online', onPressed: c.goOnline));
    }
    _wasReachable = c.reachableAgain;

    final now = c.offline;
    if (now == _wasOffline) return;
    _wasOffline = now;
    if (c.autoSwitch && !c.forcedOffline) _say(now ? "Can't reach Komga - showing downloaded books" : 'Back online');
    _nav.currentState?.popUntil((r) => r.isFirst);
    setState(() {});
  }

  bool _prompting = false, _wasReachable = false;
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
      return '${b['seriesTitle'] ?? ''} #${(b['metadata'] as Map?)?['number'] ?? ''}'.trim();
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
    ReaderKeys.instance.load(); // the reader's keys (Settings > Remote and keys)
    final p = await SharedPreferences.getInstance();
    final url = p.getString('server'), key = p.getString('apiKey');
    setState(() {
      if (url != null && key != null) _api = Komga(url, key);
      if (_api != null) { AppSettings.instance.load(_api!); Pins.instance.load(_api!); OnDeckHidden.instance.load(_api!); _startDownloads(_api!); }
      _loaded = true;
    });
  }

  Future<void> _signIn(Komga api) async {
    final p = await SharedPreferences.getInstance();
    await p.setString('server', api.baseUrl);
    await p.setString('apiKey', api.apiKey);
    setState(() => _api = api);
    AppSettings.instance.load(api);
    Pins.instance.load(api);
    OnDeckHidden.instance.load(api);
    _startDownloads(api);
  }

  /// Downloads (1.1): not on web, which has no storage for them. Offline mode needs them, so it loads after.
  Future<void> _startDownloads(Komga api) async {
    // the queue starts once the connection has applied offline mode (a forced-offline start contacts nothing)
    if (!kIsWeb) await Downloads.instance.attach(api, start: false);
    await Connection.instance.load(api);
    if (!kIsWeb) ProgressSync.instance.start(); // offline reading -> Komga
  }

  Future<void> _signOut() async {
    final p = await SharedPreferences.getInstance();
    await p.remove('apiKey');
    // the account's synced things go from this device - pins, reader settings, On deck hidden, anything unsent -
    // so they can't show under, or be sent to, the next account (code review, 2026-09-30). They come back from Komga
    // on signing in again; this device's own settings (display, keys, downloads) stay.
    await AppSettings.instance.clearAccount();
    await Pins.instance.clearAccount();
    await OnDeckHidden.instance.clearAccount();
    if (mounted) setState(() => _api = null);
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
      // this app's text size (Settings > Display), on top of the device's own
      builder: (context, child) {
        final mq = MediaQuery.of(context);
        final scale = display.textScale;
        return MediaQuery(
          data: scale == 1.0 ? mq : mq.copyWith(textScaler: TextScaler.linear(mq.textScaler.scale(1) * scale)),
          child: HoldOkGuard(child: NightOverlay(child: child!)), // a held OK's repeats don't press in its menu
        );
      },
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
