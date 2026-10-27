import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:komga_reader/offline/downloads_source.dart';
import 'package:komga_reader/screens/search.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/helpers.dart';
import 'support/no_network.dart';
import 'support/offline_store.dart';

/// Answers searches for "surf" with one series and two books; records the library each search was limited to.
class FakeKomga extends TestKomga {
  final scopes = <String?>[]; // library each search was limited to
  final marked = <String>[];
  @override
  Future<void> markRead(String bookId) async => marked.add(bookId);

  @override
  Future<Map<String, dynamic>> searchSeries(String query, {String? libraryId, int size = 30}) async {
    scopes.add(libraryId);
    return onePage(query == 'surf'
        ? [{'id': 'S1', 'name': 'Silver Surfer', 'booksCount': 2, 'metadata': {'title': 'Silver Surfer'}}]
        : []);
  }

  @override
  Future<Map<String, dynamic>> searchBooks(String query, {String? libraryId, int size = 30}) async => onePage(query == 'surf'
      ? [
          for (var i = 1; i <= 2; i++)
            {'id': 'B$i', 'seriesTitle': 'Silver Surfer', 'name': 'b$i', 'metadata': {'number': '$i', 'title': 'T$i'}},
        ]
      : []);
  @override
  Future<Map<String, dynamic>> searchReadLists(String query, {String? libraryId, int size = 30}) async => onePage([]);
  @override
  Future<Map<String, dynamic>> searchCollections(String query, {String? libraryId, int size = 30}) async => onePage([]);
  @override // the found series' books: the two already matched
  Future<Map<String, dynamic>> booksOfSeries(List<String> seriesIds, {int size = 300}) async =>
      searchBooks('surf');
}

/// Bug #15's case: two series found, Komga's book search matching only one book (its own title has the words); each
/// series has more books.
class SeriesBooksKomga extends FakeKomga {
  final asked = <List<String>>[];
  @override
  Future<Map<String, dynamic>> searchSeries(String query, {String? libraryId, int size = 30}) async => onePage([
        {'id': 'S1', 'name': 'Absolute Power', 'booksCount': 2, 'metadata': {'title': 'Absolute Power'}},
        {'id': 'S2', 'name': 'Task Force VII', 'booksCount': 2, 'metadata': {'title': 'Task Force VII'}},
      ]);
  @override
  Future<Map<String, dynamic>> searchBooks(String query, {String? libraryId, int size = 30}) async => onePage([
        {'id': 'B9', 'seriesId': 'S2', 'seriesTitle': 'Task Force VII', 'metadata': {'number': '6', 'title': 'Absolute power'}},
      ]);
  @override // by number across both series, as Komga sorts them
  Future<Map<String, dynamic>> booksOfSeries(List<String> seriesIds, {int size = 300}) async {
    asked.add(seriesIds);
    return onePage([
      {'id': 'B1', 'seriesId': 'S1', 'seriesTitle': 'Absolute Power', 'metadata': {'number': '1', 'title': 'One'}},
      {'id': 'B8', 'seriesId': 'S2', 'seriesTitle': 'Task Force VII', 'metadata': {'number': '1', 'title': 'Start'}},
      {'id': 'B2', 'seriesId': 'S1', 'seriesTitle': 'Absolute Power', 'metadata': {'number': '2', 'title': 'Two'}},
      {'id': 'B9', 'seriesId': 'S2', 'seriesTitle': 'Task Force VII', 'metadata': {'number': '6', 'title': 'Absolute power'}},
    ]);
  }
}

/// A search that only answers when told to (one still on its way when the box is cleared).
class SlowKomga extends FakeKomga {
  final pending = Completer<void>();
  @override
  Future<Map<String, dynamic>> searchSeries(String query, {String? libraryId, int size = 30}) async {
    await pending.future;
    return super.searchSeries(query, libraryId: libraryId, size: size);
  }
}

