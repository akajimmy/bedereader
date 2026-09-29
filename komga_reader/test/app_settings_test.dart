import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:komga_reader/api.dart';
import 'package:komga_reader/home_sections.dart';
import 'package:komga_reader/screens/app_settings.dart';
import 'package:komga_reader/settings.dart';
import 'package:komga_reader/widgets/drawer.dart';
import 'package:shared_preferences/shared_preferences.dart';

class FakeKomga extends Komga {
  FakeKomga() : super('http://10.0.0.23:25600', 'k');
  @override
  Future<List<dynamic>> libraries() async => [];
}

/// A portrait-tablet-sized test window: the whole settings screen fits, nothing to scroll to.
void tall(WidgetTester tester) {
  tester.view.physicalSize = const Size(800, 2400);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
}

void main() {
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await HomeSections.instance.load();
  });

  testWidgets('side menu: App settings sits above Reader settings and opens the screen', (tester) async {
    final scaffold = GlobalKey<ScaffoldState>();
    await tester.pumpWidget(MaterialApp(home: Scaffold(key: scaffold,
        drawer: AppDrawer(api: FakeKomga(), onSignOut: () {}), body: const SizedBox())));
    scaffold.currentState!.openDrawer();
    await tester.pumpAndSettle();
    double y(String t) => tester.getTopLeft(find.textContaining(t)).dy;
    expect(y('App settings') < y('Reader settings'), isTrue);
    expect(y('All libraries') < y('App settings'), isTrue); // Home, line, libraries, line, app items
    await tester.tap(find.text('App settings'));
    await tester.pumpAndSettle();
    expect(find.byType(AppSettingsScreen), findsOneWidget);
    expect(find.text('http://10.0.0.23:25600'), findsOneWidget);
  });

  testWidgets('Home section switches here are the same setting as the Home menu (shared, saved)', (tester) async {
    tall(tester);
    await tester.pumpWidget(MaterialApp(home: AppSettingsScreen(api: FakeKomga(), onSignOut: () {})));
    Finder onDeckSwitch() => find.descendant(
        of: find.ancestor(of: find.text('On deck'), matching: find.byType(Row)).first, matching: find.byType(Switch));
    await tester.tap(onDeckSwitch());
    await tester.pump();
    expect(HomeSections.instance['ondeck'], isFalse);
    expect((await SharedPreferences.getInstance()).getBool('home.show.ondeck'), isFalse);
    await HomeSections.instance.set('ondeck', true); // e.g. from the Home menu
    await tester.pump();
    expect(tester.widget<Switch>(onDeckSwitch()).value, isTrue);
  });

  testWidgets('night mode is here too - the same setting as the reader panel', (tester) async {
    tall(tester);
    final s = AppSettings.instance;
    s.setDisplay(s.display.copyWith(night: false));
    await tester.pumpWidget(MaterialApp(home: AppSettingsScreen(api: FakeKomga(), onSignOut: () {})));
    final night = find.widgetWithText(SwitchListTile, 'Night mode (warm colours)');
    await tester.tap(night);
    await tester.pump();
    expect(s.display.night, isTrue);
    s.setDisplay(s.display.copyWith(night: false)); // e.g. switched off in the reader
    await tester.pump();
    expect(tester.widget<SwitchListTile>(night).value, isFalse);
  });

  testWidgets('sign out asks first; Cancel keeps you signed in', (tester) async {
    var signedOut = 0;
    await tester.pumpWidget(MaterialApp(home: AppSettingsScreen(api: FakeKomga(), onSignOut: () => signedOut++)));
    await tester.tap(find.text('Sign out / change server'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(signedOut, 0);
    await tester.tap(find.text('Sign out / change server'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(TextButton, 'Sign out'));
    await tester.pumpAndSettle();
    expect(signedOut, 1);
  });
}
