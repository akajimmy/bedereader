import 'package:flutter/material.dart';

import 'api.dart';
import 'main.dart' show buildTheme;
import 'screens/about.dart';
import 'widgets/drawer.dart';

/// Developer preview of the About screen and the side menu with a stand-in server (no API key needed).
/// Build: flutter build web -t lib/dev_info_preview.dart. Add ?drawer to the URL to see the side menu.
void main() => runApp(MaterialApp(debugShowCheckedModeBanner: false, theme: buildTheme(), home: const _Preview()));

class _FakeKomga extends Komga {
  _FakeKomga() : super('http://192.168.1.10:25600', 'k');
  @override
  Future<Map<String, dynamic>?> me() async => {'email': 'reader@example.com'};
  @override
  Future<List<dynamic>> libraries() async => [
        {'id': '1', 'name': 'Ongoing'}, {'id': '2', 'name': 'Archive'}, {'id': '3', 'name': 'Events'},
      ];
}

class _Preview extends StatefulWidget {
  const _Preview();
  @override
  State<_Preview> createState() => _PreviewState();
}

class _PreviewState extends State<_Preview> {
  final _scaffold = GlobalKey<ScaffoldState>();

  @override
  void initState() {
    super.initState();
    if (Uri.base.queryParameters.containsKey('drawer')) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _scaffold.currentState?.openDrawer());
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        key: _scaffold,
        drawer: AppDrawer(api: _FakeKomga(), onSignOut: () {}),
        body: AboutScreen(api: _FakeKomga()),
      );
}
