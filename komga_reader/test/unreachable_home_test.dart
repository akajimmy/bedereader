import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:komga_reader/api.dart';
import 'package:komga_reader/offline/connection.dart';
import 'package:komga_reader/offline/downloads.dart';
import 'package:komga_reader/screens/home.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/app_shell.dart';
import 'support/helpers.dart';

/// "Can't reach Komga" with nothing downloaded (user, 2026-10-22: "the OK button just leads me back to a
/// non-responsive page. make sure it puts it in offline mode and dumps the user to the home screen").
void main() {
  const url = 'http://komga.test:25600';

  testWidgets('OK, with nothing downloaded: offline mode, and back on Home from wherever the user was',
      (tester) async {
    final dir = appStorage(tester);
    SharedPreferences.setMockInitialValues({'server': url});
    FlutterSecureStorage.setMockInitialValues({'apiKey': 'k'});
    await tester.runAsync(() async {
      final downloads = Directory('${dir.path}${Platform.pathSeparator}downloads')..createSync(recursive: true);
      await File('${downloads.path}${Platform.pathSeparator}server.json').writeAsString(jsonEncode({'url': url}));
    });
    final komga = ShellKomga();
    await komga.pumpApp(tester);
    await waitUntil(() => Connection.instance.online != null && Downloads.instance.ready, tester: tester,
        timeout: const Duration(seconds: 5), reason: 'the app to start');
    await tester.pump();
    expect(Connection.instance.hasDownloads, isFalse, reason: 'the premise: nothing downloaded');

    // somewhere else than Home - a library page, say - waiting on Komga
    Navigator.of(tester.element(find.byType(HomeScreen))).push(MaterialPageRoute<void>(
        builder: (_) => const Scaffold(body: Text('a page waiting on Komga'))));
    await tester.pumpAndSettle();
    expect(find.text('a page waiting on Komga'), findsOneWidget);

    // Komga stops answering: a request finds it gone (and the check that follows, too)
    komga.down = true;
    Komga.onReachability!(Connection.instance.online!, false);
    await tester.pump();
    await tester.pump();
    expect(find.text("Can't reach Komga"), findsOneWidget);
    expect(find.text('Go offline'), findsNothing, reason: 'nothing downloaded: Retry / OK');

    await tester.tap(find.text('OK'));
    await tester.pumpAndSettle();
    expect(find.text("Can't reach Komga"), findsNothing);
    expect(find.text('a page waiting on Komga'), findsNothing, reason: 'not left on the page that was waiting');
    expect(find.byType(HomeScreen), findsOneWidget, reason: 'on Home');
    expect(Connection.instance.offline, isTrue, reason: 'in offline mode');
    Connection.instance.reset(); // (the 30 s poll going offline started)
    await tester.pump(const Duration(seconds: 1));
  });
}
