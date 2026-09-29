import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'api.dart';
import 'screens/home.dart';
import 'screens/login.dart';
import 'offline/downloads.dart';
import 'pins.dart';
import 'settings.dart';
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
  Komga? _api;
  bool _loaded = false;

  @override
  void initState() {
    super.initState();
    _restore();
  }

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

  /// Downloads (1.1): not on web, which has no storage for them.
  void _startDownloads(Komga api) {
    if (!kIsWeb) Downloads.instance.attach(api);
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
      theme: buildTheme(),
      builder: (context, child) => NightOverlay(child: child!),
      home: !_loaded
          ? const Scaffold(body: SizedBox.shrink())
          : _api == null
              ? LoginScreen(onSignedIn: _signIn)
              : HomeScreen(api: _api!, onSignOut: _signOut),
    );
  }
}
