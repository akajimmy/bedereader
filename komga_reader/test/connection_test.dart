import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:komga_reader/api.dart';
import 'package:komga_reader/offline/connection.dart';
import 'package:komga_reader/offline/downloads.dart';
import 'package:komga_reader/offline/offline_komga.dart';
import 'package:komga_reader/widgets/connection_prompt.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'downloads_test.dart' show FakeKomga;

/// Phase 4: when Komga can't be reached the app asks (or, with the Automatic setting, switches by itself); once
/// offline that way it notices Komga coming back and offers (or switches back when no book is open). Offline by hand
/// wins over all of it.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory dir;
  final conn = Connection.instance;
  final d = Downloads.instance;
  late FakeKomga server;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    dir = await Directory.systemTemp.createTemp('komga_conn_test');
    server = FakeKomga();
    await d.attach(server, root: dir);
    d.store!.books['B1'] = {'book': {'id': 'B1', 'seriesId': 'S1'}, 'readLists': [], 'state': 'done'};
    await conn.load(server);
    await Future<void>.delayed(Duration.zero); // the start-up check
  });
  tearDown(() async {
    conn.reset();
    await dir.delete(recursive: true);
  });

  test('Komga answering: nothing happens', () {
    expect(conn.askPending, isFalse);
    expect(conn.offline, isFalse);
  });

  test("can't reach Komga: asks; Use downloaded books goes offline; Komga back: offers, Go online returns", () async {
    server.up = false;
    await conn.check();
    expect(conn.askPending, isTrue);
    expect(conn.offline, isFalse); // asked, not switched

    conn.useDownloads();
    expect(conn.offline, isTrue);
    expect(conn.api, isA<OfflineKomga>());
    expect(d.hold, isTrue);

    await conn.check(); // still down
    expect(conn.reachableAgain, isFalse);
    server.up = true;
    await conn.check(); // the 30 s poll / returning to the app
    expect(conn.reachableAgain, isTrue);
    expect(conn.offline, isTrue); // offered, not switched

    await conn.goOnline();
    expect(conn.offline, isFalse);
    expect(conn.api, same(server));
    expect(conn.reachableAgain, isFalse);
  });

  test('Stay online: no more prompts until Komga has answered again', () async {
    server.up = false;
    await conn.check();
    conn.stayOnline();
    await conn.check();
    expect(conn.askPending, isFalse);
    server.up = true;
    await conn.check(); // outage over
    server.up = false;
    await conn.check(); // a new one
    expect(conn.askPending, isTrue);
  });

  test('Komga answering while the prompt is up clears it', () async {
    server.up = false;
    await conn.check();
    server.up = true;
    await conn.check();
    expect(conn.askPending, isFalse);
  });

  test('nothing downloaded: still says Komga can\'t be reached (Retry / OK), never switches', () async {
    await conn.setAutoSwitch(true);
    d.store!.books.clear();
    server.up = false;
    await conn.check();
    expect(conn.hasDownloads, isFalse);
    expect(conn.askPending, isTrue);
    expect(conn.offline, isFalse);
  });

  test('Automatic: switches offline by itself, and back once no book is open', () async {
    await conn.setAutoSwitch(true);
    expect((await SharedPreferences.getInstance()).getBool('offline.autoSwitch'), isTrue);
    server.up = false;
    await conn.check();
    expect(conn.askPending, isFalse);
    expect(conn.offline, isTrue);

    conn.readerOpened(); // reading a downloaded book
    server.up = true;
    await conn.check();
    expect(conn.reachableAgain, isTrue);
    expect(conn.offline, isTrue); // not while the book is open

    conn.readerClosed();
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);
    expect(conn.offline, isFalse);
  });

  test('offline by hand wins: no checks, no prompts, no offers', () async {
    await conn.setForcedOffline(true);
    server.up = true;
    expect(await conn.check(), isFalse); // doesn't even ask Komga
    expect(conn.reachableAgain, isFalse);
    expect(conn.offline, isTrue);
  });

  testWidgets('the prompt: Use downloaded books / Retry / Stay online', (tester) async {
    server.up = false;
    await tester.runAsync(() => conn.check());
    await tester.pumpWidget(MaterialApp(home: Builder(builder: (context) => TextButton(
        onPressed: () => showUnreachablePrompt(context), child: const Text('open')))));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.text("Can't reach Komga"), findsOneWidget);
    expect(find.text('Stay online'), findsOneWidget);
    expect(find.text('Retry'), findsOneWidget);
    await tester.tap(find.text('Use downloaded books'));
    await tester.pumpAndSettle();
    expect(find.text("Can't reach Komga"), findsNothing);
    expect(conn.offline, isTrue);
    unawaited(conn.setForcedOffline(false));
  });

  test('API key refused: its own prompt, and Komga answering never counts as "back" (it would refuse again)', () {
    Komga.onKeyRefused!(server); // what the server client does on HTTP 401
    Komga.onReachability!(server, true); // ...right before reporting that Komga answered
    expect(conn.keyRefused, isTrue);
    expect(conn.keyPromptPending, isTrue);
    expect(conn.askPending, isFalse); // not "can't reach Komga"

    conn.useDownloads(); // the prompt's "Use downloaded books"
    expect(conn.offline, isTrue);
    expect(conn.keyPromptPending, isFalse);
    Komga.onReachability!(server, true); // Komga still answers (and would refuse the key)
    expect(conn.reachableAgain, isFalse); // no "Komga is reachable again - Go online"
    expect(conn.offline, isTrue);
  });

  test('signing in again (a new key) starts clean', () async {
    Komga.onKeyRefused!(server);
    conn.useDownloads();
    await conn.load(FakeKomga()); // the sign-in with a new key
    expect(conn.keyRefused, isFalse);
    expect(conn.offline, isFalse);
  });

  testWidgets('the key prompt: the message, Use downloaded books, Sign in again', (tester) async {
    Komga.onKeyRefused!(server);
    bool? signIn;
    await tester.pumpWidget(MaterialApp(home: Builder(builder: (context) => TextButton(
        onPressed: () async => signIn = await showKeyRefusedPrompt(context), child: const Text('open')))));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.text('API key not accepted'), findsOneWidget);
    expect(find.textContaining("Komga no longer accepts this device's API key."), findsOneWidget);
    expect(find.text('Use downloaded books'), findsOneWidget); // B1 is downloaded
    await tester.tap(find.text('Sign in again'));
    await tester.pumpAndSettle();
    expect(signIn, isTrue);
    expect(conn.offline, isFalse);
  });
}
