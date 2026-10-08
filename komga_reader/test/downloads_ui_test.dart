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
    d.reset(); // e.g. the pause or the timers from the test before (test audit, 2026-09-30)
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

  testWidgets('book menu: Download queues the book; the Downloads screen shows it, and hands it to Manage once '
      'downloaded', (tester) async {
    final api = noNetwork(LibraryServer.new);
    await tester.runAsync(() => d.attach(api, root: dir));
    d.pauseAll(); // keep it in the queue so the queue view can be checked
    final b = {'id': 'B1', 'seriesTitle': 'Silver Surfer', 'name': 'b1', 'metadata': {'number': '1', 'title': 'T'}};
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: Builder(builder: (context) => TextButton(
        onPressed: () => showBookActions(context, api, b, onChanged: () {}), child: const Text('menu'))))));
    await tester.tap(find.text('menu'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Download'));
    await until(tester, () => d.jobFor('B1') != null, 'B1 queued');
    await tester.pumpAndSettle();

    await tester.pumpWidget(const MaterialApp(home: DownloadsScreen()));
    // something queued: it opens on the Queue tab
    expect(find.text('Queue · 1'), findsOneWidget);
    expect(find.text('1 in the queue · paused'), findsOneWidget);
    expect(find.text('Silver Surfer #1'), findsOneWidget);
    expect(find.text('Waiting'), findsOneWidget);

    await tester.runAsync(() async {
      d.resumeAll();
      // (downloaded, then out of the queue a moment later - wait for both)
      await waitUntil(() => d.isDownloaded('B1') && d.queue.isEmpty, timeout: const Duration(seconds: 1),
          reason: 'B1 downloaded and out of the queue');
    });
    await tester.pump();
    expect(find.text('Manage · 1'), findsOneWidget);
    expect(find.text('Silver Surfer #1'), findsNothing, reason: 'no "finished this session" list on Queue (user, 2026-10-07)');
    expect(find.textContaining('Nothing downloading'), findsOneWidget);
    await quiet(tester);
    final saving = File('${dir.path}${Platform.pathSeparator}queue.json.tmp');
    await until(tester, () => !saving.existsSync(), 'the last queue save done (its file would hold the folder)');
  });

  testWidgets('failed downloads say why and offer Retry: Retry tries that book again (the other stays failed), Retry '
      'all in the top bar the rest - and they download', (tester) async {
    final api = noNetwork(LibraryServer.new);
    await tester.runAsync(() async {
      await d.attach(api, root: dir);
      await d.setCap(100); // smaller than any book
      await d.add([
        {'id': 'B1', 'seriesTitle': 'Silver Surfer', 'metadata': {'number': '1'}},
        {'id': 'B2', 'seriesTitle': 'Silver Surfer', 'metadata': {'number': '2'}},
      ]);
      await waitUntil(() => d.queue.every((j) => j.state == JobState.failed) && !d.busy,
          timeout: const Duration(seconds: 1), reason: 'both stopped for lack of room');
    });
    await tester.pumpWidget(const MaterialApp(home: DownloadsScreen()));
    expect(find.textContaining('Failed: not enough room'), findsNWidgets(2), reason: 'says why');
    expect(find.byTooltip('Retry'), findsNWidgets(2));
    expect(find.text('Retry 2'), findsOneWidget); // retry-all in the top bar, with the count
    expect(api.pageRequests, 0);

    // the limit lifted in memory only - setCap() would put the books back in the queue by itself, and Retry would
    // never be needed (test audit, 2026-09-30: Retry was found but never tapped)
    d.capBytes = null;
    await tester.tap(find.byTooltip('Retry').first); // B1's row, first in the queue
    expect(d.jobFor('B1')?.state, isNot(JobState.failed), reason: 'back in the queue');
    await until(tester, () => d.isDownloaded('B1') && !d.busy, 'B1 downloaded after Retry');
    expect(d.jobFor('B2')!.state, JobState.failed, reason: 'Retry is for that book only');
    expect(find.textContaining('Failed: '), findsOneWidget);
    expect(find.text('Retry 1'), findsOneWidget);

    await tester.tap(find.text('Retry 1'));
    expect(d.queue.map((j) => j.state), isNot(contains(JobState.failed)), reason: 'back in the queue');
    await until(tester, () => d.isDownloaded('B2') && !d.busy && d.queue.isEmpty, 'B2 downloaded after Retry all');
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
    expect(find.textContaining(RegExp(r'^3 books · .+ used · ')), findsOneWidget,
        reason: 'the count first, then the space (user, 2026-10-07)');
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
    // a series looks unlike a book (user, 2026-10-07): a shaded card with the series icon; its books plain rows
    ListTile tile(String title) => tester.widget<ListTile>(find.widgetWithText(ListTile, title));
    expect(tile('Saga').tileColor, isNotNull);
    expect(find.descendant(of: find.widgetWithText(ListTile, 'Saga'),
        matching: find.byIcon(Icons.collections_bookmark_outlined)), findsOneWidget);
    expect(tile('Saga #1').tileColor, isNull);
    // the arrow at the left; right of the name, the trash button alone (user, 2026-10-07)
    final card = find.widgetWithText(ListTile, 'Saga');
    final nameLeft = tester.getTopLeft(find.descendant(of: card, matching: find.text('Saga'))).dx;
    final nameRight = tester.getTopRight(find.descendant(of: card, matching: find.text('Saga'))).dx;
    expect(tester.getCenter(find.descendant(of: card, matching: find.byIcon(Icons.expand_more))).dx,
        lessThan(nameLeft));
    final rightOfName = [
      for (final e in find.descendant(of: card, matching: find.byType(Icon)).evaluate())
        if ((e.renderObject! as RenderBox).localToGlobal(Offset.zero).dx > nameRight) (e.widget as Icon).icon,
    ];
    expect(rightOfName, [Icons.delete_outline]);

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
    await until(tester, () => !shows(find.text('Flash #1')), 'the saved grouping read');
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
    // a series' trash button: the whole series, after asking
    await tester.tap(find.descendant(of: find.widgetWithText(ListTile, 'Saga'), matching: find.byTooltip('Remove series')));
    await tester.pumpAndSettle();
    expect(find.text('Remove Saga?'), findsOneWidget);
    expect(find.textContaining('2 downloads · 4.0 MB freed'), findsOneWidget);
    await tester.tap(find.text('Remove'));
    await until(tester, () => find.text('Manage · 1').evaluate().isNotEmpty, 'Saga gone');
    expect(titles(), ['Flash']);
  });

  testWidgets('Manage: each book has one trash button, not a menu (user, 2026-10-07) - it removes that book at once',
      (tester) async {
    await library(tester);
    final page = File(d.store!.file('B1/pages/0001.jpg').path); // Saga #1's page on disk
    await tester.runAsync(() => page.create(recursive: true));
    await tester.pumpWidget(const MaterialApp(home: DownloadsScreen()));
    expect(find.byIcon(Icons.more_vert), findsNothing);
    expect(find.byTooltip('Remove download'), findsNWidgets(3));
    // the button itself, not d.remove() (test audit, 2026-09-30)
    await tester.tap(find.descendant(of: find.widgetWithText(ListTile, 'Saga #1'),
        matching: find.byTooltip('Remove download')));
    // (the store forgets it before the save and the screen update finish: wait for the screen)
    await until(tester, () => find.text('Manage · 2').evaluate().isNotEmpty, 'Saga #1 gone');
    expect(titles(), ['Flash #1', 'Saga #2']);
    expect(d.isDownloaded('B1'), isFalse);
    expect(await tester.runAsync(() => Directory(d.store!.file('B1').path).exists()), isFalse, reason: 'files gone');
  });
}

