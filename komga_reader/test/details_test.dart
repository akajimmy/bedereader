import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:komga_reader/api.dart';
import 'package:komga_reader/screens/book_details.dart';
import 'package:komga_reader/screens/readlist.dart';
import 'package:komga_reader/screens/series.dart';
import 'package:komga_reader/screens/series_details.dart';
import 'package:komga_reader/screens/actions.dart';
import 'package:shared_preferences/shared_preferences.dart';

final theBook = {
  'id': 'B1', 'seriesId': 'S1', 'seriesTitle': 'Silver Surfer', 'name': 'b1',
  'media': {'pagesCount': 36}, 'readProgress': null,
  'metadata': {
    'number': '1', 'title': 'The Origin of the Silver Surfer', 'releaseDate': '1968-08-01',
    'summary': 'Norrin Radd leaves Zenn-La.',
    'authors': [
      {'name': 'John Buscema', 'role': 'penciller'},
      {'name': 'Stan Lee', 'role': 'writer'},
      {'name': 'Joe Sinnott', 'role': 'inker'},
      {'name': 'Sam Rosen', 'role': 'letterer'},
    ],
  },
};

class FakeKomga extends Komga {
  FakeKomga() : super('http://test', 'k');
  @override
  Future<Map<String, dynamic>?> book(String id) async => theBook;
  @override
  Future<Map<String, dynamic>?> oneSeries(String id) async =>
      {'id': 'S1', 'name': 'Silver Surfer', 'booksCount': 1, 'metadata': {'title': 'Silver Surfer', 'publisher': 'Marvel'}};
  @override
  Future<Map<String, dynamic>> readListBooks(String readListId, {List<String>? readStatus, int page = 0, int size = 1000}) async =>
      {'content': [theBook], 'totalElements': 1, 'last': true};
  @override
  Future<Map<String, dynamic>> seriesBooks(String seriesId, {List<String>? readStatus, String sort = '', int page = 0, int size = 500}) async =>
      {'content': [theBook], 'totalElements': 1, 'last': true};
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('details: title, publisher, date, summary, credits in comic order', (tester) async {
    tester.view.physicalSize = const Size(1280, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(home: BookDetailsScreen(api: FakeKomga(), book: theBook)));
    await tester.pump();
    await tester.pump();
    expect(find.text('The Origin of the Silver Surfer'), findsOneWidget);
    expect(find.text('Marvel'), findsOneWidget);
    expect(find.text('1 August 1968'), findsOneWidget);
    expect(find.text('Norrin Radd leaves Zenn-La.'), findsOneWidget);
    expect(find.text('View series'), findsOneWidget);
    final writer = tester.getTopLeft(find.text('Stan Lee')).dy;
    final penciller = tester.getTopLeft(find.text('John Buscema')).dy;
    final letterer = tester.getTopLeft(find.text('Sam Rosen')).dy;
    expect(writer < penciller && penciller < letterer, isTrue); // writer, penciller, inker, colorist, letterer...
    expect(tester.takeException(), isNull);
  });

  testWidgets('book menu in a read list offers Details and View series; View series opens the series', (tester) async {
    await tester.pumpWidget(MaterialApp(home: ReadListScreen(api: FakeKomga(),
        readList: const {'id': 'RL', 'name': 'List', 'bookIds': ['B1']})));
    await tester.pump();
    await tester.pump();
    await tester.longPress(find.text('Silver Surfer #1'));
    await tester.pumpAndSettle();
    expect(find.text('Details'), findsOneWidget);
    await tester.tap(find.text('View series'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.byType(SeriesScreen), findsOneWidget);
  });

  testWidgets('inside the series itself, the book menu has no View series', (tester) async {
    await tester.pumpWidget(MaterialApp(home: SeriesScreen(api: FakeKomga(),
        series: const {'id': 'S1', 'name': 'Silver Surfer', 'booksCount': 1, 'metadata': {'title': 'Silver Surfer'}})));
    await tester.pump();
    await tester.pump();
    await tester.longPress(find.text('Silver Surfer #1'));
    await tester.pumpAndSettle();
    expect(find.text('Details'), findsOneWidget);
    expect(find.text('View series'), findsNothing);
  });

  testWidgets('book menu fits a short landscape screen: scrolls instead of overflowing', (tester) async {
    tester.view.physicalSize = const Size(860, 400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(home: ReadListScreen(api: FakeKomga(),
        readList: const {'id': 'RL', 'name': 'List', 'bookIds': ['B1']})));
    await tester.pump();
    await tester.pump();
    await tester.longPress(find.text('Silver Surfer #1'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await tester.scrollUntilVisible(find.text('Delete book…'), 50,
        scrollable: find.descendant(of: find.byType(BottomSheet), matching: find.byType(Scrollable)));
    expect(find.text('Delete book…').hitTestable(), findsOneWidget);
  });

  testWidgets('series details: from the series menu - facts, genres and tags, summary, credits once each', (tester) async {
    tester.view.physicalSize = const Size(1280, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final series = {
      'id': 'S1', 'name': 'Silver Surfer', 'booksCount': 18, 'booksReadCount': 3, 'booksUnreadCount': 15,
      'booksInProgressCount': 0,
      'metadata': {'title': 'Silver Surfer', 'publisher': 'Marvel', 'status': 'ENDED', 'genres': ['Superhero'],
          'tags': ['cosmic'], 'summary': 'The Sentinel of the Spaceways.', 'language': 'en', 'ageRating': 12},
      'booksMetadata': {'releaseDate': '1968-08-01', 'authors': [
        {'name': 'Stan Lee', 'role': 'writer'}, {'name': 'Stan Lee', 'role': 'writer'}, // two books, same writer
        {'name': 'John Buscema', 'role': 'penciller'},
      ]},
    };
    final api = _SeriesKomga(series);
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: Builder(builder: (context) => TextButton(
        onPressed: () => showSeriesActions(context, api, series, onChanged: () {}), child: const Text('menu'))))));
    await tester.tap(find.text('menu'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Details'));
    await tester.pumpAndSettle();
    expect(find.byType(SeriesDetailsScreen), findsOneWidget);
    expect(find.text('Marvel'), findsOneWidget);
    expect(find.text('Ended'), findsOneWidget);
    expect(find.text('1 August 1968'), findsOneWidget);
    expect(find.text('Superhero'), findsOneWidget);
    expect(find.text('cosmic'), findsOneWidget);
    expect(find.text('The Sentinel of the Spaceways.'), findsOneWidget);
    expect(find.text('Stan Lee'), findsOneWidget); // once, not per book
    expect(find.text('Open series'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('series details from inside that series: no Open series', (tester) async {
    await tester.pumpWidget(MaterialApp(home: SeriesDetailsScreen(api: FakeKomga(),
        series: const {'id': 'S1', 'name': 'Silver Surfer', 'metadata': {}}, showOpen: false)));
    await tester.pump();
    expect(find.text('Open series'), findsNothing);
  });
}

class _SeriesKomga extends FakeKomga {
  _SeriesKomga(this.s);
  final Map<String, dynamic> s;
  @override
  Future<Map<String, dynamic>?> oneSeries(String id) async => s;
}
