import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:komga_reader/api.dart';
import 'package:komga_reader/offline/connection.dart';
import 'package:komga_reader/offline/downloads.dart';
import 'package:komga_reader/offline/offline_komga.dart';
import 'package:komga_reader/widgets/connection_prompt.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/library_server.dart';
import 'support/helpers.dart';
import 'support/no_network.dart';

/// Phase 4: when Komga can't be reached the app asks (or, with the Automatic setting, switches by itself); once
/// offline that way it notices Komga coming back and offers (or switches back when no book is open). Offline by hand
/// wins over all of it.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory dir;
  final conn = Connection.instance;
  final d = Downloads.instance;
  late LibraryServer server;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    dir = await Directory.systemTemp.createTemp('komga_conn_test');
    server = noNetwork(LibraryServer.new);
    d.reset();
    await d.attach(server, root: dir);
    d.store!.books['B1'] = {'book': {'id': 'B1', 'seriesId': 'S1'}, 'readLists': [], 'state': 'done'};
    await conn.load(server);
    await Future<void>.delayed(Duration.zero); // the start-up check
  });
  tearDown(() async {
    conn.reset();
    await deleteTemp(dir);
  });

  test('start-up: Komga is asked once; answering, nothing happens', () {
    expect(server.meCalls, 1, reason: 'the start-up check ran');
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

  test('nothing downloaded: still says Komga can\'t be reached (Retry / OK), never switches', () async {
    d.store!.books.clear();
    server.up = false;
    await conn.check();
    expect(conn.hasDownloads, isFalse);
    expect(conn.askPending, isTrue);
    expect(conn.offline, isFalse);
  });

  test('reachable again, after going offline from the prompt (user, 2026-10-21: no automatic switch - "when back online '
      'prompt"): offline it stays until answered - asked once no book is open; Stay offline keeps it offline',
      () async {
    await conn.load(server);
    server.up = false;
    await conn.check();
    expect(conn.askPending, isTrue, reason: 'asked, never switched by itself');
    expect(conn.offline, isFalse);
    conn.useDownloads(); // the prompt's Go offline

    conn.readerOpened(); // reading a downloaded book
    server.up = true;
    await conn.check();
    expect(conn.reachableAgain, isTrue);
    var told = 0;
    void count() => told++;
    conn.addListener(count);
    conn.readerClosed(); // the moment to ask
    await Future<void>.delayed(Duration.zero);
    conn.removeListener(count);
    expect(told, greaterThan(0), reason: 'the app hears it can ask now');
    expect(conn.offline, isTrue, reason: 'not switched back by itself');

    conn.stayOffline();
    expect((conn.offline, conn.reachableAgain), (true, false));
  });

  test('offline by hand wins: no checks, no prompts, no offers', () async {
    await conn.setForcedOffline(true);
    final asked = server.meCalls;
    expect(await conn.check(), isFalse);
    conn.didChangeAppLifecycleState(AppLifecycleState.resumed); // back in the app: normally a look at Komga
    await Future<void>.delayed(Duration.zero);
    // Komga isn't even asked, so it can't offer "reachable again" (the old `reachableAgain isFalse` held whatever
    // check() did - test audit, 2026-09-30)
    expect(server.meCalls, asked, reason: 'no checks while offline by hand');
    Komga.onReachability!(server, false); // a call already on its way finds Komga gone
    expect(conn.askPending, isFalse, reason: 'no prompt');
    expect(conn.offline, isTrue);
  });

  test('offline by hand after the prompt took it offline: a late answer from Komga offers nothing either', () async {
    server.up = false;
    await conn.check();
    conn.useDownloads(); // offline by the prompt ...
    await conn.setForcedOffline(true); // ... then by hand (side menu): "no checks, no prompts, until switched off"
    Komga.onReachability!(server, true); // a call already on its way gets its answer
    expect(conn.reachableAgain, isFalse, reason: 'no "Komga is reachable again - Go online" while offline by hand');
    expect(conn.offline, isTrue);
  }); // bug found 2026-09-30 (missing-tests audit): no forcedOffline guard there; fixed in Connection._onReachability

  testWidgets('the prompt (user, 2026-10-21: "retry or go offline"): Retry / Go offline, no Stay online',
      (tester) async {
    server.up = false;
    await tester.runAsync(() => conn.check());
    await tester.pumpWidget(MaterialApp(home: Builder(builder: (context) => TextButton(
        onPressed: () => showUnreachablePrompt(context), child: const Text('open')))));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.text("Can't reach Komga"), findsOneWidget);
    expect(find.text('Retry'), findsOneWidget);
    await tester.tap(find.text('Go offline'));
    await tester.pumpAndSettle();
    expect(find.text("Can't reach Komga"), findsNothing);
    expect(conn.offline, isTrue);
    conn.reset(); // stops the 30 s poll going offline started (a timer left pending fails a widget test)
  });

  testWidgets('reachable again (user, 2026-10-21: "when back online prompt. if user dismisses prompt, stay in offline '
      'mode"): Go online goes online; Stay offline, or closing it, stays offline', (tester) async {
    Future<void> ask(Future<void> Function() answer) async {
      server.up = false;
      await tester.runAsync(() => conn.check());
      conn.useDownloads();
      server.up = true;
      await tester.runAsync(() => conn.check());
      expect(conn.reachableAgain, isTrue);
      await tester.pumpWidget(MaterialApp(key: UniqueKey(), home: Builder(builder: (context) => TextButton(
          onPressed: () => showReachableAgainPrompt(context), child: const Text('open')))));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      expect(find.text('Komga is reachable again'), findsOneWidget);
      await answer();
      await tester.runAsync(() => Future<void>.delayed(Duration.zero));
      await tester.pumpAndSettle();
      expect(find.text('Komga is reachable again'), findsNothing);
    }

    await ask(() => tester.tap(find.text('Go online')));
    expect(conn.offline, isFalse, reason: 'Go online');
    await ask(() => tester.tap(find.text('Stay offline')));
    expect((conn.offline, conn.reachableAgain), (true, false), reason: 'Stay offline');
    await tester.runAsync(() => conn.goOnline());
    await ask(() => tester.tapAt(const Offset(5, 5))); // closed: a tap outside
    expect(conn.offline, isTrue, reason: 'closed: offline it stays');
    conn.reset();
  });

  testWidgets("the prompt, when Komga answered before it was listening, closes - not a Retry that spins for good "
      '(tablet, build 77: Komga answered another request while the prompt was opening; Retry then succeeded with no '
      'change left to close it, and spun for 10+ minutes)', (tester) async {
    server.up = false;
    await tester.runAsync(() => conn.check());
    expect(conn.askPending, isTrue);
    await tester.pumpWidget(MaterialApp(home: Builder(builder: (context) => TextButton(
        onPressed: () => showUnreachablePrompt(context), child: const Text('open')))));
    // Komga answers another request just as the prompt is opening: the question is gone before the prompt listens
    server.up = true;
    Komga.onReachability!(server, true);
    expect(conn.askPending, isFalse);
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.text("Can't reach Komga"), findsNothing, reason: 'nothing to ask any more: it closes itself');
  });

  testWidgets('the prompt: Retry that reaches Komga closes it', (tester) async {
    server.up = false;
    await tester.runAsync(() => conn.check());
    await tester.pumpWidget(MaterialApp(home: Builder(builder: (context) => TextButton(
        onPressed: () => showUnreachablePrompt(context), child: const Text('open')))));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    server.up = true;
    await tester.tap(find.text('Retry'));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
    await tester.pumpAndSettle();
    expect(find.text("Can't reach Komga"), findsNothing);
    expect(conn.askPending, isFalse);
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
    await conn.load(noNetwork(LibraryServer.new)); // the sign-in with a new key
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
    expect(conn.keyPromptPending, isTrue);
    await tester.tap(find.text('Sign in again'));
    await tester.pumpAndSettle();
    expect(signIn, isTrue);
    // answered: not asked again, and not switched to the downloaded books (offline isFalse alone held either way
    // - test audit, 2026-09-30)
    expect(conn.keyPromptPending, isFalse);
    expect(conn.keyRefused, isTrue, reason: 'the key is still refused until signing in again');
    expect(conn.autoOffline, isFalse);
    expect(conn.offline, isFalse);
  });
}
