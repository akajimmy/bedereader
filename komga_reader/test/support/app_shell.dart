import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:komga_reader/main.dart';
import 'package:komga_reader/offline/connection.dart';
import 'package:komga_reader/offline/downloads.dart';
import 'package:komga_reader/offline/sync.dart';
import 'helpers.dart';

/// The real app shell (main.dart's KomgaReaderApp) builds its own server client from the saved sign-in - not a fake.
/// [pumpApp] builds it with this behind it instead: an empty Komga (no libraries, empty lists, no client settings),
/// every request recorded in [requests] ("GET /api/v1/libraries"). Nothing reaches a network.
class ShellKomga {
  final requests = <String>[];

  http.Response _json(Object body) =>
      http.Response(jsonEncode(body), 200, headers: {'content-type': 'application/json'});

  http.Client client() => MockClient((r) async {
        requests.add('${r.method} ${r.url.path}');
        final p = r.url.path;
        if (r.method != 'GET') return http.Response('', 204);
        if (p == '/api/v2/users/me') return _json({'id': 'U1', 'email': 'nick@test'});
        if (p == '/api/v1/libraries') return _json([]);
        if (p == '/api/v1/client-settings/user/list') return _json({});
        if (p.endsWith('/thumbnail')) return http.Response('', 404);
        return _json({'content': [], 'totalElements': 0, 'last': true});
      });

  /// Pumps the app with this Komga behind it. The client is picked up when the app makes its [Komga] (main.dart
  /// _restore), which runs from here.
  Future<void> pumpApp(WidgetTester tester) =>
      http.runWithClient(() => tester.pumpWidget(const KomgaReaderApp()), client);
}

/// A storage folder for the app (what Android / Windows give it - lib/screen.dart appStorageDir), deleted when the
/// test ends; downloads go in `downloads` inside it. The singletons the app shell starts are put back too.
Directory appStorage(WidgetTester tester) {
  final dir = Directory.systemTemp.createTempSync('komga_app_shell');
  const channel = MethodChannel('komga_reader/screen');
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  messenger.setMockMethodCallHandler(channel, (call) async => call.method == 'storageDir' ? dir.path : null);
  addTearDown(() async {
    messenger.setMockMethodCallHandler(channel, null);
    Downloads.instance.pauseAll(); // the worker stops before its folder goes
    await tester.runAsync(() async {
      for (var i = 0; i < 300 && Downloads.instance.busy; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
    });
    Downloads.instance.reset();
    ProgressSync.instance.reset();
    Connection.instance.reset();
    await tester.runAsync(() => deleteTemp(dir));
  });
  return dir;
}
