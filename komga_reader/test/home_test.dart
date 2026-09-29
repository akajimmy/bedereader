import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:komga_reader/api.dart';
import 'package:komga_reader/home_sections.dart';
import 'package:komga_reader/screens/home.dart';
import 'package:shared_preferences/shared_preferences.dart';

class FakeKomga extends Komga {
  FakeKomga() : super('http://test', 'k');
  @override
  Future<List<dynamic>> libraries() async => [{'id': 'L1', 'name': 'Events'}];
  @override
  Future<Map<String, dynamic>> inProgress({String? libraryId, int size = 30}) async =>
      {'content': [], 'totalElements': 0, 'last': true};
  @override
  Future<Map<String, dynamic>> onDeck({String? libraryId, int size = 30}) async =>
      {'content': [], 'totalElements': 0, 'last': true};
  final booksSorts = <String>[];
  @override
  Future<Map<String, dynamic>> books({String? libraryId, List<String>? readStatus,
      String sort = 'metadata.releaseDate,desc', int page = 0, int size = 60}) async {
    booksSorts.add(sort);
    return {'content': [
      {'id': 'N1', 'seriesTitle': 'New Series', 'name': 'n1', 'metadata': {'number': '1', 'title': 'Fresh'}},
    ], 'totalElements': 1, 'last': true};
  }

  @override
  Future<Map<String, dynamic>> series({String? libraryId, String? collectionId, List<String>? readStatus,
          String sort = 'metadata.titleSort,asc', int page = 0, int size = 60}) async =>
      {'content': [], 'totalElements': 0, 'last': true};
}

void main() {
  testWidgets('the ⋮ menu shows or hides each Home section, and the choice is remembered', (tester) async {
    SharedPreferences.setMockInitialValues({'showOnDeck': false}); // old build-15 setting carries over
    await tester.pumpWidget(MaterialApp(home: HomeScreen(api: FakeKomga(), onSignOut: () {})));
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
    expect((await SharedPreferences.getInstance()).getBool('home.show.libraries'), isFalse);
  });

  test('section order: new rows start hidden, moves are saved, saved orders keep new sections', () async {
    SharedPreferences.setMockInitialValues({'home.order': ['libraries', 'continue']});
    final h = HomeSections.instance;
    await h.load();
    expect(h.order.take(3), ['libraries', 'continue', 'ondeck']); // saved first, the rest after in default order
    expect(h['recentBooks'], isFalse);
    await h.move('libraries', 1);
    expect(h.order.take(2), ['continue', 'libraries']);
    expect((await SharedPreferences.getInstance()).getStringList('home.order')!.take(2), ['continue', 'libraries']);
  });

  testWidgets('Home draws the sections in the chosen order; a switched-on new row loads and shows', (tester) async {
    SharedPreferences.setMockInitialValues({'home.order': ['libraries', 'continue'], 'home.show.recentBooks': true});
    final api = FakeKomga();
    await tester.pumpWidget(MaterialApp(home: HomeScreen(api: api, onSignOut: () {})));
    await tester.pump();
    await tester.pump();
    expect(tester.getTopLeft(find.text('Libraries')).dy < tester.getTopLeft(find.text('Continue reading')).dy, isTrue);
    expect(find.text('Recently added books'), findsOneWidget);
    expect(find.text('New Series #1'), findsOneWidget);
    expect(api.booksSorts, contains('createdDate,desc'));
  });
}

