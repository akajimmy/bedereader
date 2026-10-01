import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:komga_reader/screens/home.dart';
import 'package:komga_reader/side_menu.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/helpers.dart';
import 'support/home_server.dart';
import 'support/no_network.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));
  tearDown(() => SideMenu.instance.pinned = false);

  Future<void> home(WidgetTester tester, Size size) async {
    setView(tester, size);
    await tester.pumpWidget(MaterialApp(home: HomeScreen(api: noNetwork(HomeServer.new), onSignOut: () {})));
    await tester.pump();
    await tester.pump();
  }

  testWidgets('wide screen: the pin keeps the menu open beside the page; unpinning slides it away', (tester) async {
    await home(tester, const Size(1280, 800));
    expect(find.text('Settings'), findsNothing); // slide-out menu, closed (Settings = a side-menu item)
    await tester.tap(find.byTooltip('Open navigation menu'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Keep the side menu open'));
    await tester.pumpAndSettle();
    expect(SideMenu.instance.pinned, isTrue);
    expect(find.text('Settings'), findsOneWidget); // docked, visible without opening
    expect(find.byTooltip('Open navigation menu'), findsNothing); // no menu button needed
    expect(tester.getTopLeft(find.text('Home').last).dx, greaterThanOrEqualTo(SideMenu.width)); // page shifted right
    expect((await SharedPreferences.getInstance()).getBool('sidemenu.pinned'), isTrue);

    await tester.tap(find.byTooltip('Let the side menu slide away'));
    await tester.pumpAndSettle();
    expect(find.text('Settings'), findsNothing);
    expect(find.byTooltip('Open navigation menu'), findsOneWidget);
  });

  testWidgets('narrow screen: never docked, and the pin button is hidden', (tester) async {
    SideMenu.instance.pinned = true; // pinned on a wide screen earlier
    await home(tester, const Size(600, 900));
    expect(find.text('Settings'), findsNothing);
    await tester.tap(find.byTooltip('Open navigation menu'));
    await tester.pumpAndSettle();
    expect(find.text('Settings'), findsOneWidget); // slides out as usual
    expect(find.byTooltip('Let the side menu slide away'), findsNothing);
    expect(find.byTooltip('Keep the side menu open'), findsNothing);
  });
}
