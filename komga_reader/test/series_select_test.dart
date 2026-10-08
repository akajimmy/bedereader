import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:komga_reader/offline/downloads.dart';
import 'package:komga_reader/screens/library.dart';
import 'package:komga_reader/screens/series.dart';
import 'package:komga_reader/widgets/readlist_tile.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/browse_server.dart';
import 'support/helpers.dart';
import 'support/no_network.dart';

/// Library L1 with three series: S1 and S2 unread, S3 read. Records the series marked read / unread and the series'
/// books asked for (each series has two books, S1a and S1b, ...).
class SelectServer extends BrowseServer {
  SelectServer() : super(seriesCount: 3);
  final marks = <String>[]; // "read S2", "unread S3"
  final booksAsked = <String>[]; // "S2 all", "S1 UNREAD+IN_PROGRESS"

  @override
  Future<Map<String, dynamic>> series({String? libraryId, String? collectionId, List<String>? readStatus,
      String sort = 'metadata.titleSort,asc', int page = 0, int size = 60}) async {
    final r = await super.series(libraryId: libraryId, collectionId: collectionId, readStatus: readStatus,
        sort: sort, page: page, size: size);
    for (final s in r['content'] as List) {
      if (s['id'] == 'S3') s['booksUnreadCount'] = 0; // read
    }
    return r;
  }

  @override
  Future<Map<String, dynamic>> seriesBooks(String seriesId, {List<String>? readStatus,
      String sort = 'metadata.numberSort,asc', int page = 0, int size = 500}) async {
    booksAsked.add('$seriesId ${readStatus == null ? 'all' : readStatus.join('+')}');
    return {
      'content': [
        for (final x in ['a', 'b'])
          {'id': '$seriesId$x', 'seriesId': seriesId, 'seriesTitle': seriesId, 'name': x, 'metadata': {'number': x}},
      ],
      'last': true,
    };
  }

  @override
  Future<void> markSeriesRead(String seriesId) async => marks.add('read $seriesId');
  @override
  Future<void> markSeriesUnread(String seriesId) async => marks.add('unread $seriesId');
}

