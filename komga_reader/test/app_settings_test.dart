import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:komga_reader/api.dart';
import 'package:komga_reader/home_sections.dart';
import 'package:komga_reader/screen.dart';
import 'package:komga_reader/screens/app_settings.dart';
import 'package:komga_reader/settings.dart';
import 'package:komga_reader/widgets/drawer.dart';
import 'package:komga_reader/widgets/poster.dart' show PosterSizeButton;
import 'package:komga_reader/widgets/setting_rows.dart';
import 'package:shared_preferences/shared_preferences.dart';

class FakeKomga extends Komga {
  FakeKomga() : super('http://192.168.1.10:25600', 'k');
  @override
  Future<List<dynamic>> libraries() async => [];
  @override
  Future<Map<String, dynamic>?> me() async => {'email': 'nick@test'}; // the server status check
}

/// A tall window, wide enough for the side list of pages: a whole page fits, nothing to scroll to.
void tall(WidgetTester tester, {double width = 1000}) {
  tester.view.physicalSize = Size(width, 2400);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
}

Future<void> open(WidgetTester tester, {SettingsPage page = SettingsPage.server, VoidCallback? onSignOut}) async {
  await tester.pumpWidget(MaterialApp(home: AppSettingsScreen(api: FakeKomga(), onSignOut: onSignOut ?? () {},
      initialPage: page)));
  await tester.pump();
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
    expect(find.text('http://192.168.1.10:25600'), findsOneWidget); // opens on Server
  });

  testWidgets('wide: the pages down the side, one shown at a time, each saying where it is kept', (tester) async {
    tall(tester);
    await open(tester);
    await tester.pumpAndSettle();
    final names = ['Server', 'Reading defaults', 'Reader', 'Display', 'Library & Home', 'About'];
    final ys = [for (final n in names) tester.getTopLeft(find.widgetWithText(ListTile, n).first).dy];
    expect(ys, [...ys]..sort()); // in that order, down the side
    expect(find.text('Connected as nick@test'), findsOneWidget); // Server: the status, from Info
    expect(find.text('Kept on this device'), findsOneWidget);
    await tester.tap(find.widgetWithText(ListTile, 'Reading defaults'));
    await tester.pumpAndSettle();
    expect(find.text('Synced through Komga - every device'), findsOneWidget);
    expect(find.text('Connected as nick@test'), findsNothing); // one page at a time
    await tester.tap(find.widgetWithText(ListTile, 'Display'));
    await tester.pumpAndSettle();
    expect(find.text('Screen brightness'), findsWidgets);
    expect(find.text('Night mode'), findsOneWidget);
  });

  testWidgets('narrow: the pages as a table of contents at the top', (tester) async {
    tall(tester, width: 420);
    await open(tester);
    expect(find.byType(ChoiceChip), findsNWidgets(6)); // no Downloads here (downloads not set up in tests)
    await tester.tap(find.widgetWithText(ChoiceChip, 'Reader'));
    await tester.pumpAndSettle();
    expect(find.text('Turning pages'), findsOneWidget);
    expect(tester.widget<ChoiceChip>(find.widgetWithText(ChoiceChip, 'Reader')).selected, isTrue);
    expect(tester.takeException(), isNull); // no overflow at phone width
  });

  testWidgets('a segmented choice sits beside a short label, and under a long one when the row is narrow',
      (tester) async {
    tall(tester, width: 700); // still the narrow layout; the test font is wider than the real one
    await open(tester, page: SettingsPage.reader);
    Offset label(String t) => tester.getTopLeft(find.text(t));
    Offset button(String t) => tester.getTopLeft(find.text(t).last);
    expect(button('Wipe').dy, lessThan(label('Page turn animation').dy + 20)); // beside
    expect(button('30 min').dy, greaterThan(label('Keep the screen on').dy + 20)); // under
  });

  testWidgets('Home section switches here are the same setting as the Home menu (shared, saved)', (tester) async {
    tall(tester);
    await open(tester, page: SettingsPage.library);
    Finder onDeckSwitch() => find.descendant(
        of: find.ancestor(of: find.text('On deck').first, matching: find.byType(Row)).first, matching: find.byType(Switch));
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
    await open(tester, page: SettingsPage.display);
    final night = find.widgetWithText(SwitchListTile, 'Night mode');
    await tester.tap(night);
    await tester.pump();
    expect(s.display.night, isTrue);
    expect(find.text('Warmth'), findsOneWidget); // shown while night mode is on
    s.setDisplay(s.display.copyWith(night: false)); // e.g. switched off in the reader
    await tester.pump();
    expect(tester.widget<SwitchListTile>(night).value, isFalse);
    expect(find.text('Warmth'), findsNothing);
  });

  testWidgets('sign out asks first; Cancel keeps you signed in', (tester) async {
    tall(tester);
    var signedOut = 0;
    await open(tester, onSignOut: () => signedOut++);
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

  testWidgets('Reading defaults: edited here; series with their own settings can all be reset', (tester) async {
    tall(tester);
    final s = AppSettings.instance;
    s.setDefault(const ReaderPrefs());
    s.setSeries('S1', const ReaderPrefs(fit: FitMode.width));
    s.setSeries('S2', const ReaderPrefs(sharpen: true));
    await open(tester, page: SettingsPage.defaults);
    await tester.tap(find.text('Height'));
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

  testWidgets('Reader and Library & Home: the new device settings are set here', (tester) async {
    tall(tester);
    final s = AppSettings.instance;
    s.setDisplay(const DisplayPrefs());
    addTearDown(() => s.setDisplay(const DisplayPrefs()));
    await open(tester, page: SettingsPage.reader);
    Future<void> tap(Finder f) async {
      await tester.tap(f);
      await tester.pumpAndSettle();
    }

    await tap(find.text('None'));
    expect(s.display.pageTurn, PageTurn.flip); // "None" is the old Instant flip: saved choices carry over
    await tap(find.text('Mark read'));
    expect(s.display.midBook, MidBook.markRead);
    await tap(find.bySemanticsLabel('White background'));
    expect(s.display.background, ReaderBackground.white);
    await tap(find.text('10 min'));
    expect(s.display.screenOn, 10);
    await tap(find.widgetWithText(ListTile, 'Library & Home'));
    await tap(find.text('Large'));
    expect(s.display.posterSize, PosterSize.large);
    await tap(find.text('Title only'));
    expect(s.display.posterTitleOnly, isTrue);
  });

  testWidgets("Reset this device's settings: asks first; this device's settings go back, synced ones stay",
      (tester) async {
    tall(tester);
    final s = AppSettings.instance;
    s.setDisplay(const DisplayPrefs(night: true, posterSize: PosterSize.large, screenOn: 5));
    s.setSeries('S9', const ReaderPrefs(fit: FitMode.width)); // synced: untouched
    await HomeSections.instance.set('ondeck', false);
    final p = await SharedPreferences.getInstance();
    await p.setString('view.library.all', '{"hideRead":true}');
    await open(tester, page: SettingsPage.about);
    await tester.tap(find.widgetWithText(TextButton, 'Reset'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(s.display.night, isTrue); // cancelled: nothing changed
    await tester.tap(find.widgetWithText(TextButton, 'Reset'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(TextButton, 'Reset').last); // confirm
    await tester.pumpAndSettle();
    expect(s.display.night, isFalse);
    expect(s.display.posterSize, PosterSize.medium);
    expect(s.display.screenOn, 0); // Off by default
    expect(HomeSections.instance['ondeck'], isTrue);
    expect(p.getString('view.library.all'), isNull);
    expect(s.series['S9']?.fit, FitMode.width);
    s.series.remove('S9');
    await tester.pump(const Duration(seconds: 5)); // the snackbar and the settings sync timer
  });

  test('new device settings survive the saved form; older saves get the defaults', () {
    const d = DisplayPrefs(midBook: MidBook.keep, background: ReaderBackground.grey, screenOn: 20,
        posterSize: PosterSize.small, posterTitleOnly: true, pageTurn: PageTurn.curl);
    final back = DisplayPrefs.fromJson(d.toJson());
    expect([back.midBook, back.background, back.screenOn, back.posterSize, back.posterTitleOnly, back.pageTurn],
        [MidBook.keep, ReaderBackground.grey, 20, PosterSize.small, true, PageTurn.curl]);
    final old = DisplayPrefs.fromJson({'night': true, 'pageTurn': 'flip'});
    expect([old.midBook, old.background, old.screenOn, old.posterSize, old.posterTitleOnly, old.pageTurn],
        [MidBook.ask, ReaderBackground.black, 0, PosterSize.medium, false, PageTurn.flip]);
    expect(DisplayPrefs.fromJson({'screenOn': 7}).screenOn, 0); // not a choice: the default
  });

  testWidgets('Display: text size and accent colour are set here; the schedule shows its times when on', (tester) async {
    tall(tester);
    final s = AppSettings.instance;
    s.setDisplay(const DisplayPrefs());
    addTearDown(() => s.setDisplay(const DisplayPrefs()));
    await open(tester, page: SettingsPage.display);
    await tester.tap(find.text('115%'));
    await tester.pumpAndSettle();
    expect(s.display.textScale, 1.15);
    await tester.tap(find.bySemanticsLabel('Teal'));
    await tester.pumpAndSettle();
    expect(s.display.accent, Accent.teal);
    expect(find.text('From / to'), findsNothing);
    await tester.tap(find.widgetWithText(SwitchListTile, 'On a schedule'));
    await tester.pumpAndSettle();
    expect(s.display.nightSchedule, isTrue);
    expect(find.text('From / to'), findsOneWidget);
    expect(find.text('9:00 PM'), findsOneWidget); // 21:00, in the test's 12-hour format
  });

  testWidgets('segmented choices on a page share one width (the widest), flush right', (tester) async {
    tall(tester, width: 1200);
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: SettingsColumn(child: Column(children: [
      SettingsGroup(children: [
        SegmentRow<int>(title: 'A', choices: const [Choice(1, 'x'), Choice(2, 'y')], value: 1, onChanged: (_) {}),
        SegmentRow<String>(title: 'B', value: 'a', onChanged: (_) {},
            choices: const [Choice('a', 'aaaa'), Choice('b', 'bbbb'), Choice('c', 'cccc')]),
      ]),
    ])))));
    await tester.pump(); // the column widens after the first frame
    final small = tester.getRect(find.byType(SegmentedButton<int>));
    final wide = tester.getRect(find.byType(SegmentedButton<String>));
    expect(small.width, closeTo(wide.width, 0.5));
    expect(small.right, closeTo(wide.right, 0.5));
    expect(small.right, greaterThan(1200 - 20)); // flush with the row's right edge (inside its padding)
  });

  testWidgets('poster size button in a top bar: S / M / L, the same setting as here', (tester) async {
    final s = AppSettings.instance;
    s.setDisplay(const DisplayPrefs());
    addTearDown(() => s.setDisplay(const DisplayPrefs()));
    await tester.pumpWidget(MaterialApp(home: Scaffold(appBar: AppBar(actions: const [PosterSizeButton()]))));
    expect(find.text('M'), findsOneWidget);
    await tester.tap(find.byTooltip('Poster size: medium'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Large'));
    await tester.pumpAndSettle();
    expect(s.display.posterSize, PosterSize.large);
    expect(find.text('L'), findsOneWidget);
  });

  testWidgets('settings groups: rows are separated by hairlines, not spacers', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: Scaffold(body: SettingsGroup(title: 'G', children: [
      NoteRow('one'), NoteRow('two'), NoteRow('three'),
    ]))));
    expect(find.byType(Divider), findsNWidgets(2));
  });

  testWidgets('full screen: an X at the right of the top bar leaves it; none otherwise', (tester) async {
    tall(tester);
    fullscreen.value = true;
    addTearDown(() => fullscreen.value = false);
    await open(tester);
    expect(find.byTooltip('Leave full screen (F11)'), findsOneWidget);
    fullscreen.value = false;
    await tester.pump();
    expect(find.byTooltip('Leave full screen (F11)'), findsNothing);
  });
}
