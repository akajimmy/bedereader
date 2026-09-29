import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:komga_reader/api.dart';
import 'package:komga_reader/pins.dart';
import 'package:komga_reader/screens/series.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Records the sort each series-books request asks for.
class FakeKomga extends Komga {
  FakeKomga() : super('http://test', 'k');
  final sorts = <String>[];
  @override
  Future<Map<String, dynamic>> seriesBooks(String seriesId, {List<String>? readStatus, String sort = '', int page = 0,
      int size = 500}) async {
    sorts.add(sort);
    return {'content': [], 'totalElements': 0, 'last': true};
  }
}

const series = {'id': 'S1', 'name': 'Silver Surfer', 'booksCount': 3, 'metadata': {'title': 'Silver Surfer'}};

void main() {
  Future<FakeKomga> open(WidgetTester tester, {Pin? pin}) async {
    final api = FakeKomga();
    await tester.pumpWidget(MaterialApp(home: SeriesScreen(key: UniqueKey(), api: api, series: series, pin: pin)));
    await tester.pump();
    await tester.pump();
    return api;
  }

  testWidgets('series order: oldest first by default, one tap for newest first, remembered', (tester) async {
    SharedPreferences.setMockInitialValues({});
    var api = await open(tester);
    expect(api.sorts.last, 'metadata.numberSort,asc');
    await tester.tap(find.byTooltip('Oldest first (switch to newest first)'));
    await tester.pump();
    expect(api.sorts.last, 'metadata.numberSort,desc');
    final saved = jsonDecode((await SharedPreferences.getInstance()).getString('view.series.S1')!) as Map;
    expect(saved['newestFirst'], true);

    api = await open(tester); // reopen: remembered
    expect(api.sorts.last, 'metadata.numberSort,desc');
    expect(find.byTooltip('Newest first (switch to oldest first)'), findsOneWidget);
  });

  testWidgets('a filter saved before this change still loads (and order defaults to oldest first)', (tester) async {
    SharedPreferences.setMockInitialValues({'view.series.S1': jsonEncode({'filter': 'hideRead'})});
    final api = await open(tester);
    expect(api.sorts.last, 'metadata.numberSort,asc');
    expect(find.byTooltip('Read hidden (show read)'), findsOneWidget);
  });

  testWidgets('pins: "number:desc" opens newest first; older series pins (no sort) open oldest first', (tester) async {
    SharedPreferences.setMockInitialValues({});
    var api = await open(tester, pin: const Pin(name: 'x', kind: 'series', id: 'S1', title: 'Silver Surfer', sort: 'number:desc'));
    expect(api.sorts.last, 'metadata.numberSort,desc');
    api = await open(tester, pin: const Pin(name: 'x', kind: 'series', id: 'S1', title: 'Silver Surfer'));
    expect(api.sorts.last, 'metadata.numberSort,asc');
  });

  testWidgets('pull down to refresh reloads the series from Komga (even when it is empty)', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final api = await open(tester);
    final before = api.sorts.length;
    await tester.fling(find.byType(Scrollable).first, const Offset(0, 400), 1500);
    await tester.pump(); // start the refresh
    await tester.pump(const Duration(seconds: 1));
    await tester.pump(const Duration(seconds: 1));
    expect(api.sorts.length, greaterThan(before));
  });
}

