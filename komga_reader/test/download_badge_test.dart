import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:komga_reader/offline/downloads.dart';
import 'package:komga_reader/offline/store.dart';
import 'package:komga_reader/widgets/download_badge.dart';

/// Tile badges: a book shows downloaded / in the queue / failed; a series or read list shows how many of its books are
/// downloaded (tick alone when all are). No file IO - the store's index is filled in memory.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized(); // (the plain test may run alone)
  final d = Downloads.instance;

  Map<String, dynamic> entry(String series, List<String> lists, {String state = 'done'}) => {
        'book': {'seriesId': series},
        'readLists': [for (final id in lists) {'id': id, 'name': id, 'index': 0}],
        'state': state,
      };

  setUp(() {
    d.store = OfflineStore(Directory.systemTemp) // never read or written here
      ..books.addAll({
        'b1': entry('s1', ['rl1']),
        'b2': entry('s1', ['rl1']),
        'b3': entry('s1', [], state: 'partial'), // not finished: doesn't count
      });
    d.queue.clear();
    d.notifyListeners();
  });
  tearDown(() {
    d.store = null;
    d.queue.clear();
  });

  Future<void> show(WidgetTester tester, Widget badge) =>
      tester.pumpWidget(MaterialApp(home: Scaffold(body: Center(child: badge))));

  testWidgets('counts only finished downloads, per series and read list', (tester) async {
    expect(d.downloadedInSeries('s1'), 2);
    expect(d.downloadedInReadList('rl1'), 2);
    expect(d.downloadedInSeries('other'), 0);

    await show(tester, const DownloadBadge.series('s1', total: 5));
    expect(find.text('2'), findsOneWidget); // partly downloaded: the count

    await show(tester, const DownloadBadge.readList('rl1', total: 2));
    expect(find.text('2'), findsNothing); // all of it: tick alone
    expect(find.byIcon(Icons.download_done), findsOneWidget);

    await show(tester, const DownloadBadge.series('other', total: 3));
    expect(find.byIcon(Icons.download_done), findsNothing);
  });

  testWidgets('a book: downloaded, downloading, failed, or nothing', (tester) async {
    await show(tester, const DownloadBadge.book('b1'));
    expect(find.byIcon(Icons.download_done), findsOneWidget);

    d.queue.add(DownloadJob(bookId: 'b9', title: 'x', state: JobState.downloading)
      ..pagesTotal = 20
      ..pagesDone = 5);
    await show(tester, const DownloadBadge.book('b9'));
    expect(tester.widget<CircularProgressIndicator>(find.byType(CircularProgressIndicator)).value, 0.25);

    d.queue.first.state = JobState.failed;
    d.notifyListeners();
    await tester.pump();
    expect(find.byIcon(Icons.priority_high), findsOneWidget);

    await show(tester, const DownloadBadge.book('nope'));
    // within the badge only - any Container elsewhere on the page would have broken the old check (test audit,
    // 2026-09-30)
    final inBadge = find.descendant(of: find.byType(DownloadBadge), matching: find.byWidgetPredicate((w) => w is Container || w is Icon));
    expect(inBadge, findsNothing);
    expect(tester.getSize(find.byType(DownloadBadge)), Size.zero);
  });

  test('the counts follow changes to the store', () {
    expect(d.downloadedInSeries('s1'), 2);
    d.store!.books['b3']!['state'] = 'done';
    d.notifyListeners();
    expect(d.downloadedInSeries('s1'), 3);
  });
}
