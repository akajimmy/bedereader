import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:komga_reader/api.dart';
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
}
