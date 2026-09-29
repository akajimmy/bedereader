import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:komga_reader/api.dart';
import 'package:komga_reader/offline/offline_komga.dart';
import 'package:komga_reader/screens/search.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'offline_test.dart' show buildStore;

/// Answers searches for "surf" with one series and two books; records the library each search was limited to.
class FakeKomga extends Komga {
  FakeKomga() : super('http://test', 'k');
  final scopes = <String?>[]; // library each search was limited to
  Map<String, dynamic> page(List<Map<String, dynamic>> items) =>
      {'content': items, 'totalElements': items.length, 'last': true};

  @override
  Future<Map<String, dynamic>> searchSeries(String query, {String? libraryId, int size = 30}) async {
    scopes.add(libraryId);
    return page(query == 'surf'
        ? [{'id': 'S1', 'name': 'Silver Surfer', 'booksCount': 2, 'metadata': {'title': 'Silver Surfer'}}]
        : []);
  }

  @override
  Future<Map<String, dynamic>> searchBooks(String query, {String? libraryId, int size = 30}) async => page(query == 'surf'
      ? [
          for (var i = 1; i <= 2; i++)
            {'id': 'B$i', 'seriesTitle': 'Silver Surfer', 'name': 'b$i', 'metadata': {'number': '$i', 'title': 'T$i'}},
        ]
      : []);
  @override
  Future<Map<String, dynamic>> searchReadLists(String query, {String? libraryId, int size = 30}) async => page([]);
  @override
  Future<Map<String, dynamic>> searchCollections(String query, {String? libraryId, int size = 30}) async => page([]);
}

void main() {
  testWidgets('results appear as you type, in rows with counts; nothing found says so', (tester) async {
    SharedPreferences.setMockInitialValues({});
    await tester.pumpWidget(MaterialApp(home: SearchScreen(api: FakeKomga())));
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
    final api = FakeKomga();
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

  test('offline search looks through the downloaded titles', () async {
    final dir = await Directory.systemTemp.createTemp('komga_search_test');
    try {
      final api = OfflineKomga(await buildStore(dir));
      List<String> ids(Map<String, dynamic> r) => [for (final i in r['content'] as List) i['id'] as String];
      expect(ids(await api.searchSeries('surf')), ['S1']);
      expect(ids(await api.searchBooks('spider')), ['B3']); // matches the series title of the book
      expect(ids(await api.searchReadLists('event')), ['RL1']);
      expect(ids(await api.searchCollections('cosm')), ['C1']);
      expect(ids(await api.searchSeries('   ')), isEmpty);
    } finally {
      await dir.delete(recursive: true);
    }
  });
}
