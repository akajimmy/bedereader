// One top bar on the four browsing views (user, 2026-10-08, option B): the buttons in one order, Sort as a menu on
// every view with each view's fields, the sort remembered per view and kept by pins.
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:komga_reader/pins.dart';
import 'package:komga_reader/screens/library.dart';
import 'package:komga_reader/screens/readlist.dart';
import 'package:komga_reader/screens/series.dart';
import 'package:komga_reader/view_sort.dart';
import 'package:komga_reader/widgets/pin_tile.dart';
import 'package:komga_reader/widgets/readlist_tile.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/browse_server.dart';
import 'support/helpers.dart';
import 'support/no_network.dart';
import 'support/readlist_server.dart';

const series = {'id': 'S1', 'name': 'Silver Surfer', 'booksCount': 3, 'metadata': {'title': 'Silver Surfer'}};
const readList = {'id': 'RL3', 'name': 'Fresh'};

void main() {
  setUp(() => ReadListTile.invalidate());

  Future<BrowseServer> show(WidgetTester tester, Widget Function(BrowseServer api) screen) async {
    final api = noNetwork(BrowseServer.new);
    setView(tester, const Size(1600, 900));
    await tester.pumpWidget(MaterialApp(home: screen(api)));
    await tester.pump();
    await tester.pump();
    return api;
  }

  Future<BrowseServer> library(WidgetTester tester, {Pin? pin}) =>
      show(tester, (api) => LibraryScreen(key: UniqueKey(), api: api, onSignOut: () {}, libraryId: 'L1', pin: pin));
  Future<BrowseServer> seriesView(WidgetTester tester, {Pin? pin, Map<String, dynamic> s = series}) =>
      show(tester, (api) => SeriesScreen(key: UniqueKey(), api: api, series: s, pin: pin));
  Future<BrowseServer> collection(WidgetTester tester, {Pin? pin, String id = 'C1'}) =>
      show(tester, (api) => SeriesListScreen(key: UniqueKey(), api: api, title: 'Cosmic', collectionId: id, pin: pin));
  Future<BrowseServer> list(WidgetTester tester, {Pin? pin, Map<String, dynamic> rl = readList}) =>
      show(tester, (api) => ReadListScreen(key: UniqueKey(), api: api, readList: rl, pin: pin));

  /// Picks [item] ("release", "desc", ...) in the Sort menu.
  Future<void> sortBy(WidgetTester tester, String item) async {
    await tester.tap(find.byKey(const ValueKey('bar.sort')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(ValueKey('sort.$item')));
    await tester.pumpAndSettle();
  }

  Pin pinned(WidgetTester tester) => tester.widget<PinButton>(find.byType(PinButton)).current;

  Future<Map> saved(String key) async =>
      jsonDecode((await SharedPreferences.getInstance()).getString(key)!) as Map;

  testWidgets("a narrow window (650 px - Windows test plan, 2026-10-22): each view's title shortens beside the "
      "buttons rather than overflowing the bar", (tester) async {
    for (final (name, open) in [
      ('library', () => library(tester)),
      ('series', () => seriesView(tester)),
      ('collection', () => collection(tester)),
      ('read list', () => list(tester)),
    ]) {
      await open();
      setView(tester, const Size(650, 1000));
      await tester.pump();
      await tester.pump();
      expect(tester.takeException(), isNull, reason: '$name: no overflow');
    }
  });

  testWidgets('Refresh asks Komga again on a series, a collection and a read list', (tester) async {
    SharedPreferences.setMockInitialValues({});
    var api = await seriesView(tester);
    var before = api.sorts.length;
    await tester.tap(find.byKey(const ValueKey('bar.refresh')));
    await tester.pump();
    expect(api.sorts.length, before + 1);

    api = await collection(tester);
    before = api.requests.length;
    await tester.tap(find.byKey(const ValueKey('bar.refresh')));
    await tester.pump();
    expect(api.requests.length, before + 1);

    api = await list(tester);
    before = api.readListAsks.length;
    await tester.tap(find.byKey(const ValueKey('bar.refresh')));
    await tester.pump();
    expect(api.readListAsks.length, before + 1);
  });

  // ---- a series' books ------------------------------------------------------------------------------------------------

  testWidgets("a series' books sort by number, release date or date added, remembered for that series", (tester) async {
    SharedPreferences.setMockInitialValues({});
    var api = await seriesView(tester);
    expect(api.sorts.last, 'metadata.numberSort,asc');
    await sortBy(tester, 'release');
    expect(api.sorts.last, 'metadata.releaseDate,desc'); // a date starts newest first
    await sortBy(tester, 'added');
    expect(api.sorts.last, 'createdDate,desc');
    await sortBy(tester, 'asc');
    expect(api.sorts.last, 'createdDate,asc');
    expect(await saved('view.series.S1'), containsPair('sort', 'added'));

    api = await seriesView(tester); // reopened: remembered
    expect(api.sorts.last, 'createdDate,asc');
    api = await seriesView(tester, s: {...series, 'id': 'S2'}); // another series: its own (the default)
    expect(api.sorts.last, 'metadata.numberSort,asc');
  });

  testWidgets("a series' sort goes into its pin, and the pin opens in it; number:desc is still newest first",
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    await seriesView(tester);
    expect(pinned(tester).sort, isNull, reason: 'the default: none, as pins made before sorts');
    await sortBy(tester, 'desc');
    expect(pinned(tester).sort, 'number:desc', reason: 'newest first, as series pins always had it');
    await sortBy(tester, 'release');
    expect(pinned(tester).sort, 'release:desc');

    var api = await seriesView(tester, pin: const Pin(name: 'x', kind: 'series', id: 'S1', title: 'S', sort: 'release:asc'));
    expect(api.sorts.last, 'metadata.releaseDate,asc');
    api = await seriesView(tester, pin: const Pin(name: 'x', kind: 'series', id: 'S1', title: 'S', sort: 'number:desc'));
    expect(api.sorts.last, 'metadata.numberSort,desc');
    api = await seriesView(tester, pin: const Pin(name: 'x', kind: 'series', id: 'S1', title: 'S'));
    expect(api.sorts.last, 'metadata.numberSort,asc', reason: 'a pin with no sort (made before sorts): oldest first');
  });

  testWidgets("a series' saved filter is restored when it is opened again (its order, not saved, oldest first)",
      (tester) async {
    SharedPreferences.setMockInitialValues({'view.series.S1': jsonEncode({'filter': 'hideRead'})});
    final api = await seriesView(tester);
    expect(api.sorts.last, 'metadata.numberSort,asc');
    expect(find.byTooltip('Read hidden (hide unread)'), findsOneWidget);
  });

  testWidgets('pull down to refresh reloads the series from Komga (even when it is empty)', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final api = await seriesView(tester);
    final before = api.sorts.length;
    await tester.fling(find.byType(Scrollable).first, const Offset(0, 400), 1500);
    await tester.pump(); // start the refresh
    await tester.pump(const Duration(seconds: 1));
    await tester.pump(const Duration(seconds: 1));
    expect(api.sorts.length, greaterThan(before));
  });

  // ---- a collection's series -----------------------------------------------------------------------------------------

  testWidgets("a collection's series: its own order first, then title, release date, date added; remembered",
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    var api = await collection(tester);
    expect(api.requests.last, 'collectionSeries C1 p0 all');
    await sortBy(tester, 'title');
    expect((api.requests.last, api.sorts.last), ('series C1 p0 all', 'metadata.titleSort,asc'));
    await sortBy(tester, 'release');
    expect(api.sorts.last, 'booksMetadata.releaseDate,desc');
    await sortBy(tester, 'added');
    expect(api.sorts.last, 'createdDate,desc');
    expect(pinned(tester).sort, 'added:desc');
    expect(await saved('view.collection.C1'), containsPair('sort', 'added'));

    api = await collection(tester); // reopened: remembered
    expect(api.sorts.last, 'createdDate,desc');
    api = await collection(tester, pin: const Pin(name: 'x', kind: 'collection', id: 'C1', title: 'C'));
    expect(api.requests.last, 'collectionSeries C1 p0 all', reason: 'a pin without a sort: the collection order');
    api = await collection(tester, pin: const Pin(name: 'x', kind: 'collection', id: 'C1', title: 'C', sort: 'title:desc'));
    expect(api.sorts.last, 'metadata.titleSort,desc');
  });

  // ---- a read list's books -------------------------------------------------------------------------------------------

  testWidgets("a read list's books: the list's order, or by release date (Komga's book search); remembered",
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    var api = await list(tester);
    expect(api.readListAsks.last, 'RL3 p0 all');
    await sortBy(tester, 'release');
    expect(api.readListAsks.last, 'RL3 p0 all metadata.releaseDate,desc');
    await sortBy(tester, 'asc');
    expect(api.readListAsks.last, 'RL3 p0 all metadata.releaseDate,asc');
    expect(pinned(tester).sort, 'release:asc');
    expect(await saved('view.readlist.RL3'), containsPair('sort', 'release'));

    api = await list(tester); // reopened: remembered
    expect(api.readListAsks.last, 'RL3 p0 all metadata.releaseDate,asc');
    api = await list(tester, pin: const Pin(name: 'x', kind: 'readlist', id: 'RL3', title: 'F'));
    expect(api.readListAsks.last, 'RL3 p0 all', reason: 'a pin without a sort: the list order');
  });

  test("a read list's own order, last to first: all of it, reversed", () async {
    final api = noNetwork(() => ReadListServer([for (var i = 1; i <= 5; i++) listBook('$i')]));
    final r = await readListBooksPage(api, 'RL', const ViewSort('order', true), page: 0, size: 2);
    expect([for (final b in r['content'] as List) b['id']], ['5', '4', '3', '2', '1']);
    expect(r['last'], true);
  });

  // ---- the library's collections and read lists ---------------------------------------------------------------------

  testWidgets("the library's read lists sort by name or date updated; the pin keeps it", (tester) async {
    SharedPreferences.setMockInitialValues({'view.library.L1': jsonEncode({'mode': 'readLists'})});
    await library(tester);
    List<String> shown() {
      final names = ['Infinity', 'Done', 'Fresh'];
      final at = {for (final n in names) n: tester.getTopLeft(find.text(n).first)};
      return names..sort((a, b) => at[a]!.dy != at[b]!.dy ? at[a]!.dy.compareTo(at[b]!.dy) : at[a]!.dx.compareTo(at[b]!.dx));
    }

    expect(pinned(tester).sort, isNull, reason: 'the default: none, as pins made before');
    await sortBy(tester, 'updated');
    expect(shown(), ['Fresh', 'Infinity', 'Done'], reason: 'most recently updated first');
    expect(pinned(tester).sort, 'updated:desc');
    await sortBy(tester, 'title');
    await sortBy(tester, 'desc');
    expect(shown(), ['Infinity', 'Fresh', 'Done'], reason: 'Z -> A');

    final api = noNetwork(BrowseServer.new);
    final r = await pinView(api, const Pin(name: 'x', kind: 'library', id: 'L1', title: 'Events', mode: 'readLists',
        sort: 'updated:asc'));
    expect([for (final l in r['content'] as List) l['id']], ['RL2', 'RL1', 'RL3']);
  });

  // ---- pins' posters ask for what the screens ask for ---------------------------------------------------------------

  testWidgets("a pinned series', collection's and read list's poster asks Komga for the same as the screen, every sort",
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    for (final (kind, fields) in [('series', seriesBookSorts), ('collection', collectionSeriesSorts),
        ('readlist', readListBookSorts)]) {
      for (final f in fields) {
        for (final dir in const ['asc', 'desc']) {
          final pin = Pin(name: 'x', kind: kind, id: {'series': 'S1', 'collection': 'C1', 'readlist': 'RL3'}[kind],
              title: 'T', sort: '${f.key}:$dir');
          final api = switch (kind) {
            'series' => await seriesView(tester, pin: pin),
            'collection' => await collection(tester, pin: pin),
            _ => await list(tester, pin: pin),
          };
          String asked() => kind == 'readlist'
              ? api.readListAsks.last.replaceFirst(RegExp(r' p0'), '')
              : '${api.requests.last.replaceFirst(RegExp(r' p0.*'), '')} ${api.sorts.last}';
          final screen = asked();
          await tester.runAsync(() => pinView(api, pin));
          expect(asked(), screen, reason: '$kind ${f.key}:$dir');
        }
      }
    }
  });
}
