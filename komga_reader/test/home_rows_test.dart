// home rows (test audit, 2026-10-23: row_arrows_test.dart folded in).
import 'dart:convert';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:komga_reader/api.dart';
import 'package:komga_reader/home_sections.dart';
import 'package:komga_reader/pins.dart';
import 'package:komga_reader/screens/home.dart';
import 'package:komga_reader/screens/library.dart';
import 'package:komga_reader/screens/readlist.dart';
import 'package:komga_reader/screens/series.dart';
import 'package:komga_reader/settings.dart';
import 'package:komga_reader/widgets/poster_row.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/client_settings.dart';
import 'support/helpers.dart';
import 'support/home_server.dart';
import 'support/no_network.dart';

// Home's rows and pins (test audit, 2026-09-30: only the section menu and order had tests).

Map<String, dynamic> book(String id, String series, int n) =>
    {'id': id, 'seriesId': 'S1', 'seriesTitle': series, 'name': id, 'metadata': {'number': '$n', 'title': 'T$id'}};

/// A Komga with one book for each of Home's rows - unless [empty] - told apart by the query each row runs; series
/// S1 "Saga", read list RL1 "Infinity" and collection C1 "Marvel cosmic", and a series and a read list deleted from
/// the server ("gone"). Komga's client settings are kept, for the pins.
class HomeRowsServer extends HomeServer with ClientSettingsStore {
  HomeRowsServer({this.empty = false})
      : super(inProgressBooks: empty ? const [] : [book('C1', 'Ongoing', 4)],
            onDeckBooks: empty ? const [] : [book('D1', 'Next Up', 2)]);
  final bool empty;
  final asked = <String>[]; // the queries the rows ran

  List<Map<String, dynamic>> _one(Map<String, dynamic> b) => empty ? [] : [b];

  @override
  Future<Map<String, dynamic>> books({String? libraryId, List<String>? readStatus,
      String sort = 'metadata.releaseDate,desc', int page = 0, int size = 60}) async {
    asked.add('books ${libraryId ?? '-'} ${readStatus?.join('+') ?? 'all'} $sort');
    if (libraryId != null) return onePage([]); // a pinned library's view
    return onePage(switch ((readStatus?.join('+'), sort)) {
      ('READ', 'readProgress.readDate,desc') => _one(book('R1', 'Read Series', 1)),
      (null, 'createdDate,desc') => _one(book('N1', 'New Series', 1)),
      (null, 'metadata.releaseDate,desc') => _one(book('X1', 'Fresh Release', 1)),
      _ => throw StateError('no Home row asks for books $readStatus $sort'),
    });
  }

  @override
  Future<Map<String, dynamic>> series({String? libraryId, String? collectionId, List<String>? readStatus,
      String sort = 'metadata.titleSort,asc', int page = 0, int size = 60}) async {
    asked.add('series ${libraryId ?? '-'} ${collectionId ?? '-'} $sort');
    if (collectionId != null || libraryId != null) return onePage([]); // a pinned collection's / library's view
    if (sort != 'createdDate,desc') throw StateError('no Home row asks for series sorted $sort');
    return onePage(_one({'id': 'S9', 'name': 'Brand New Series', 'metadata': {'title': 'Brand New Series'},
        'booksCount': 1, 'booksUnreadCount': 1, 'booksInProgressCount': 0}));
  }

  /// A pinned collection's view (in the collection's own order: its default sort).
  @override
  Future<Map<String, dynamic>> collectionSeries(String collectionId, {List<String>? readStatus, int page = 0,
      int size = 60}) async {
    asked.add('collectionSeries $collectionId');
    return onePage([]);
  }

  // pins: the views and the things themselves
  @override
  Future<Map<String, dynamic>?> oneSeries(String id) async =>
      id == 'S1' ? {'id': 'S1', 'name': 'Saga', 'metadata': {'title': 'Saga'}, 'libraryId': 'L1'} : null;
  @override
  Future<Map<String, dynamic>?> readList(String id) async =>
      id == 'RL1' ? {'id': 'RL1', 'name': 'Infinity', 'bookIds': <String>[]} : null;
  @override
  Future<Map<String, dynamic>> seriesBooks(String seriesId, {List<String>? readStatus,
      String sort = 'metadata.numberSort,asc', int page = 0, int size = 500}) async {
    if (seriesId != 'S1') throw KomgaError(404, '/api/v1/series/$seriesId/books'); // gone
    return onePage([]);
  }

