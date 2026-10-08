import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:komga_reader/home_sections.dart';
import 'package:komga_reader/screens/home.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/home_server.dart';
import 'support/no_network.dart';

void main() {
  testWidgets('the ⋮ menu shows or hides each Home section, and the choice is remembered', (tester) async {
    SharedPreferences.setMockInitialValues({'home.show.ondeck': false});
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
    final api = noNetwork(HomeServer.new);
    await tester.pumpWidget(MaterialApp(home: HomeScreen(api: api, onSignOut: () {})));
    await tester.pump();
    await tester.pump();
    expect(tester.getTopLeft(find.text('Libraries')).dy < tester.getTopLeft(find.text('Continue reading')).dy, isTrue);
    expect(find.text('Recently added books'), findsOneWidget);
    expect(find.text('New Series #1'), findsOneWidget);
    expect(api.booksSorts, contains('createdDate,desc'));
  });
}

