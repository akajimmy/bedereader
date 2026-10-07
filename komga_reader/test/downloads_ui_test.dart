import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:komga_reader/offline/downloads.dart';
import 'package:komga_reader/screens/actions.dart';
import 'package:komga_reader/screens/downloads_screen.dart';
import 'package:komga_reader/widgets/selection.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/helpers.dart';
import 'support/library_server.dart';
import 'support/no_network.dart';

void main() {
  late Directory dir;
  final d = Downloads.instance;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    d.reset(); // e.g. "finished this session" from the test before (test audit, 2026-09-30)
    dir = await Directory.systemTemp.createTemp('komga_downloads_ui');
  });
  tearDown(() async {
    d.paused = false;
    await deleteTemp(dir);
  });

  /// Pause and wait (on a real clock) until the worker has finished its last save, so the folder can go.
  Future<void> quiet(WidgetTester tester) => tester.runAsync(() async {
        d.pauseAll();
        for (var i = 0; i < 300 && d.busy; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }
      });

  /// Waits (real clock, 1 s at most) for [done], pumping between looks: work started by a tap runs in the test's zone
  /// and only moves on when pumped.
  Future<void> until(WidgetTester tester, bool Function() done, String reason) =>
      waitUntil(done, tester: tester, timeout: const Duration(seconds: 1), step: const Duration(milliseconds: 10),
          reason: reason);

  testWidgets('book menu: Download queues the book; the Downloads screen shows it, then Remove download frees it',
      (tester) async {
    final api = noNetwork(LibraryServer.new);
    await tester.runAsync(() => d.attach(api, root: dir));
    d.pauseAll(); // keep it in the queue so the queue view can be checked
    final b = {'id': 'B1', 'seriesTitle': 'Silver Surfer', 'name': 'b1', 'metadata': {'number': '1', 'title': 'T'}};
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: Builder(builder: (context) => TextButton(
        onPressed: () => showBookActions(context, api, b, onChanged: () {}), child: const Text('menu'))))));
    await tester.tap(find.text('menu'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Download'));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
    await tester.pumpAndSettle();
    expect(d.jobFor('B1'), isNotNull);

    await tester.pumpWidget(const MaterialApp(home: DownloadsScreen()));
    expect(find.text('Queue · 1 · paused'), findsOneWidget);
    expect(find.text('Silver Surfer #1'), findsOneWidget);
    expect(find.text('Waiting'), findsOneWidget);

    await tester.runAsync(() async {
      d.resumeAll();
      await waitUntil(() => d.isDownloaded('B1'), timeout: const Duration(seconds: 1), reason: 'B1 downloaded');
    });
    await tester.pump();
    expect(find.text('Downloaded · 1'), findsOneWidget);
    expect(find.text('3 pages · 0.0 MB'), findsOneWidget);
    expect(find.text('Silver Surfer #1'), findsNWidgets(2)); // finished this session + downloaded

    // the button itself, not d.remove() (test audit, 2026-09-30)
    await tester.tap(find.byTooltip('Remove download'));
    // (the store forgets it before the save and the screen update finish: wait for the screen)
    await until(tester, () => find.text('Downloaded · 0').evaluate().isNotEmpty, 'the screen to show it gone');
    expect(d.isDownloaded('B1'), isFalse);
    expect(await tester.runAsync(() => Directory(d.store!.file('B1').path).exists()), isFalse, reason: 'files gone');
    expect(find.text('Downloaded · 0'), findsOneWidget);
    expect(find.byTooltip('Remove download'), findsNothing);
    await quiet(tester);
  });

  testWidgets('a failed download says why and offers Retry; Retry tries it again', (tester) async {
    final api = noNetwork(LibraryServer.new);
    await tester.runAsync(() async {
      await d.attach(api, root: dir);
      await d.setCap(100); // smaller than any book
      await d.add([{'id': 'B2', 'seriesTitle': 'Silver Surfer', 'metadata': {'number': '2'}}]);
      await waitUntil(() => d.jobFor('B2')?.state == JobState.failed, timeout: const Duration(seconds: 1),
          reason: 'B2 stopped for lack of room');
    });
    await tester.pumpWidget(const MaterialApp(home: DownloadsScreen()));
    expect(find.textContaining('Failed: not enough room'), findsOneWidget);
    expect(find.byTooltip('Retry'), findsOneWidget);
    expect(find.text('Retry 1'), findsOneWidget); // retry-all in the top bar
    expect(api.pageRequests, 0);

    // the limit lifted in memory only - setCap() would put the book back in the queue by itself, and Retry would
    // never be needed (test audit, 2026-09-30: Retry was found but never tapped)
    d.capBytes = null;
    await tester.tap(find.byTooltip('Retry'));
    expect(d.jobFor('B2')?.state, isNot(JobState.failed), reason: 'back in the queue');
    await until(tester, () => d.isDownloaded('B2') && !d.busy, 'B2 downloaded after Retry');
    expect(d.isDownloaded('B2'), isTrue);
    expect(find.textContaining('Failed:'), findsNothing);
    expect(find.text('Downloaded · 1'), findsOneWidget);
    await quiet(tester);
  });

  testWidgets("Retry all in the top bar: every failed book goes back in the queue and downloads", (tester) async {
    final api = noNetwork(LibraryServer.new)..booksFail = true;
    await tester.runAsync(() async {
      await d.attach(api, root: dir);
      await d.add([
        {'id': 'B1', 'seriesTitle': 'Silver Surfer', 'metadata': {'number': '1'}},
        {'id': 'B2', 'seriesTitle': 'Silver Surfer', 'metadata': {'number': '2'}},
      ]);
      await waitUntil(() => d.queue.every((j) => j.state == JobState.failed) && !d.busy,
          timeout: const Duration(seconds: 1), reason: 'both failed');
    });
    await tester.pumpWidget(const MaterialApp(home: DownloadsScreen()));
    expect(find.textContaining('Failed: '), findsNWidgets(2));

    api.booksFail = false; // Komga fixed
    await tester.tap(find.text('Retry 2'));
    expect(d.queue.map((j) => j.state), isNot(contains(JobState.failed)), reason: 'both back in the queue');
    await waitUntil(() => d.isDownloaded('B1') && d.isDownloaded('B2') && !d.busy, tester: tester,
        timeout: const Duration(seconds: 3), step: const Duration(milliseconds: 10), reason: 'both downloaded');
    expect(find.textContaining('Failed:'), findsNothing);
    expect(find.text('Downloaded · 2'), findsOneWidget);
    await quiet(tester);
  });

  testWidgets('multi-select: Download queues the ticked books in the order picked', (tester) async {
    final api = noNetwork(LibraryServer.new);
    await tester.runAsync(() => d.attach(api, root: dir));
    d.pauseAll(); // keep them in the queue to check the order
    final sel = Selection()..start();
    final b1 = {'id': 'B1', 'seriesTitle': 'Silver Surfer', 'metadata': {'number': '1'}};
    final b2 = {'id': 'B2', 'seriesTitle': 'Silver Surfer', 'metadata': {'number': '2'}};
    sel
      ..toggle(b2)
      ..toggle(b1);
    await tester.pumpWidget(MaterialApp(home: Builder(builder: (context) => Scaffold(
        appBar: selectionAppBar(context, api, sel, all: () => [b1, b2], onChanged: () {}), body: const SizedBox()))));
    await tester.tap(find.byTooltip('Download'));
    // the queue is updated before the save starts, so this is deterministic (the save itself is covered in
    // downloads_test; waiting on it here would need the real clock and the test clock to hand over repeatedly)
    expect(d.queue.map((j) => j.bookId), ['B2', 'B1']);
  });

  testWidgets('a downloaded EPUB is listed as an EPUB with its size - it has no pages to count ("0 pages" - Windows, '
      'build 79)', (tester) async {
    await tester.runAsync(() async {
      await d.attach(noNetwork(LibraryServer.new), root: dir);
      await d.store!.put('B1', {
        'book': {'id': 'B1', 'seriesTitle': 'The Dispossessed', 'metadata': {'number': '1'}},
        'pages': [], 'bytes': 1048576, 'state': 'done', 'epubFile': 'book.epub', 'positions': [],
      });
    });
    await tester.pumpWidget(const MaterialApp(home: DownloadsScreen()));
    expect(find.text('EPUB · 1.0 MB'), findsOneWidget);
    expect(find.textContaining('0 pages'), findsNothing);
  });
}