  @override
  Future<Map<String, dynamic>> readListBooks(String readListId, {List<String>? readStatus, int page = 0,
      int size = 1000}) async {
    if (readListId != 'RL1') throw KomgaError(404, '/api/v1/readlists/$readListId/books');
    return onePage([]);
  }
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    AppSettings.instance.library = const LibraryPrefs(); // Home's sections: synced settings now (2026-10-22)
  });

  /// Home, tall enough for every row, with every section switched on.
  Future<HomeRowsServer> open(WidgetTester tester, {bool empty = false, List<Pin> pins = const []}) async {
    setView(tester, const Size(1280, 3000));
    AppSettings.instance.library = LibraryPrefs(homeShown: {for (final k in HomeSections.names.keys) k: true});
    final api = noNetwork(() => HomeRowsServer(empty: empty));
    api.written[Pins.komgaKey] = jsonEncode([for (final p in pins) p.toJson()]);
    await Pins.instance.load(api);
    addTearDown(Pins.instance.clearAccount); // all of it: the server, what's unsent, a retry timer
    await tester.pumpWidget(MaterialApp(home: HomeScreen(api: api, onSignOut: () {})));
    await tester.pump();
    await tester.pump();
    return api;
  }

  Finder inRow(String row, String item) => find.descendant(
      of: find.ancestor(of: find.text(row), matching: find.byType(PosterRow)), matching: find.text(item));

  testWidgets('a mouse click on a poster that moves a pixel or two while pressed still opens it - the side menu\'s '
      'swipe took it for a drag, and the click went missing (user, build 107: "dropped clicks")', (tester) async {
    await open(tester);
    final poster = inRow('Recently added series', 'Brand New Series');
    final g = await tester.startGesture(tester.getCenter(poster), kind: PointerDeviceKind.mouse);
    await tester.pump(const Duration(milliseconds: 30));
    await g.moveBy(const Offset(2, 0)); // a hand's wobble
    await tester.pump(const Duration(milliseconds: 30));
    await g.up();
    await tester.pumpAndSettle();
    expect(find.byType(SeriesScreen), findsOneWidget, reason: 'the click opened the series');
  });

  testWidgets("a right-click on a poster opens its menu however far the mouse moves while the button is down (past "
      '18 px it was lost - user, build 108)', (tester) async {
    await open(tester);
    final poster = inRow('Continue reading', 'Ongoing #4');
    final g = await tester.startGesture(tester.getCenter(poster), kind: PointerDeviceKind.mouse,
        buttons: kSecondaryMouseButton);
    await tester.pump(const Duration(milliseconds: 30));
    await g.moveBy(const Offset(30, 4));
    await tester.pump(const Duration(milliseconds: 30));
    await g.up();
    await tester.pumpAndSettle();
    expect(find.text('Mark as read'), findsOneWidget, reason: "the book's menu");
  });

  testWidgets("each row shows its own books (or series), from the query that's its own", (tester) async {
    final api = await open(tester);
    for (final (row, item) in [
      ('Continue reading', 'Ongoing #4'),
      ('On deck', 'Next Up #2'),
      ('Recently read', 'Read Series #1'),
      ('Recently added books', 'New Series #1'),
      ('Recently added series', 'Brand New Series'),
      ('Recent releases', 'Fresh Release #1'),
    ]) {
      expect(inRow(row, item), findsOneWidget, reason: '$row: $item');
    }
    expect(find.byType(PosterRow), findsNWidgets(6), reason: 'no pins: no Pinned row');
    expect(find.text('Pinned'), findsNothing);
    expect(api.asked, containsAll([
      'books - READ readProgress.readDate,desc', 'books - all createdDate,desc',
      'books - all metadata.releaseDate,desc', 'series - - createdDate,desc',
    ]));
  });

  testWidgets('an empty row keeps its title and says what is missing; switched off, a row is neither shown nor '
      'fetched', (tester) async {
    final api = await open(tester, empty: true);
    expect(find.byType(PosterRow), findsNothing);
    for (final (row, says) in [
      ('Continue reading', 'Nothing in progress'),
      ('On deck', 'Nothing on deck'),
      ('Recently read', 'Nothing read yet'),
      ('Recent releases', 'No releases yet'),
    ]) {
      expect(find.text(row), findsOneWidget, reason: row);
      expect(find.text(says), findsOneWidget, reason: row);
      expect(tester.getTopLeft(find.text(says)).dy, greaterThan(tester.getTopLeft(find.text(row)).dy),
          reason: '$says under $row');
    }
    expect(find.text('Nothing added yet'), findsNWidgets(2), reason: 'recently added books, and series');

    await HomeSections.instance.set('recentlyRead', false);
    api.asked.clear();
    await tester.tap(find.byTooltip('Refresh'));
    await tester.pump();
    await tester.pump();
    expect(find.text('Recently read'), findsNothing);
    expect(find.text('Nothing read yet'), findsNothing);
    expect(api.asked, isNot(contains('books - READ readProgress.readDate,desc')), reason: 'not fetched while off');
  });

  // ---- pins

  const series = Pin(name: 'My saga', kind: 'series', id: 'S1', title: 'Saga', filter: 'hideRead');
  const readList = Pin(name: 'My list', kind: 'readlist', id: 'RL1', title: 'Infinity');
  const collection = Pin(name: 'My collection', kind: 'collection', id: 'C1', title: 'Marvel cosmic');
  const library = Pin(name: 'My library', kind: 'library', id: 'L1', title: 'Events', filter: 'hideRead',
      mode: 'books', sort: 'added:desc');

  testWidgets('a pin opens its own view: a series, a read list, a collection, a library in its mode and filter',
      (tester) async {
    await open(tester, pins: [series, readList, collection, library]);
    Future<void> openPin(String name) async {
      await tester.tap(inRow('Pinned', name));
      await tester.pumpAndSettle();
    }

    await openPin('My saga');
    final s = tester.widget<SeriesScreen>(find.byType(SeriesScreen));
    expect((s.series['id'], jsonEncode(s.pin)), ('S1', jsonEncode(series)));
    expect(find.byTooltip('Read hidden (hide unread)'), findsOneWidget, reason: "the pin's filter");
    await tester.pageBack();
    await tester.pumpAndSettle();

    await openPin('My list');
    final rl = tester.widget<ReadListScreen>(find.byType(ReadListScreen));
    expect((rl.readList['id'], jsonEncode(rl.pin)), ('RL1', jsonEncode(readList)));
    await tester.pageBack();
    await tester.pumpAndSettle();

    await openPin('My collection');
    final c = tester.widget<SeriesListScreen>(find.byType(SeriesListScreen));
    expect((c.collectionId, c.title, jsonEncode(c.pin)), ('C1', 'Marvel cosmic', jsonEncode(collection)));
    await tester.pageBack();
    await tester.pumpAndSettle();

    await openPin('My library');
    final l = tester.widget<LibraryScreen>(find.byType(LibraryScreen));
    expect((l.libraryId, jsonEncode(l.pin)), ('L1', jsonEncode(library)));
    expect(tester.widget<ChoiceChip>(find.widgetWithText(ChoiceChip, 'Books')).selected, isTrue, reason: 'its mode');
    expect(find.byTooltip('Read hidden (hide unread)'), findsOneWidget, reason: 'its filter');
  }, tags: 'slow');

  testWidgets("a pin to something deleted from the server: nothing opens; it says so, and offers to unpin it (Komga's "
      'copy too)', (tester) async {
    const goneSeries = Pin(name: 'Old saga', kind: 'series', id: 'gone', title: 'Old Saga');
    const goneList = Pin(name: 'Old list', kind: 'readlist', id: 'gone', title: 'Old List');
    final api = await open(tester, pins: [goneSeries, goneList, readList]);

    await tester.tap(inRow('Pinned', 'Old list'));
    await tester.pumpAndSettle();
    expect(find.byType(ReadListScreen), findsNothing);
    expect(find.text('"Old List" no longer exists on the server'), findsOneWidget);
    ScaffoldMessenger.of(tester.element(find.byType(HomeScreen))).hideCurrentSnackBar(); // closed, pin kept
    await tester.pumpAndSettle();
    expect(Pins.instance.items.map((p) => p.name), contains('Old list'));

    await tester.tap(inRow('Pinned', 'Old saga'));
    await tester.pumpAndSettle();
    expect(find.byType(SeriesScreen), findsNothing);
    expect(find.text('"Old Saga" no longer exists on the server'), findsOneWidget);
    await tester.tap(find.widgetWithText(SnackBarAction, 'Unpin'));
    await tester.pumpAndSettle();
    expect(Pins.instance.items.map((p) => p.name), ['Old list', 'My list']);
    expect(inRow('Pinned', 'Old saga'), findsNothing);
    expect(api.written[Pins.komgaKey], isNot(contains('"gone","title":"Old Saga"')), reason: 'unpinned on Komga');
    expect(api.written[Pins.komgaKey], contains('Old List'));
  });

  // ---- the sections: shown or hidden, and their order (from home_test.dart)
  testWidgets('the ⋮ menu shows or hides each Home section, and the choice is remembered', (tester) async {
    AppSettings.instance.library = const LibraryPrefs(homeShown: {'ondeck': false});
    await tester.pumpWidget(MaterialApp(home: HomeScreen(api: noNetwork(HomeServer.new), onSignOut: () {})));
    await tester.pump();
    await tester.pump();
    expect(find.text('Continue reading'), findsOneWidget);
    expect(find.text('On deck'), findsNothing);
    expect(find.text('Libraries'), findsOneWidget);

    await tester.tap(find.byTooltip('Show or hide sections'));
    await tester.pumpAndSettle();
    expect(find.text('Pinned'), findsOneWidget); // listed in the menu
    await tester.tap(find.text('Libraries').last);
    await tester.pumpAndSettle();
    expect(find.text('Libraries'), findsNothing);
    expect(AppSettings.instance.library.homeShown['libraries'], isFalse, reason: 'kept (synced)');
  });

  test('section order: new rows start hidden, moves are saved, saved orders keep new sections', () async {
    AppSettings.instance.library = const LibraryPrefs(homeOrder: ['libraries', 'continue']);
    final h = HomeSections.instance;
    await h.load();
    expect(h.order.take(3), ['libraries', 'continue', 'ondeck']); // saved first, the rest after in default order
    expect(h['recentBooks'], isFalse);
    await h.move('libraries', 1);
    expect(h.order.take(2), ['continue', 'libraries']);
    expect(AppSettings.instance.library.homeOrder.take(2), ['continue', 'libraries'], reason: 'kept (synced)');
  });

  testWidgets('Home draws the sections in the chosen order', (tester) async {
    AppSettings.instance.library = const LibraryPrefs(homeOrder: ['libraries', 'continue']);
    await tester.pumpWidget(MaterialApp(home: HomeScreen(api: noNetwork(HomeServer.new), onSignOut: () {})));
    await tester.pump();
    await tester.pump();
    expect(tester.getTopLeft(find.text('Libraries')).dy < tester.getTopLeft(find.text('Continue reading')).dy, isTrue);
  });

  group('row arrows', () {
    testWidgets('home rows have ‹ › buttons: greyed at the ends, each press scrolls about a screen', (tester) async {
      SharedPreferences.setMockInitialValues({});
      setView(tester, const Size(1000, 900));
      // twenty books in progress - a Continue reading row wider than the screen
      final api = noNetwork(() => HomeServer(inProgressBooks: [
            for (var i = 1; i <= 20; i++)
              {'id': 'B$i', 'seriesTitle': 'Series', 'name': 'b$i', 'metadata': {'number': '$i', 'title': 'T$i'}},
          ]));
      await tester.pumpWidget(MaterialApp(home: HomeScreen(api: api, onSignOut: () {})));
      await tester.pump();
      await tester.pump();

      // the button with that tooltip (the helper used to take the first chevron on the screen, whatever its row - test
      // audit, 2026-09-30)
      IconButton button(String tip) =>
          tester.widget<IconButton>(find.ancestor(of: find.byTooltip(tip), matching: find.byType(IconButton)));
      final strip = find.ancestor(of: find.text('Series #1'), matching: find.byType(ListView)).first;
      // (found once: the finder goes through "Series #1", which scrolls out of the strip)
      final scrollable = tester.state<ScrollableState>(find.descendant(of: strip, matching: find.byType(Scrollable)).first);
      ScrollPosition position() => scrollable.position;
      expect(position().axis, Axis.horizontal);
      final screen = tester.getSize(strip).width;

      expect(button('Continue reading: back').onPressed, isNull); // at the start
      expect(button('Continue reading: more').onPressed, isNotNull);
      final firstX = tester.getTopLeft(find.text('Series #1')).dx;

      await tester.tap(find.byTooltip('Continue reading: more'));
      await tester.pumpAndSettle();
      expect(position().pixels, closeTo(0.9 * screen, 1), reason: 'about a screen (90%, so a poster carries over)');
      expect(find.text('Series #1').hitTestable(), findsNothing); // scrolled past the first poster
      expect(button('Continue reading: back').onPressed, isNotNull);

      await tester.tap(find.byTooltip('Continue reading: back'));
      await tester.pumpAndSettle();
      expect(position().pixels, 0);
      expect(tester.getTopLeft(find.text('Series #1')).dx, firstX); // back at the start

      // to the end: there "more" is greyed and "back" isn't
      for (var i = 0; i < 10 && position().pixels < position().maxScrollExtent; i++) {
        await tester.tap(find.byTooltip('Continue reading: more'));
        await tester.pumpAndSettle();
      }
      expect(position().pixels, position().maxScrollExtent);
      expect(position().maxScrollExtent, greaterThan(2 * screen)); // (several presses: twenty posters)
      expect(button('Continue reading: more').onPressed, isNull);
      expect(button('Continue reading: back').onPressed, isNotNull);
    });
  });
}
