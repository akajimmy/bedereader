// A single book pinned to Home (user, 2026-10-12: "make it possible to pin a single book"; their answers 2026-10-16:
// a tap opens the reader, pinned from the book menu and its Details, the poster its cover with the pin's name and how
// far through it is).
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:komga_reader/pins.dart';
import 'package:komga_reader/refresh_gate.dart';
import 'package:komga_reader/screens/actions.dart';
import 'package:komga_reader/screens/book_details.dart';
import 'package:komga_reader/screens/home.dart';
import 'package:komga_reader/screens/reader.dart';
import 'package:komga_reader/widgets/pin_tile.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/client_settings.dart';
import 'support/home_server.dart';
import 'support/no_network.dart';

/// Home, with the pins' client settings and two books: B1 (34 of 100 pages read) and B2 (read); any other is gone.
class BookPinServer extends HomeServer with ClientSettingsStore {
  static Map<String, dynamic> theBook(String id) => {
        'id': id, 'seriesId': 'S1', 'seriesTitle': 'Discworld', 'name': id,
        'metadata': {'title': id == 'B1' ? 'Small Gods' : 'Mort', 'number': id == 'B1' ? '13' : '4'},
        'media': {'pagesCount': 100},
        'readProgress': id == 'B1' ? {'page': 34, 'completed': false} : {'page': 100, 'completed': true},
      };
  final asked = <String>[];
  @override
  Future<Map<String, dynamic>?> book(String id) async {
    asked.add(id);
    return id == 'B1' || id == 'B2' ? theBook(id) : null;
  }

  @override
  Future<Map<String, dynamic>?> oneSeries(String id) async => {'id': id, 'name': 'Discworld', 'metadata': {}};
  @override
  Future<List<dynamic>> pages(String bookId) async => []; // (the reader opened: nothing to show)
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    RefreshGate.gap = Duration.zero;
  });
  tearDown(() async {
    RefreshGate.gap = const Duration(seconds: 10);
    await Pins.instance.clearAccount();
  });

  Future<BookPinServer> home(WidgetTester tester, List<Pin> pins) async {
    final api = noNetwork(BookPinServer.new);
    await Pins.instance.load(api);
    for (final p in pins) {
      Pins.instance.add(p);
    }
    await tester.pumpWidget(MaterialApp(home: HomeScreen(api: api, onSignOut: () {})));
    for (var i = 0; i < 4; i++) {
      await tester.pump();
    }
    return api;
  }

  test("a book's pin: named after its series, number and title (user, 2026-10-18), the same pin whatever the "
      "book's read state", () {
    final pin = Pin.book(BookPinServer.theBook('B1'));
    expect((pin.kind, pin.id, pin.name, pin.title), ('book', 'B1', 'Discworld #13 · Small Gods', 'Small Gods'));
    // a title that only repeats the series and number isn't said twice; a book in no series is its title
    final b1 = BookPinServer.theBook('B1');
    expect(Pin.book({...b1, 'metadata': {'title': 'Discworld #13', 'number': '13'}}).name, 'Discworld #13');
    expect(Pin.book({...b1, 'seriesTitle': null, 'metadata': {'title': 'Small Gods'}}).name, 'Small Gods');
    // an eBook is its title alone (user, 2026-10-18: nobody names a novel by its series and number)
    expect(Pin.book({...b1, 'media': {'mediaProfile': 'EPUB'}}).name, 'Small Gods');
    expect(pin.sameView(Pin.book({...BookPinServer.theBook('B1'), 'readProgress': null})), isTrue);
    expect(pin.sameView(Pin.book(BookPinServer.theBook('B2'))), isFalse);
    expect(Pin.fromJson(pin.toJson()).sameView(pin), isTrue, reason: 'kept and synced as the other pins');
    expect(bookState(BookPinServer.theBook('B1')), '34% read');
    expect(bookState(BookPinServer.theBook('B2')), 'Read');
    expect(bookState({...BookPinServer.theBook('B1'), 'readProgress': null}), 'Not started');
  });

  testWidgets("a pinned book on Home: the pin's name and how far through it is; a tap opens the reader",
      (tester) async {
    final api = await home(tester, [Pin.book(BookPinServer.theBook('B1')).renamed('Brutha')]);
    expect(find.text('Brutha'), findsOneWidget);
    expect(find.text('34% read'), findsOneWidget);
    await tester.tap(find.text('Brutha'));
    for (var i = 0; i < 4; i++) {
      await tester.pump();
    }
    expect(find.byType(ReaderScreen), findsOneWidget, reason: 'straight into the reader');
    expect(api.asked.where((id) => id == 'B1').length, greaterThanOrEqualTo(2), reason: 'fetched fresh to open');
    await tester.pumpWidget(const SizedBox()); // (the reader closed)
  }, tags: 'slow');

  testWidgets('a pinned book gone from the server: a tap says so and offers Unpin', (tester) async {
    await home(tester, [const Pin(name: 'Lost', kind: 'book', id: 'B9', title: 'Lost')]);
    await tester.tap(find.text('Lost'));
    await tester.pump();
    await tester.pump();
    expect(find.text('"Lost" no longer exists on the server'), findsOneWidget);
    await tester.pump(const Duration(milliseconds: 500)); // (the snack bar in place)
    await tester.tap(find.text('Unpin'));
    await tester.pump();
    expect(Pins.instance.items, isEmpty);
  });

  testWidgets('the book menu: Pin to Home (named after its series, number and title); pinned, it says so - and renames or unpins',
      (tester) async {
    final api = noNetwork(BookPinServer.new);
    await Pins.instance.load(api);
    final b = BookPinServer.theBook('B1');
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: Builder(builder: (context) => TextButton(
        onPressed: () => showBookActions(context, api, b, onChanged: () {}), child: const Text('menu'))))));
    await tester.tap(find.text('menu'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Pin to Home'));
    await tester.pumpAndSettle();
    expect(find.widgetWithText(TextField, 'Discworld #13 · Small Gods'), findsOneWidget,
        reason: 'named after its series, number and title');
    await tester.tap(find.widgetWithText(FilledButton, 'Pin'));
    await tester.pumpAndSettle();
    expect(Pins.instance.items.single.sameView(Pin.book(b)), isTrue);
    expect(Pins.instance.items.single.name, 'Discworld #13 · Small Gods');

    await tester.tap(find.text('menu'));
    await tester.pumpAndSettle();
    expect(find.text('Pin to Home'), findsNothing);
    await tester.tap(find.text('Pinned as "Discworld #13 · Small Gods"'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Unpin'));
    await tester.pumpAndSettle();
    expect(Pins.instance.items, isEmpty);
  });

  testWidgets("the book's Details: a pin button, filled once the book is pinned", (tester) async {
    final api = noNetwork(BookPinServer.new);
    await Pins.instance.load(api);
    await tester.pumpWidget(MaterialApp(home: BookDetailsScreen(api: api, book: BookPinServer.theBook('B2'))));
    await tester.pump();
    expect(find.byIcon(Icons.push_pin), findsNothing);
    await tester.tap(find.byIcon(Icons.push_pin_outlined));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Pin'));
    await tester.pumpAndSettle();
    expect(Pins.instance.items.single.name, 'Discworld #4 · Mort');
    expect(find.byIcon(Icons.push_pin), findsOneWidget, reason: 'pinned');
  });
}
