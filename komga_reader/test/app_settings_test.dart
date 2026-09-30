import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:komga_reader/api.dart';
import 'package:komga_reader/home_sections.dart';
import 'package:komga_reader/screen.dart';
import 'package:komga_reader/screens/app_settings.dart';
import 'package:komga_reader/settings.dart';
import 'package:komga_reader/widgets/drawer.dart';
import 'package:shared_preferences/shared_preferences.dart';

class FakeKomga extends Komga {
  FakeKomga() : super('http://192.168.1.10:25600', 'k');
  @override
  Future<List<dynamic>> libraries() async => [];
  @override
  Future<Map<String, dynamic>?> me() async => {'email': 'nick@test'}; // the server status check
}

/// A portrait-tablet-sized test window: the whole settings screen fits, nothing to scroll to.
void tall(WidgetTester tester) {
  tester.view.physicalSize = const Size(800, 3200);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
}

void main() {
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await HomeSections.instance.load();
  });

  testWidgets('side menu: Settings after the libraries, and opens the screen', (tester) async {
    final scaffold = GlobalKey<ScaffoldState>();
    await tester.pumpWidget(MaterialApp(home: Scaffold(key: scaffold,
        drawer: AppDrawer(api: FakeKomga(), onSignOut: () {}), body: const SizedBox())));
    scaffold.currentState!.openDrawer();
    await tester.pumpAndSettle();
    double y(String t) => tester.getTopLeft(find.textContaining(t)).dy;
    expect(y('All libraries') < y('Settings'), isTrue); // Home, line, libraries, line, app items
    await tester.tap(find.text('Settings'));
    await tester.pumpAndSettle();
    expect(find.byType(AppSettingsScreen), findsOneWidget);
    expect(find.text('http://192.168.1.10:25600'), findsOneWidget);
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
    tall(tester);
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

  testWidgets('one place for everything: sections in order, each saying where it is kept; server status shown',
      (tester) async {
    tall(tester);
    await tester.pumpWidget(MaterialApp(home: AppSettingsScreen(api: FakeKomga(), onSignOut: () {})));
    await tester.pumpAndSettle();
    final titles = ['SERVER & CONNECTION', 'READING', 'DISPLAY', 'LIBRARY & HOME', 'ABOUT'];
    final ys = [for (final t in titles) tester.getTopLeft(find.text(t)).dy];
    expect(ys, [...ys]..sort()); // in that order
    expect(find.text('This device'), findsWidgets);
    expect(find.text('Defaults synced through Komga'), findsOneWidget);
    expect(find.text('Connected as nick@test'), findsOneWidget); // status, from Info
    expect(find.text('Screen brightness'), findsOneWidget); // brightness moved here from the side-menu panel
    expect(find.text('Night mode (warm colours)'), findsOneWidget);
  });

  testWidgets('Reading: defaults edited here; series with their own settings can all be reset', (tester) async {
    tall(tester);
    final s = AppSettings.instance;
    s.setDefault(const ReaderPrefs());
    s.setSeries('S1', const ReaderPrefs(fit: FitMode.width));
    s.setSeries('S2', const ReaderPrefs(sharpen: true));
    await tester.pumpWidget(MaterialApp(home: AppSettingsScreen(api: FakeKomga(), onSignOut: () {})));
    await tester.pump();
    await tester.tap(find.text('Fit height').first);
    await tester.pump();
    expect(s.defaults.fit, FitMode.height);
    expect(find.text('2 series have their own settings'), findsOneWidget);
    await tester.tap(find.text('Reset all'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(TextButton, 'Reset all').last); // confirm
    await tester.pumpAndSettle();
    expect(s.series, isEmpty);
    expect(s.prefsFor('S1').fit, FitMode.height); // follows the defaults now
    expect(find.text('Every series follows the defaults'), findsOneWidget);
    await tester.pump(const Duration(seconds: 3)); // the settings sync timer
  });

  testWidgets('full screen: an X at the right of the top bar leaves it; none otherwise', (tester) async {
    tall(tester);
    fullscreen.value = true;
    addTearDown(() => fullscreen.value = false);
    await tester.pumpWidget(MaterialApp(home: AppSettingsScreen(api: FakeKomga(), onSignOut: () {})));
    await tester.pump();
    expect(find.byTooltip('Leave full screen (F11)'), findsOneWidget);
    fullscreen.value = false;
    await tester.pump();
    expect(find.byTooltip('Leave full screen (F11)'), findsNothing);
  });
}
