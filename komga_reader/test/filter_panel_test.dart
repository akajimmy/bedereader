// The filter panel and its chips (filters step 4, user 2026-10-08): what the panel asks Komga for, the live count,
// which sections a view gets, the chips, saving per view, pins, offline, and the remote.
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:komga_reader/api.dart';
import 'package:komga_reader/offline/offline_komga.dart';
import 'package:komga_reader/offline/store.dart';
import 'package:komga_reader/pins.dart';
import 'package:komga_reader/screens/library.dart';
import 'package:komga_reader/screens/readlist.dart';
import 'package:komga_reader/screens/series.dart';
import 'package:komga_reader/view_filter.dart';
import 'package:komga_reader/widgets/filter_panel.dart' show firstYear;
import 'package:komga_reader/widgets/pin_tile.dart';
import 'package:komga_reader/widgets/poster.dart';
import 'package:komga_reader/widgets/readlist_tile.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/browse_server.dart';
import 'support/helpers.dart';
import 'support/no_network.dart';
import 'support/offline_store.dart';

/// One filtered listing asked for: where, with which filter and read filter, how many.
typedef Asked = ({String where, ViewFilter filter, ReadFilter read, int size});

/// [BrowseServer] with the filter engine's calls answered: the filtered listings recorded (a filtered one answers
/// with one item), the value lists and the view's kind as set.
class FilterServer extends BrowseServer {
  final asked = <Asked>[];
  final searches = <String?>[];
  ViewKind kind = ViewKind.comics;
  List<String> writers = ['Al Ewing', 'Jonathan Hickman'], artists = ['Esad Ribic', 'Mike Allred'];
  List<String> publisherValues = ['DC', 'Marvel'], genreValues = ['Action', 'Horror'];
  Set<String> statusesHere = {'ONGOING', 'ENDED'};

  /// The listings asked for (pages - not the panel's counts and probes, which ask for one).
  List<Asked> get listings => [for (final a in asked) if (a.size > 1) a];

  @override
  Future<Map<String, dynamic>> filteredSeries({String? libraryId, String? collectionId,
      ReadFilter read = ReadFilter.all, ViewFilter filter = ViewFilter.none, String sort = 'metadata.titleSort,asc',
      int page = 0, int size = 60}) async {
    asked.add((where: 'series ${collectionId ?? libraryId}', filter: filter, read: read, size: size));
    final f = filter.forView(seriesView: true);
    if (f.statuses.length == 1 && f.copyWith(statuses: const []).isEmpty) { // (the panel's status probes, too)
      final n = statusesHere.contains(f.statuses.single) ? 1 : 0;
      return {'content': [], 'totalElements': n, 'last': true};
    }
    if (f.isEmpty) {
      return super.filteredSeries(libraryId: libraryId, collectionId: collectionId, read: read, sort: sort,
          page: page, size: size);
    }
    return {'content': [_series1], 'totalElements': 1, 'last': true};
  }

  static const _series1 = {'id': 'S1', 'name': 'Series 1', 'libraryId': 'L1', 'metadata': {'title': 'Series 1'},
      'booksCount': 1, 'booksUnreadCount': 1, 'booksInProgressCount': 0};

  @override
  Future<Map<String, dynamic>> filteredBooks({String? libraryId, String? seriesId, String? readListId,
      ReadFilter read = ReadFilter.all, ViewFilter filter = ViewFilter.none, String? sort, int page = 0,
      int? size}) async {
    asked.add((where: 'books ${seriesId ?? readListId ?? libraryId}', filter: filter, read: read, size: size ?? 60));
    if (filter.forView(seriesView: false).isEmpty) {
      return super.filteredBooks(libraryId: libraryId, seriesId: seriesId, readListId: readListId, read: read,
          sort: sort, page: page, size: size);
    }
    return {'content': [shelf[1]], 'totalElements': 1, 'last': true};
  }

  @override
  Future<List<String>> authorNames(List<String> roles, {String? search, String? libraryId, String? collectionId,
      String? seriesId, String? readListId, int size = 1000}) async {
    if (size > 1) searches.add(search);
    final q = (search ?? '').toLowerCase();
    return [for (final n in roles.contains('writer') ? writers : artists) if (n.toLowerCase().contains(q)) n]
        .take(size)
        .toList();
  }

