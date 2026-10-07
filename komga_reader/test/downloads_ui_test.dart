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
    // something queued: it opens on the Queue tab
    expect(find.text('Queue · 1'), findsOneWidget);
    expect(find.text('1 in the queue · paused'), findsOneWidget);
    expect(find.text('Silver Surfer #1'), findsOneWidget);
    expect(find.text('Waiting'), findsOneWidget);

    await tester.runAsync(() async {
      d.resumeAll();
      await waitUntil(() => d.isDownloaded('B1'), timeout: const Duration(seconds: 1), reason: 'B1 downloaded');
    });
    await tester.pump();
    expect(find.text('Manage · 1'), findsOneWidget);
    expect(find.text('Silver Surfer #1'), findsOneWidget, reason: 'finished this session, on the Queue tab');
    await tester.tap(find.text('Manage · 1'));
    await tester.pumpAndSettle();
    expect(find.text('3 pages · 0.0 MB · in progress'), findsOneWidget); // (the fake Komga has B1 started)

    // the menu itself, not d.remove() (test audit, 2026-09-30)
    await tester.tap(find.byTooltip('Remove'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Remove download'));
    // (the store forgets it before the save and the screen update finish: wait for the screen)
    await until(tester, () => find.text('Manage · 0').evaluate().isNotEmpty, 'the screen to show it gone');
    expect(d.isDownloaded('B1'), isFalse);
    expect(await tester.runAsync(() => Directory(d.store!.file('B1').path).exists()), isFalse, reason: 'files gone');
    expect(find.byTooltip('Remove'), findsNothing);
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
    expect(find.text('Manage · 1'), findsOneWidget);
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
    expect(find.text('Manage · 2'), findsOneWidget);
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

  // ---- Manage (user, 2026-10-07: Queue and Manage tabs; a flat list, sortable, filtered, with select mode, a
  // series' removal and Remove all read)

  /// Downloaded: Saga #1 read (3 MB), Saga #2 in progress (1 MB), Flash #1 unread (2 MB).
  Future<void> library(WidgetTester tester) => tester.runAsync(() async {
        await d.attach(noNetwork(LibraryServer.new), root: dir);
        Future<void> put(String id, String series, int n, int mb, Map<String, dynamic>? rp) => d.store!.put(id, {
              'book': {'id': id, 'seriesId': 'S-$series', 'seriesTitle': series,
                'metadata': {'number': '$n', 'numberSort': n}, 'readProgress': rp},
              'pages': [{}, {}, {}], 'bytes': mb * 1048576, 'state': 'done',
            });
        await put('B1', 'Saga', 1, 3, {'page': 3, 'completed': true});
        await put('B2', 'Saga', 2, 1, {'page': 1, 'completed': false});
        await put('B3', 'Flash', 1, 2, null);
      });

  List<String> titles() => [
        for (final t in find.byType(ListTile).evaluate().map((e) => (e.widget as ListTile).title))
          if (t is Text) t.data!,
      ];

  testWidgets('Manage: nothing queued, it opens there; filters by read state; sorts by name or by size', (tester) async {
    await library(tester);
    await tester.pumpWidget(const MaterialApp(home: DownloadsScreen()));
    expect(find.text('Manage · 3'), findsOneWidget);
    expect(titles(), ['Flash #1', 'Saga #1', 'Saga #2'], reason: 'by name: series, then number');
    expect(find.text('3 pages · 3.0 MB · read'), findsOneWidget);
    expect(find.text('3 pages · 1.0 MB · in progress'), findsOneWidget);

    await tester.tap(find.text('Read'));
    await tester.pump();
    expect(titles(), ['Saga #1']);
    await tester.tap(find.text('Unread'));
    await tester.pump();
    expect(titles(), ['Flash #1', 'Saga #2'], reason: 'in progress counts as unread, as Hide read has it');
    await tester.tap(find.text('All'));
    await tester.tap(find.text('Sort: Name'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Size, largest first'));
    await tester.pumpAndSettle();
    expect(titles(), ['Saga #1', 'Flash #1', 'Saga #2']);
  });

  testWidgets('Manage: Remove all read removes the read ones only, after saying how many and how much', (tester) async {
    await library(tester);
    await tester.pumpWidget(const MaterialApp(home: DownloadsScreen()));
    await tester.tap(find.text('Remove all read'));
    await tester.pumpAndSettle();
    expect(find.text('Remove all 1 read?'), findsOneWidget);
    expect(find.textContaining('1 download · 3.0 MB freed'), findsOneWidget);
    await tester.tap(find.text('Remove'));
    await until(tester, () => find.text('Manage · 2').evaluate().isNotEmpty, 'the read one gone');
    expect(d.isDownloaded('B1'), isFalse);
    expect([d.isDownloaded('B2'), d.isDownloaded('B3')], [true, true]);
    expect(find.text('Remove all read'), findsNothing, reason: 'nothing read left');
  });

  testWidgets("Manage: select mode - long-press starts it, taps tick, the bar says how many and how much; Back leaves "
      'it; Remove takes the ticked ones', (tester) async {
    await library(tester);
    await tester.pumpWidget(const MaterialApp(home: DownloadsScreen()));
    await tester.longPress(find.text('Saga #2'));
    await tester.pump();
    await tester.tap(find.text('Flash #1'));
    await tester.pump();
    expect(find.text('2 selected · 3.0 MB'), findsOneWidget);

    // Back: out of select mode, still on the screen
    await tester.binding.handlePopRoute();
    await tester.pump();
    expect(find.text('Downloads'), findsOneWidget);
    expect(find.byType(Checkbox), findsNothing);

    await tester.tap(find.text('Select'));
    await tester.pump();
    await tester.tap(find.text('Select all'));
    await tester.pump();
    expect(find.text('3 selected · 6.0 MB'), findsOneWidget);
    await tester.tap(find.text('Saga #1')); // untick one
    await tester.pump();
    await tester.tap(find.widgetWithText(TextButton, 'Remove'));
    await tester.pumpAndSettle();
    expect(find.text('Remove the selected downloads?'), findsOneWidget);
    await tester.tap(find.widgetWithText(TextButton, 'Remove').last);
    await until(tester, () => find.text('Manage · 1').evaluate().isNotEmpty, 'the two gone');
    expect([d.isDownloaded('B1'), d.isDownloaded('B2'), d.isDownloaded('B3')], [true, false, false]);
    expect(find.byType(Checkbox), findsNothing, reason: 'select mode over');
  });

  testWidgets('Manage, Group by series: collapsed groups with their count, size and read; a tap opens one; filters and '
      'sort apply inside; the choice is remembered', (tester) async {
    await library(tester);
    await tester.pumpWidget(const MaterialApp(home: DownloadsScreen()));
    await tester.tap(find.text('Group by series'));
    await tester.pump();
    expect(titles(), ['Flash', 'Saga'], reason: 'one closed group per series, by name');
    expect(find.text('2 books · 4.0 MB · 1 read'), findsOneWidget);
    expect(find.text('1 book · 2.0 MB'), findsOneWidget);

    await tester.tap(find.text('Saga'));
    await tester.pump();
    expect(titles(), ['Flash', 'Saga', 'Saga #1', 'Saga #2']);

    await tester.tap(find.text('Sort: Name'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Size, largest first'));
    await tester.pumpAndSettle();
    expect(titles(), ['Saga', 'Saga #1', 'Saga #2', 'Flash'], reason: "groups by their total size, books by theirs");

    await tester.tap(find.text('Unread'));
    await tester.pump();
    expect(titles(), ['Flash', 'Saga', 'Saga #2'], reason: 'the filter first: a group holds the books shown (Saga 1 MB now)');
    expect(find.text('1 book · 1.0 MB'), findsOneWidget);

    expect((await tester.runAsync(SharedPreferences.getInstance))!.getBool('downloads.groupBySeries'), isTrue);
    await tester.pumpWidget(const SizedBox());
    await tester.pumpWidget(const MaterialApp(home: DownloadsScreen()));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
    await tester.pump();
    expect(titles(), ['Flash', 'Saga'], reason: 'opened again: still grouped (groups closed again)');
  });

  testWidgets("Manage, Group by series: in select mode a group's box ticks its books (a dash when some are); its menu "
      'removes the series', (tester) async {
    await library(tester);
    await tester.pumpWidget(const MaterialApp(home: DownloadsScreen()));
    await tester.tap(find.text('Group by series'));
    await tester.pump();
    await tester.tap(find.text('Select'));
    await tester.pump();
    Checkbox box(String series) => tester.widget<Checkbox>(
        find.descendant(of: find.widgetWithText(ListTile, series), matching: find.byType(Checkbox)));
    await tester.tap(find.descendant(of: find.widgetWithText(ListTile, 'Saga'), matching: find.byType(Checkbox)));
    await tester.pump();
    expect(find.text('2 selected · 4.0 MB'), findsOneWidget);
    expect(box('Saga').value, isTrue);
    await tester.tap(find.text('Saga')); // opens it (select mode or not)
    await tester.pump();
    await tester.tap(find.text('Saga #2'));
    await tester.pump();
    expect(box('Saga').value, isNull, reason: 'some of it ticked');
    expect(find.text('1 selected · 3.0 MB'), findsOneWidget);

    await tester.tap(find.byTooltip('Done selecting'));
    await tester.pump();
    await tester.tap(find.descendant(of: find.widgetWithText(ListTile, 'Saga'), matching: find.byTooltip('Remove')));
    await tester.pumpAndSettle();
    await tester.tap(find.text("Remove the series' 2 downloads"));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Remove'));
    await until(tester, () => find.text('Manage · 1').evaluate().isNotEmpty, 'Saga gone');
    expect(titles(), ['Flash']);
  });

  testWidgets("Manage: a row's menu removes the whole series", (tester) async {
    await library(tester);
    await tester.pumpWidget(const MaterialApp(home: DownloadsScreen()));
    await tester.tap(find.byTooltip('Remove').at(1)); // Saga #1's
    await tester.pumpAndSettle();
    await tester.tap(find.text("Remove the series' 2 downloads"));
    await tester.pumpAndSettle();
    expect(find.textContaining('2 downloads · 4.0 MB freed'), findsOneWidget);
    await tester.tap(find.text('Remove'));
    await until(tester, () => find.text('Manage · 1').evaluate().isNotEmpty, 'Saga gone');
    expect(titles(), ['Flash #1']);
  });
}