void main() {
  testWidgets('clearing the box while a search is on its way stops the progress bar (it stayed on above "Type to '
      'search." - code review 2026-10-05, #13)', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final api = noNetwork(SlowKomga.new);
    await tester.pumpWidget(MaterialApp(home: SearchScreen(api: api)));
    await tester.enterText(find.byType(TextField), 'surf');
    await tester.pump(const Duration(milliseconds: 400)); // typing pause: the search starts
    expect(find.byType(LinearProgressIndicator), findsOneWidget);
    await tester.enterText(find.byType(TextField), '');
    await tester.pump(const Duration(milliseconds: 400));
    api.pending.complete(); // the old search answers - too late, it's ignored
    await tester.pump();
    expect(find.text('Type to search.'), findsOneWidget);
    expect(find.byType(LinearProgressIndicator), findsNothing);
  });

  testWidgets('results appear as you type, in rows with counts; nothing found says so', (tester) async {
    SharedPreferences.setMockInitialValues({});
    await tester.pumpWidget(MaterialApp(home: SearchScreen(api: noNetwork(FakeKomga.new))));
    expect(find.text('Type to search.'), findsOneWidget);
    await tester.enterText(find.byType(TextField), 'surf');
    await tester.pump(const Duration(milliseconds: 400)); // typing pause
    await tester.pump();
    expect(find.text('Series · 1'), findsOneWidget);
    expect(find.text('Books · 2'), findsOneWidget);
    expect(find.text('Silver Surfer #2'), findsOneWidget);
    expect(find.textContaining('Read lists'), findsNothing); // empty kinds are left out

    await tester.enterText(find.byType(TextField), 'zzz');
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump();
    expect(find.text('Nothing found for "zzz"'), findsOneWidget);
  });

  testWidgets('opened from a library it searches there; the chip widens it to all libraries', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final api = noNetwork(FakeKomga.new);
    await tester.pumpWidget(MaterialApp(home: SearchScreen(api: api, libraryId: 'L1', libraryName: 'Events')));
    await tester.enterText(find.byType(TextField), 'surf');
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump();
    expect(api.scopes.last, 'L1');
    await tester.tap(find.text('All libraries'));
    await tester.pump();
    await tester.pump();
    expect(api.scopes.last, isNull);
  });

  testWidgets("after an action from a result's menu, the search runs again (code review, 2026-09-30)",
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    setView(tester, const Size(1280, 1600)); // tall enough for the Books row
    final api = noNetwork(FakeKomga.new);
    await tester.pumpWidget(MaterialApp(home: SearchScreen(api: api)));
    await tester.enterText(find.byType(TextField), 'surf');
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump();
    final searches = api.scopes.length;
    await tester.longPress(find.text('Silver Surfer #1'));
    await tester.pumpAndSettle();
    expect(find.text('Details'), findsOneWidget, reason: "the book's menu");
    await tester.ensureVisible(find.text('Mark as read')); // the sheet scrolls in a short window
    await tester.pumpAndSettle();
    await tester.tap(find.text('Mark as read'));
    await tester.pumpAndSettle();
    expect(api.marked, ['B1']);
    expect(api.scopes.length, searches + 1, reason: 'the results are fetched again (a deleted book would go)');
  });

  test('offline search looks through the downloaded titles', () async {
    final dir = await Directory.systemTemp.createTemp('komga_search_test');
    try {
      final api = DownloadsSource(await buildStore(dir));
      List<String> ids(Map<String, dynamic> r) => [for (final i in r['content'] as List) i['id'] as String];
      expect(ids(await api.searchSeries('surf')), ['S1']);
      expect(ids(await api.searchBooks('spider')), ['B3']); // matches the series title of the book
      expect(ids(await api.searchReadLists('event')), ['RL1']);
      expect(ids(await api.searchCollections('cosm')), ['C1']);
      expect(ids(await api.searchSeries('   ')), isEmpty);
      // a found series' downloaded books, by number - Search's Books row (bug #15)
      expect(ids(await api.booksOfSeries(['S1'])), ['B1', 'B2', 'B5']);
      expect(ids(await api.booksOfSeries(['S2', 'S1'])).toSet(), {'B1', 'B2', 'B5', 'B3'});
    } finally {
      await deleteTemp(dir);
    }
  });

  testWidgets("bug #15: the Books row has the books of the series found too - the matched ones first, then each "
      "series' books in the Series row's order and by number, each once; one request for every series", (tester) async {
    SharedPreferences.setMockInitialValues({});
    final api = noNetwork(SeriesBooksKomga.new);
    await tester.pumpWidget(MaterialApp(home: SearchScreen(api: api)));
    await tester.enterText(find.byType(TextField), 'absolute power');
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();
    expect(api.asked, [['S1', 'S2']], reason: 'one request, both series');
    expect(find.text('Books · 4'), findsOneWidget);
    double x(String t) => tester.getTopLeft(find.text(t)).dx;
    final shown = ['Task Force VII #6', 'Absolute Power #1', 'Absolute Power #2', 'Task Force VII #1'];
    for (final t in shown) {
      expect(find.text(t), findsOneWidget, reason: '$t once');
    }
    final xs = [for (final t in shown) x(t)];
    expect(xs, [...xs]..sort(), reason: shown.join(', '));
  });
}
