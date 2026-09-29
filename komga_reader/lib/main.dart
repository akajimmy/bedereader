import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'api.dart';
import 'screens/home.dart';
import 'screens/login.dart';
import 'offline/connection.dart';
import 'offline/downloads.dart';
import 'offline/sync.dart';
import 'pins.dart';
import 'settings.dart';
import 'side_menu.dart';
import 'widgets/connection_prompt.dart';
import 'widgets/sync_alert.dart';
import 'widgets/focus_style.dart';
import 'widgets/night.dart';

void main() => runApp(const KomgaReaderApp());

/// Minimal dark theme. Focus is made clearly visible because the app is driven by a D-pad remote as well as touch.
ThemeData buildTheme() {
  const accent = Color(0xFF8AB4F8);
  final base = ThemeData(brightness: Brightness.dark, useMaterial3: true);
  return base.copyWith(
    scaffoldBackgroundColor: const Color(0xFF0B0B0C),
    colorScheme: const ColorScheme.dark(primary: accent, secondary: accent, surface: Color(0xFF141416)),
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
    Connection.instance.addListener(_onConnection);
    ProgressSync.instance.addListener(_onSync);
    _restore();
  }

  /// Online <-> offline: back to Home, rebuilt on the other connection (open screens hold the old one). Also shows
  /// the "can't reach Komga" prompt and the messages about switching.
  void _onConnection() {
    final c = Connection.instance;
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

  void _say(String text, {SnackBarAction? action}) => _messenger.currentState
    ?..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(text), action: action,
        duration: Duration(seconds: action == null ? 4 : 12), behavior: SnackBarBehavior.floating));

  Future<void> _restore() async {
    final p = await SharedPreferences.getInstance();
    final url = p.getString('server'), key = p.getString('apiKey');
    setState(() {
      if (url != null && key != null) _api = Komga(url, key);
      if (_api != null) { AppSettings.instance.load(_api!); Pins.instance.load(_api!); _startDownloads(_api!); }
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
    _startDownloads(api);
  }

  /// Downloads (1.1): not on web, which has no storage for them. Offline mode needs them, so it loads after.
  Future<void> _startDownloads(Komga api) async {
    if (!kIsWeb) await Downloads.instance.attach(api);
    await Connection.instance.load(api);
    if (!kIsWeb) ProgressSync.instance.start(); // offline reading -> Komga
  }

  Future<void> _signOut() async {
    final p = await SharedPreferences.getInstance();
    await p.remove('apiKey');
    setState(() => _api = null);
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Komga Reader',
      debugShowCheckedModeBanner: false,
      navigatorKey: _nav,
      scaffoldMessengerKey: _messenger,
      theme: buildTheme(),
      builder: (context, child) => NightOverlay(child: child!),
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