  @override
  Future<List<String>> publishers({String? libraryId, String? collectionId}) async => publisherValues;
  @override
  Future<List<String>> genres({String? libraryId, String? collectionId}) async => genreValues;
  /// A collection in its own order: Series 3, 2, 1 (not by title).
  @override
  Future<Map<String, dynamic>> collectionSeries(String collectionId, {List<String>? readStatus, int page = 0,
      int size = 60}) async {
    final all = [for (final i in [3, 2, 1]) {..._series1, 'id': 'S$i', 'name': 'Series $i'}];
    final from = (page * size).clamp(0, all.length), to = ((page + 1) * size).clamp(0, all.length);
    return {'content': all.sublist(from, to), 'totalElements': all.length, 'last': to >= all.length};
  }

  @override
  Future<ViewKind> viewKind({String? libraryId, String? seriesId, String? readListId}) async => kind;
}

const series = {'id': 'S1', 'name': 'Saga', 'metadata': {'title': 'Saga'}};
const readList = {'id': 'RL3', 'name': 'Fresh'};

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    ReadListTile.invalidate();
  });

  Future<T> show<T extends Komga>(WidgetTester tester, T api, Widget screen, {Size size = const Size(1400, 900)})
      async {
    setView(tester, size);
    await tester.pumpWidget(MaterialApp(home: screen));
    await tester.pump();
    await tester.pump();
    return api;
  }

  FilterServer server([void Function(FilterServer s)? setUp]) {
    final s = noNetwork(FilterServer.new);
    setUp?.call(s);
    return s;
  }

  Future<FilterServer> library(WidgetTester tester, {FilterServer? api, Pin? pin, String mode = 'series'}) async {
    final s = api ?? server();
    if (pin == null) {
      final prefs = await SharedPreferences.getInstance();
      final v = jsonDecode(prefs.getString('view.library.L1') ?? '{}') as Map<String, dynamic>;
      await prefs.setString('view.library.L1', jsonEncode({...v, 'mode': mode}));
    }
    return show(tester, s, LibraryScreen(key: UniqueKey(), api: s, onSignOut: () {}, libraryId: 'L1', pin: pin));
  }

  /// A few frames, past the panel's slide-in and the count's wait.
  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 4; i++) {
      await tester.pump();
    }
    await tester.pump(const Duration(milliseconds: 400));
    for (var i = 0; i < 4; i++) {
      await tester.pump();
    }
  }

  Future<void> openPanel(WidgetTester tester) async {
    await tester.tap(find.byKey(const ValueKey('bar.filter')));
    await settle(tester);
  }

  Future<void> tapKey(WidgetTester tester, String key) async {
    await tester.ensureVisible(find.byKey(ValueKey(key)));
    await tester.pump();
    await tester.tap(find.byKey(ValueKey(key)));
    await settle(tester);
  }

  bool section(String name) => find.byKey(ValueKey('filter.section.$name')).evaluate().isNotEmpty;

  // years near the top of the newest-first lists (the menu shows them without scrolling)
  final thisYear = DateTime.now().year, lastYear = DateTime.now().year - 1;

  /// Pick [year] (null: Any) in the From or To year list.
  Future<void> pickYear(WidgetTester tester, String which, int? year) async {
    await tapKey(tester, 'filter.$which');
    await tester.tap(find.text(year == null ? 'Any' : '$year').last);
    await settle(tester);
  }

  /// Add [names] through the writer / artist picker.
  Future<void> pickNames(WidgetTester tester, String field, List<String> names) async {
    await tapKey(tester, 'filter.add.$field');
    for (final n in names) {
      await tapKey(tester, 'filter.pick.$n');
    }
    await tapKey(tester, 'filter.pickDone');
  }

  Future<Map<String, dynamic>> saved(String key) async =>
      jsonDecode((await SharedPreferences.getInstance()).getString(key)!) as Map<String, dynamic>;

  // ---- choosing and applying ----------------------------------------------------------------------------------------

  testWidgets('choosing filters in the panel and Show lists the series with them (one search, all of them)',
      (tester) async {
    final api = await library(tester);
    expect(api.listings.last.filter, ViewFilter.none);
    await openPanel(tester);
    await pickNames(tester, 'writer', ['Jonathan Hickman']);
    expect(api.searches, isNotEmpty, reason: "the picker lists Komga's names");
    await tapKey(tester, 'filter.publisher.Marvel');
    await tapKey(tester, 'filter.status.ENDED');
    await pickYear(tester, 'from', lastYear); // (To follows: that year only)
    final before = api.listings.length;
    await tapKey(tester, 'filter.show');

    expect(api.listings.length, before + 1);
    expect(api.listings.last.filter, ViewFilter(writers: const ['Jonathan Hickman'], publishers: const ['Marvel'],
        statuses: const ['ENDED'], fromYear: lastYear, toYear: lastYear));
    expect(api.listings.last.where, 'series L1');
    expect(find.byType(PosterTile), findsOneWidget, reason: 'what Komga answered');
    for (final c in ['writer', 'publisher', 'status', 'years']) {
      expect(find.byKey(ValueKey('filter.chip.$c')), findsOneWidget, reason: 'its chip under the bar');
    }
  });

  testWidgets('Cancel and Back close the panel without applying anything', (tester) async {
    final api = await library(tester);
    await openPanel(tester);
    await tapKey(tester, 'filter.publisher.Marvel');
    final before = api.listings.length;
    await tapKey(tester, 'filter.cancel');
    expect(find.byKey(const ValueKey('filter.show')), findsNothing);
    expect(api.listings.length, before);

    await openPanel(tester);
    await tapKey(tester, 'filter.publisher.DC');
    await tester.binding.handlePopRoute(); // the remote's / Android's Back
    await settle(tester);
    expect(find.byKey(const ValueKey('filter.show')), findsNothing);
    expect(api.listings.length, before);
    expect(find.byKey(const ValueKey('filter.chip.publisher')), findsNothing);
  });

  testWidgets('the live count asks Komga with the draft (one item), as it changes', (tester) async {
    final api = await library(tester);
    await openPanel(tester);
    List<ViewFilter> counts() => [for (final a in api.asked) if (a.size == 1 && a.filter.statuses.isEmpty) a.filter];
    expect(counts().last, ViewFilter.none, reason: 'the view as it is, on opening');
    await tapKey(tester, 'filter.publisher.Marvel');
    expect(counts().last, const ViewFilter(publishers: ['Marvel']));
    await tapKey(tester, 'filter.genre.Horror');
    expect(counts().last, const ViewFilter(publishers: ['Marvel'], genres: ['Horror']));
    expect(api.listings.last.filter, ViewFilter.none, reason: 'nothing applied yet');

    // with the eye on, the count keeps it
    await tapKey(tester, 'filter.cancel');
    await tester.tap(find.byKey(const ValueKey('bar.eye')));
    await settle(tester);
    await openPanel(tester);
    final last = api.asked.lastWhere((a) => a.size == 1 && a.filter.statuses.isEmpty);
    expect(last.read, ReadFilter.hideRead);
  });

  // ---- the chips ----------------------------------------------------------------------------------------------------

  testWidgets('a chip removes its filter, Clear removes them all; saved each time', (tester) async {
    SharedPreferences.setMockInitialValues({'view.library.L1': jsonEncode({
      'mode': 'series', 'filters': const ViewFilter(writers: ['Al Ewing'], publishers: ['Marvel']).toJson(),
    })});
    final api = await library(tester);
    expect(api.listings.last.filter, const ViewFilter(writers: ['Al Ewing'], publishers: ['Marvel']),
        reason: 'restored');
    await tapKey(tester, 'filter.chip.publisher');
    expect(api.listings.last.filter, const ViewFilter(writers: ['Al Ewing']));
    expect(ViewFilter.fromJson((await saved('view.library.L1'))['filters']), const ViewFilter(writers: ['Al Ewing']));
    await tapKey(tester, 'filter.chip.clear');
    expect(api.listings.last.filter, ViewFilter.none);
    expect(api.requests.last, 'series p0 all', reason: 'unfiltered: the plain listing again');
    expect((await saved('view.library.L1')).containsKey('filters'), isFalse);
    expect(find.byKey(const ValueKey('filter.chip.clear')), findsNothing);
  });

  testWidgets('no Clear filters button in the top bar - clearing is in the panel (user, 2026-10-08)', (tester) async {
    SharedPreferences.setMockInitialValues({'view.library.L1': jsonEncode({
      'mode': 'books', 'filter': 'hideRead', 'sort': 'title', 'desc': true,
      'filters': const ViewFilter(writers: ['Al Ewing']).toJson(),
    })});
    await library(tester, mode: 'books');
    expect(find.byKey(const ValueKey('bar.clear')), findsNothing, reason: 'filters, the eye and a sort all on');
  });

  testWidgets('the funnel is filled with the accent while filters are on, plain when none (user, 2026-10-08)',
      (tester) async {
    SharedPreferences.setMockInitialValues({'view.library.L1': jsonEncode({
      'mode': 'series', 'filters': const ViewFilter(publishers: ['Marvel']).toJson(),
    })});
    await library(tester);
    IconButton funnel() => tester.widget<IconButton>(find.descendant(
        of: find.byKey(const ValueKey('bar.filter')), matching: find.byType(IconButton)));
    final accent = Theme.of(tester.element(find.byKey(const ValueKey('bar.filter')))).colorScheme.primary;
    Color? fill() => funnel().style?.backgroundColor?.resolve({});
    expect(fill(), accent, reason: 'a filter on');
    await tapKey(tester, 'filter.chip.clear');
    expect(fill(), isNot(accent), reason: 'none on');
  });

  testWidgets("the filled funnel gives way to the remote's focus look (its outline vanished into the fill, build 101)",
      (tester) async {
    SharedPreferences.setMockInitialValues({'view.library.L1': jsonEncode({
      'mode': 'series', 'filters': const ViewFilter(publishers: ['Marvel']).toJson(),
    })});
    await library(tester);
    addTearDown(() => FocusManager.instance.highlightStrategy = FocusHighlightStrategy.automatic);
    FocusManager.instance.highlightStrategy = FocusHighlightStrategy.alwaysTraditional; // the remote in use
    final funnel = tester.widget<IconButton>(find.descendant(
        of: find.byKey(const ValueKey('bar.filter')), matching: find.byType(IconButton)));
    final accent = Theme.of(tester.element(find.byKey(const ValueKey('bar.filter')))).colorScheme.primary;
    expect(funnel.style?.backgroundColor?.resolve({}), accent, reason: 'filled, not focused');
    expect(funnel.style?.backgroundColor?.resolve({WidgetState.focused}), isNull,
        reason: "focused: the theme's focus fill and outline");
    expect(funnel.style?.iconColor?.resolve({WidgetState.focused}), isNull);
  });

  testWidgets('the name picker says when its list was cut (more than 50 names), not when it holds them all',
      (tester) async {
    Future<void> openPicker(int names) async {
      await tester.pumpWidget(const SizedBox()); // the last one's panel and picker gone
      await library(tester, api: server((s) => s.writers = [
            for (var i = 0; i < names; i++) 'Writer ${i.toString().padLeft(2, '0')}',
          ]));
      await openPanel(tester);
      await tapKey(tester, 'filter.add.writer');
    }

    final list = find.descendant(of: find.byType(AlertDialog), matching: find.byType(Scrollable)).last; // (first: the search field's)

    await openPicker(51);
    await tester.scrollUntilVisible(find.byKey(const ValueKey('filter.pickMore')), 300, scrollable: list);
    expect(find.byKey(const ValueKey('filter.pick.Writer 49')), findsOneWidget, reason: 'the 50th is listed');
    expect(find.byKey(const ValueKey('filter.pick.Writer 50')), findsNothing, reason: 'the 51st is not');

    await openPicker(50);
    await tester.scrollUntilVisible(find.byKey(const ValueKey('filter.pick.Writer 49')), 300, scrollable: list);
    await tester.pump();
    expect(find.byKey(const ValueKey('filter.pickMore')), findsNothing, reason: 'all 50 are there');
  });

  // ---- which sections ----------------------------------------------------------------------------------------------

  testWidgets('series filters (publisher, status, genre) only in series views', (tester) async {
    await library(tester);
    await openPanel(tester);
    for (final s in ['writer', 'artist', 'years', 'publisher', 'status', 'genre']) {
      expect(section(s), isTrue, reason: 'library series: $s');
    }
    await tapKey(tester, 'filter.cancel');

    for (final open in <Future<void> Function()>[
      () => library(tester, mode: 'books'),
      () => show(tester, server(), SeriesScreen(key: UniqueKey(), api: server(), series: series)),
      () => show(tester, server(), ReadListScreen(key: UniqueKey(), api: server(), readList: readList)),
    ]) {
      await open();
      await openPanel(tester);
      expect(section('writer'), isTrue);
      expect(section('years'), isTrue);
      for (final s in ['publisher', 'status', 'genre']) {
        expect(section(s), isFalse, reason: 'a book view: $s');
      }
      await tapKey(tester, 'filter.cancel');
    }

    final c = server();
    await show(tester, c, SeriesListScreen(key: UniqueKey(), api: c, title: 'Cosmic', collectionId: 'C1'));
    await openPanel(tester);
    expect(section('publisher'), isTrue, reason: 'a collection lists series');
  });

  testWidgets('a filter with fewer than two values in the view is left out (writer / artist: any; years: always)',
      (tester) async {
    await library(tester, api: server((s) {
      s.writers = ['Al Ewing'];
      s.artists = [];
      s.publisherValues = ['Marvel'];
      s.genreValues = [];
      s.statusesHere = {'ONGOING'};
    }));
    await openPanel(tester);
    expect(section('writer'), isTrue, reason: 'one writer is enough');
    expect(section('years'), isTrue, reason: 'any year can be asked for');
    for (final s in ['artist', 'publisher', 'genre', 'status']) {
      expect(section(s), isFalse, reason: s);
    }
  });

  testWidgets("release years: the same list in every view (this year back to 1800); From fills To", (tester) async {
    final api = await library(tester);
    await openPanel(tester);
    List<int?> offered(String which) => [
          for (final i in tester.widget<DropdownButton<int?>>(find.byKey(ValueKey('filter.$which'))).items!) i.value,
        ];
    expect(offered('from').first, isNull, reason: 'Any');
    expect(offered('from')[1], thisYear, reason: 'newest first');
    expect(offered('from').last, firstYear);
    expect(offered('to'), offered('from'));

    await pickYear(tester, 'from', lastYear);
    await tapKey(tester, 'filter.show');
    expect(api.listings.last.filter, ViewFilter(fromYear: lastYear, toYear: lastYear), reason: 'one pick: that year');

    await openPanel(tester);
    await pickYear(tester, 'to', null);
    await tapKey(tester, 'filter.show');
    expect(api.listings.last.filter, ViewFilter(fromYear: lastYear), reason: 'To back to Any: that year and later');

    await openPanel(tester);
    await pickYear(tester, 'to', thisYear);
    await pickYear(tester, 'from', lastYear);
    await tapKey(tester, 'filter.show');
    expect(api.listings.last.filter, ViewFilter(fromYear: lastYear, toYear: thisYear),
        reason: 'a To already after From stays: a range');
  });

  testWidgets('no Artist for eBooks; the kind is asked once', (tester) async {
    await library(tester, api: server((s) => s.kind = ViewKind.ebooks));
    await openPanel(tester);
    expect(section('writer'), isTrue);
    expect(section('artist'), isFalse);
    await tapKey(tester, 'filter.cancel');

    await library(tester, api: server((s) => s.kind = ViewKind.mixed));
    await openPanel(tester);
    expect(section('artist'), isTrue, reason: 'comics and eBooks together: artists may be there');
  });

  test("a series' kind from its books' media profiles; a view's from Komga's two searches", () async {
    expect(ViewKind.ofProfiles(['EPUB', 'EPUB']), ViewKind.ebooks);
    expect(ViewKind.ofProfiles(['DIVINA', 'PDF']), ViewKind.comics);
    expect(ViewKind.ofProfiles(['EPUB', 'DIVINA']), ViewKind.mixed);
    expect(ViewKind.combine([ViewKind.comics, ViewKind.ebooks]), ViewKind.mixed);
  });

  // ---- remembered, pinned --------------------------------------------------------------------------------------------

  testWidgets("a collection's filters are saved with it and restored when it's opened again", (tester) async {
    var c = server();
    await show(tester, c, SeriesListScreen(key: UniqueKey(), api: c, title: 'Cosmic', collectionId: 'C1'));
    await openPanel(tester);
    await tapKey(tester, 'filter.genre.Horror');
    await tapKey(tester, 'filter.show');
    expect(c.listings.last.filter, const ViewFilter(genres: ['Horror']));
    expect(ViewFilter.fromJson((await saved('view.collection.C1'))['filters']), const ViewFilter(genres: ['Horror']));

    c = server();
    await show(tester, c, SeriesListScreen(key: UniqueKey(), api: c, title: 'Cosmic', collectionId: 'C1'));
    expect(c.listings.first.filter, const ViewFilter(genres: ['Horror']), reason: 'the first listing has them');
    expect(find.byKey(const ValueKey('filter.chip.genre')), findsOneWidget);
  });

  testWidgets("a series' and a read list's filters, saved and restored", (tester) async {
    var s = server();
    await show(tester, s, SeriesScreen(key: UniqueKey(), api: s, series: series));
    await openPanel(tester);
    await pickNames(tester, 'artist', ['Esad Ribic']);
    await tapKey(tester, 'filter.show');
    expect(s.listings.last.filter, const ViewFilter(artists: ['Esad Ribic']));
    expect(s.listings.last.where, 'books S1');
    s = server();
    await show(tester, s, SeriesScreen(key: UniqueKey(), api: s, series: series));
    expect(s.listings.first.filter, const ViewFilter(artists: ['Esad Ribic']));

    var r = server();
    await show(tester, r, ReadListScreen(key: UniqueKey(), api: r, readList: readList));
    await openPanel(tester);
    await pickYear(tester, 'to', thisYear);
    await pickYear(tester, 'from', lastYear);
    await tapKey(tester, 'filter.show');
    expect(r.listings.last.filter, ViewFilter(fromYear: lastYear, toYear: thisYear));
    r = server();
    await show(tester, r, ReadListScreen(key: UniqueKey(), api: r, readList: readList));
    expect(r.listings.first.filter, ViewFilter(fromYear: lastYear, toYear: thisYear));
  });

  testWidgets('a pin keeps the filters, and opening it applies them', (tester) async {
    final api = await library(tester, mode: 'books');
    await openPanel(tester);
    await pickNames(tester, 'writer', ['Al Ewing']);
    await tapKey(tester, 'filter.show');
    final pin = tester.widget<PinButton>(find.byType(PinButton)).current;
    expect(pin.filters, const ViewFilter(writers: ['Al Ewing']));
    expect(api.listings.last.filter, pin.filters);

    SharedPreferences.setMockInitialValues({});
    final opened = await library(tester, pin: Pin.fromJson(pin.toJson())); // (as kept)
    expect(opened.listings.first.filter, const ViewFilter(writers: ['Al Ewing']));
    expect(opened.listings.first.where, 'books L1');
    expect(find.byKey(const ValueKey('filter.chip.writer')), findsOneWidget);

    const seriesPin = Pin(name: 'x', kind: 'series', id: 'S1', title: 'Saga', filters: ViewFilter(fromYear: 2015));
    final s = server();
    await show(tester, s, SeriesScreen(key: UniqueKey(), api: s, series: series, pin: seriesPin));
    expect(s.listings.first.filter, const ViewFilter(fromYear: 2015));
  });

  test("a pin's poster on Home asks with its filters, like the screen", () async {
    final api = noNetwork(FilterServer.new);
    for (final (pin, where) in [
      (const Pin(name: 'x', kind: 'library', id: 'L1', title: 'E', mode: 'series',
          filters: ViewFilter(publishers: ['Marvel'])), 'series L1'),
      (const Pin(name: 'x', kind: 'library', id: 'L1', title: 'E', mode: 'books',
          filters: ViewFilter(writers: ['Al Ewing'])), 'books L1'),
      (const Pin(name: 'x', kind: 'series', id: 'S1', title: 'S', filters: ViewFilter(toYear: 2015)), 'books S1'),
      (const Pin(name: 'x', kind: 'readlist', id: 'RL3', title: 'R', filters: ViewFilter(toYear: 2015)), 'books RL3'),
      (const Pin(name: 'x', kind: 'collection', id: 'C1', title: 'C', sort: 'title:asc',
          filters: ViewFilter(genres: ['Horror'])), 'series C1'),
    ]) {
      final r = await pinView(api, pin);
      expect(api.asked.last.where, where);
      expect(api.asked.last.filter, pin.filters, reason: where);
      expect(r['totalElements'], 1, reason: 'the filtered answer');
    }
  });

  test("a filtered collection in its own order: the matching series, in the collection's order", () async {
    final api = noNetwork(FilterServer.new);
    final r = await pinView(api, const Pin(name: 'x', kind: 'collection', id: 'C1', title: 'C',
        filters: ViewFilter(genres: ['Horror'])));
    expect(api.asked.last.filter, const ViewFilter(genres: ['Horror']));
    expect([for (final s in r['content'] as List) s['id']], ['S1'], reason: 'the collection holds S3, S2, S1');
    final unfiltered = await pinView(api, const Pin(name: 'x', kind: 'collection', id: 'C1', title: 'C'));
    expect([for (final s in unfiltered['content'] as List) s['id']], ['S3', 'S2', 'S1']);
  });

  // ---- offline ------------------------------------------------------------------------------------------------------

  testWidgets('offline: the panel filters the downloads', (tester) async {
    late Directory dir;
    late OfflineStore store;
    await tester.runAsync(() async {
      dir = await Directory.systemTemp.createTemp('komga_filter_panel');
      store = await buildStore(dir);
      Future<void> authors(String id, String date, String writer) async {
        final e = Map<String, dynamic>.from(store.books[id]!);
        final b = Map<String, dynamic>.from(e['book'] as Map);
        b['metadata'] = {...(b['metadata'] as Map), 'releaseDate': date, 'authors': [{'name': writer, 'role': 'writer'}]};
        e['book'] = b;
        await store.put(id, e);
      }
      await authors('B1', '2014-05-01', 'Dan Slott');
      await authors('B2', '2015-01-01', 'Dan Slott');
      await authors('B5', '2016-12-31', 'Dan Slott');
      await authors('B3', '2020-02-02', 'Jonathan Hickman');
    });
    addTearDown(() => deleteTemp(dir));
    final api = OfflineKomga(store);
    SharedPreferences.setMockInitialValues({'view.library.L1': jsonEncode({'mode': 'books'})});
    await show(tester, api, LibraryScreen(key: UniqueKey(), api: api, onSignOut: () {}, libraryId: 'L1'));
    await settle(tester);
    expect(find.byType(PosterTile), findsNWidgets(4));

    await openPanel(tester);
    await pickNames(tester, 'writer', ['Jonathan Hickman']);
    await tapKey(tester, 'filter.show');
    expect(find.byType(PosterTile), findsOneWidget, reason: "Hickman's book only");
  });

  // ---- the remote ----------------------------------------------------------------------------------------------------

  testWidgets('the panel by keys alone: the first filter has the focus, Down reaches Show, OK applies',
      (tester) async {
    final api = await library(tester, api: server((s) {
      s.writers = []; // (the first section: the years)
      s.artists = [];
    }));
    await openPanel(tester);

    /// Whether the focus is on (or in) the widget keyed [key].
    bool focusOn(String key) {
      final ctx = FocusManager.instance.primaryFocus?.context;
      if (ctx == null) return false;
      var found = ctx.widget.key == ValueKey(key);
      ctx.visitAncestorElements((e) {
        if (e.widget.key == ValueKey(key)) found = true;
        return !found;
      });
      return found;
    }

    Future<void> press(LogicalKeyboardKey k) async {
      await tester.sendKeyEvent(k);
      await settle(tester);
    }

    expect(focusOn('filter.from'), isTrue, reason: 'the first control of the first section');
    for (var i = 0; i < 20 && !focusOn('filter.publisher.Marvel'); i++) {
      await press(LogicalKeyboardKey.arrowDown);
    }
    expect(focusOn('filter.publisher.Marvel'), isTrue);
    await press(LogicalKeyboardKey.enter); // ticks it
    for (var i = 0; i < 20 && !focusOn('filter.show'); i++) {
      await press(LogicalKeyboardKey.arrowDown);
    }
    expect(focusOn('filter.show'), isTrue, reason: 'Down from the last filter reaches Show');
    await press(LogicalKeyboardKey.enter);
    expect(find.byKey(const ValueKey('filter.show')), findsNothing, reason: 'closed');
    expect(api.listings.last.filter, const ViewFilter(publishers: ['Marvel']));
  });
}