void main() {
  late Directory dir;
  final d = Downloads.instance;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    ListContents.invalidate();
    d.reset();
    dir = await Directory.systemTemp.createTemp('komga_series_select');
  });
  tearDown(() async {
    d.paused = false;
    d.store = null;
    await deleteTemp(dir);
  });

  Future<void> frames(WidgetTester tester) async {
    for (var i = 0; i < 6; i++) {
      await tester.pump();
    }
  }

  Future<SelectServer> library(WidgetTester tester) async {
    final api = noNetwork(SelectServer.new);
    setView(tester, const Size(1280, 900));
    await tester.pumpWidget(MaterialApp(home: LibraryScreen(api: api, onSignOut: () {}, libraryId: 'L1')));
    await frames(tester);
    return api;
  }

  Future<void> startSelecting(WidgetTester tester) async {
    await tester.tap(find.descendant(of: find.byKey(const ValueKey('bar.select')), matching: find.byType(IconButton)));
    await tester.pump();
  }

  /// Taps [tooltip] in the selection bar, then the confirm's [confirm] button.
  Future<void> confirmed(WidgetTester tester, String tooltip, String confirm) async {
    await tester.tap(find.byTooltip(tooltip));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(TextButton, confirm));
    await tester.pumpAndSettle();
  }

  testWidgets('library Series mode: select all, untick one, mark read - only the picked series not read yet',
      (tester) async {
    final api = await library(tester);
    expect(find.byKey(const ValueKey('bar.select')), findsOneWidget);
    await startSelecting(tester);
    await tester.tap(find.byTooltip('Select all'));
    await tester.pump();
    expect(find.text('3 selected'), findsOneWidget);
    await tester.tap(find.text('Series 1')); // untick S1
    await tester.pump();
    expect(find.text('2 selected'), findsOneWidget);
    await confirmed(tester, 'Mark as read', 'Mark read');
    expect(api.marks, ['read S2']); // S3 already read: skipped
    expect(find.byKey(const ValueKey('bar.select')), findsOneWidget); // selection over: the normal bar
    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets('mark unread: series with no book read or in progress are skipped; Cancel keeps the selection',
      (tester) async {
    final api = await library(tester);
    await startSelecting(tester);
    await tester.tap(find.byTooltip('Select all'));
    await tester.pump();
    await confirmed(tester, 'Mark as unread', 'Cancel');
    expect(api.marks, isEmpty);
    expect(find.text('3 selected'), findsOneWidget);
    await confirmed(tester, 'Mark as unread', 'Mark unread');
    expect(api.marks, ['unread S3']);
    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets('long-press a series -> Select multiple starts with it ticked; OK on a tile toggles it',
      (tester) async {
    await library(tester);
    await tester.longPress(find.text('Series 2'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Select multiple'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Select multiple'));
    await tester.pumpAndSettle();
    expect(find.text('1 selected'), findsOneWidget);
    await tester.tap(find.text('Series 1'));
    await tester.pump();
    expect(find.text('2 selected'), findsOneWidget);
    expect(find.byType(LibraryScreen), findsOneWidget); // a tap toggled, didn't open the series
    expect(find.byType(SeriesScreen), findsNothing);
  });

  testWidgets('download: the picked series\' books are queued, series by series in the order picked', (tester) async {
    final api = await library(tester);
    await tester.runAsync(() => d.attach(api, root: dir));
    d.pauseAll(); // keep them in the queue
    await tester.pump();
    await startSelecting(tester);
    await tester.tap(find.text('Series 2'));
    await tester.tap(find.text('Series 1'));
    await tester.pump();
    await tester.tap(find.byTooltip('Download'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Download all'));
    await frames(tester);
    expect(api.booksAsked, ['S2 all', 'S1 all']);
    // the queue is updated before its save (real file IO, not waited on here: the selection ends after it)
    expect(d.queue.map((j) => j.bookId), ['S2a', 'S2b', 'S1a', 'S1b']);
    await tester.runAsync(() async {
      d.pauseAll();
      for (var i = 0; i < 300 && d.busy; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
    });
    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets('download unread asks for the unread and in-progress books only', (tester) async {
    final api = await library(tester);
    await tester.runAsync(() => d.attach(api, root: dir));
    d.pauseAll();
    await tester.pump();
    await startSelecting(tester);
    await tester.tap(find.text('Series 3'));
    await tester.tap(find.text('Series 1'));
    await tester.pump();
    await tester.tap(find.byTooltip('Download'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Download unread'));
    await frames(tester);
    expect(api.booksAsked, ['S3 UNREAD+IN_PROGRESS', 'S1 UNREAD+IN_PROGRESS']);
    await tester.runAsync(() async {
      d.pauseAll();
      for (var i = 0; i < 300 && d.busy; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
    });
    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets('a breadcrumb back to the library in Books mode ends a series selection', (tester) async {
    final api = await library(tester);
    await startSelecting(tester);
    await tester.tap(find.text('Series 1'));
    await tester.pump();
    expect(find.text('1 selected'), findsOneWidget);
    // a screen on top (as the side menu can open), whose breadcrumb goes back to this library's Books
    final nav = tester.state<NavigatorState>(find.byType(Navigator));
    nav.push(MaterialPageRoute<void>(builder: (context) => Scaffold(body: TextButton(
        onPressed: () => LibraryScreen.openFromBreadcrumb(context, api, libraryId: 'L1', mode: BrowseMode.books),
        child: const Text('crumb')))));
    await tester.pumpAndSettle();
    await tester.tap(find.text('crumb'));
    await tester.pumpAndSettle();
    expect(find.text('Saga #1'), findsOneWidget); // books
    expect(find.text('1 selected'), findsNothing);
    expect(find.byKey(const ValueKey('bar.select')), findsOneWidget);
  });

  testWidgets('a collection\'s series: Select is there, and mark read sends its series', (tester) async {
    final api = noNetwork(SelectServer.new);
    setView(tester, const Size(1280, 900));
    await tester.pumpWidget(MaterialApp(home: SeriesListScreen(api: api, title: 'Marvel cosmic', collectionId: 'C1')));
    await frames(tester);
    expect(find.byKey(const ValueKey('bar.select')), findsOneWidget);
    await startSelecting(tester);
    await tester.tap(find.byTooltip('Select all'));
    await tester.pump();
    expect(find.text('1 selected'), findsOneWidget);
    await confirmed(tester, 'Mark as read', 'Mark read');
    expect(api.marks, ['read S1']);
    await tester.pump(const Duration(seconds: 5));
  });
}
