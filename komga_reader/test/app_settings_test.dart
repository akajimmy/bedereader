import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:komga_reader/api.dart';
import 'package:komga_reader/hidden_libraries.dart';
import 'package:komga_reader/home_sections.dart';
import 'package:komga_reader/offline/connection.dart';
import 'package:komga_reader/offline/downloads.dart';
import 'package:komga_reader/reader_keys.dart';
import 'package:komga_reader/screen.dart';
import 'package:komga_reader/screens/about.dart';
import 'package:komga_reader/screens/app_settings.dart';
import 'package:komga_reader/settings.dart';
import 'package:komga_reader/widgets/drawer.dart';
import 'package:komga_reader/widgets/poster.dart' show PosterSizeButton;
import 'package:komga_reader/widgets/setting_rows.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// me() - the server status check - answers with whatever [next] says: 'ok', 'refused' or 'down'.
class FakeKomga extends Komga {
  FakeKomga() : super('http://192.168.1.10:25600', 'k');
  String next = 'ok';
  int calls = 0;
  @override
  Future<List<dynamic>> libraries() async => [];
  @override
  Future<Map<String, dynamic>?> me() async {
    calls++;
    if (next == 'refused') throw KomgaError(401, '/api/v2/users/me');
    if (next == 'down') throw KomgaUnreachable(baseUrl);
    return {'email': 'nick@test'};
  }
}

/// A tall window, wide enough for the side list of pages: a whole page fits, nothing to scroll to.
void tall(WidgetTester tester, {double width = 1000}) {
  tester.view.physicalSize = Size(width, 2400);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
}

Future<void> open(WidgetTester tester, {SettingsPage page = SettingsPage.server, VoidCallback? onSignOut,
    Komga? api}) async {
  await tester.pumpWidget(MaterialApp(home: AppSettingsScreen(api: api ?? FakeKomga(), onSignOut: onSignOut ?? () {},
      initialPage: page)));
  await tester.pump();
}

/// Each page's name in the list and the line under its title saying where its settings are kept (null: none). A
/// switch, so a new page doesn't compile here until it's added (test audit, 2026-09-30).
(String, String?) pageInfo(SettingsPage p) => switch (p) {
      SettingsPage.server => ('Server', 'Kept on this device'),
      SettingsPage.defaults => ('Reading defaults', 'Synced through Komga - every device'),
      SettingsPage.reader => ('Reader', 'Kept on this device'),
      SettingsPage.keys => ('Remote and keys', 'Kept on this device'),
      SettingsPage.display => ('Display', 'Kept on this device'),
      SettingsPage.library => ('Library & Home', 'Kept on this device, except On deck (synced)'),
      SettingsPage.downloads => ('Downloads', 'Kept on this device'),
      SettingsPage.about => ('About', null),
    };

void main() {
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await HomeSections.instance.load();
  });

  testWidgets('side menu: Home and the libraries, then Settings, then About, last; each opens its screen; '
      'no App settings / Info / Reader settings / Sign out', (tester) async {
    // one test for the menu's order (about_test had a second with the same setup - test audit, 2026-09-30)
    final scaffold = GlobalKey<ScaffoldState>();
    await tester.pumpWidget(MaterialApp(home: Scaffold(key: scaffold,
        drawer: AppDrawer(api: FakeKomga(), onSignOut: () {}), body: const SizedBox())));
    scaffold.currentState!.openDrawer();
    await tester.pumpAndSettle();
    double y(String t) => tester.getTopLeft(find.text(t)).dy;
    expect(y('Home') < y('All libraries'), isTrue);
    expect(y('All libraries') < y('Settings'), isTrue);
    expect(y('Settings') < y('About'), isTrue);
    for (final gone in ['App settings', 'Info', 'Reader settings', 'Sign out']) {
      expect(find.text(gone), findsNothing, reason: gone);
    }
    await tester.tap(find.text('Settings'));
    await tester.pumpAndSettle();
    expect(find.byType(AppSettingsScreen), findsOneWidget);
    expect(find.text('http://192.168.1.10:25600'), findsOneWidget); // opens on Server

    await tester.pageBack();
    await tester.pumpAndSettle();
    scaffold.currentState!.openDrawer();
    await tester.pumpAndSettle();
    await tester.tap(find.text('About'));
    await tester.pumpAndSettle();
    expect(find.byType(AboutScreen), findsOneWidget);
  });

  testWidgets('wide: every page down the side in order, one shown at a time, each saying where it is kept',
      (tester) async {
    tall(tester);
    await open(tester);
    await tester.pumpAndSettle();
    // every page but Downloads (shown only once downloads are set up - not in this test)
    final pages = [for (final p in SettingsPage.values) if (p != SettingsPage.downloads) p];
    final ys = [for (final p in pages) tester.getTopLeft(find.widgetWithText(ListTile, pageInfo(p).$1).first).dy];
    expect(ys, [...ys]..sort()); // in that order, down the side
    expect(find.widgetWithText(ListTile, 'Downloads'), findsNothing);
    expect(find.text('Connected as nick@test'), findsOneWidget); // Server: the status
    final scopes = {for (final p in SettingsPage.values) pageInfo(p).$2}.whereType<String>().toSet();
    for (final p in pages) {
      await tester.tap(find.widgetWithText(ListTile, pageInfo(p).$1).first);
      await tester.pumpAndSettle();
      final scope = pageInfo(p).$2;
      for (final s in scopes) {
        expect(find.text(s), s == scope ? findsOneWidget : findsNothing, reason: '${p.name}: "$s"');
      }
      if (p != SettingsPage.server) {
        expect(find.text('Connected as nick@test'), findsNothing, reason: 'one page at a time (${p.name})');
      }
    }
    await tester.tap(find.widgetWithText(ListTile, 'Display'));
    await tester.pumpAndSettle();
    expect(find.text('Screen brightness'), findsWidgets);
    expect(find.text('Night mode'), findsOneWidget);
  });

  testWidgets('narrow: the pages as a table of contents at the top', (tester) async {
    tall(tester, width: 420);
    await open(tester);
    expect(find.byType(ChoiceChip), findsNWidgets(7)); // no Downloads here (downloads not set up in tests)
    await tester.tap(find.widgetWithText(ChoiceChip, 'Reader'));
    await tester.pumpAndSettle();
    expect(find.text('Turning pages'), findsOneWidget);
    expect(tester.widget<ChoiceChip>(find.widgetWithText(ChoiceChip, 'Reader')).selected, isTrue);
    expect(tester.takeException(), isNull); // no overflow at phone width
  });

  testWidgets("server status (Settings > Server): connected, key refused, unreachable - Retry checks again",
      (tester) async {
    // moved from about_test: the status left About for Settings (test audit, 2026-09-30)
    tall(tester);
    final api = FakeKomga();
    await open(tester, api: api);
    await tester.pump();
    expect(find.text('Connected as nick@test'), findsOneWidget);

    api.next = 'refused';
    await tester.tap(find.text('Retry'));
    await tester.pump();
    expect(find.textContaining("Komga no longer accepts this device's API key."), findsOneWidget);

    api.next = 'down';
    await tester.tap(find.text('Retry'));
    await tester.pump();
    expect(find.textContaining("Can't reach Komga at 192.168.1.10:25600."), findsOneWidget); // no http://
    expect(api.calls, 3);
  });

  testWidgets("a segmented choice sits beside its label while both fit, and drops under it when they don't "
      '(the widths measured in the font in use)', (tester) async {
    // it used to check one row at 700 px, which only stacked because the test font is about twice as wide as a real
    // one; the window widths here come from the row's own measure, so the check holds in any font (test audit,
    // 2026-09-30)
    tall(tester, width: 700); // the narrow layout
    await open(tester, page: SettingsPage.reader);
    await tester.pump();
    final row = find.byWidgetPredicate((w) => w is SegmentRow && w.title == 'Page turn animation');
    final seg = tester.widget<SegmentRow>(row);
    final ctx = tester.element(row);
    // SegmentRow's sum: every segment as wide as the widest label, plus 28 each; the label gets up to 120, plus 12
    final widest = [for (final c in seg.choices) textWidth(ctx, c.label, 13)].reduce((a, b) => a > b ? a : b);
    final own = seg.choices.length * (widest + 28);
    final room = textWidth(ctx, seg.title, 14.5).clamp(0.0, 120.0) + 12;
    final margin = 700 - tester.getSize(row).width; // the page's padding around the row
    final fits = own + room + 28 + margin; // the narrowest window where the buttons sit beside the label
    expect(fits + 10, lessThan(760), reason: 'both widths still in the narrow layout');

    Future<bool> beside(double width) async {
      tester.view.physicalSize = Size(width, 2400);
      await tester.pump();
      await tester.pump(); // the shared width settles
      final buttons = tester.getRect(find.descendant(of: row, matching: find.byType(SegmentedButton<PageTurn>)));
      return buttons.top < tester.getRect(find.text('Page turn animation')).bottom;
    }

    expect(await beside(fits + 10), isTrue, reason: 'room for both at ${fits + 10}');
    expect(await beside(fits - 10), isFalse, reason: 'not at ${fits - 10}: under the label');
    expect(tester.takeException(), isNull);
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
    expect(s.display.pageTurn, PageTurn.flip); // "None" is the flip
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

  testWidgets("Reset this device's settings: asks first; every one of this device's settings goes back, synced ones "
      'stay', (tester) async {
    tall(tester);
    final s = AppSettings.instance;
    final conn = Connection.instance, d = Downloads.instance;
    // downloads set up, so the reset reaches "If Komga can't be reached" and the download settings too
    final dir = (await tester.runAsync(() => Directory.systemTemp.createTemp('komga_reset_test')))!;
    addTearDown(() {
      conn.reset();
      d.store = null; // downloads not set up again, for the other tests
      dir.deleteSync(recursive: true);
    });
    await tester.runAsync(() async {
      await d.attach(FakeKomga(), root: dir, start: false);
      await d.setCap(Downloads.gb);
      await d.setDeleteRead(DeleteRead.always);
    });
    await conn.setAutoSwitch(true);
    // every setting kept on this device, away from its default (test audit, 2026-09-30)
    s.setDisplay(const DisplayPrefs(night: true, posterSize: PosterSize.large, screenOn: 5, nightSchedule: true,
        textScale: 1.3, accent: Accent.teal));
    await ReaderKeys.instance.assign(ReaderAction.next, LogicalKeyboardKey.keyN);
    await HiddenLibraries.instance.setHidden('L1', true);
    await HomeSections.instance.set('ondeck', false);
    final p = await SharedPreferences.getInstance();
    await p.setString('view.library.all', '{"hideRead":true}');
    s.setSeries('S9', const ReaderPrefs(fit: FitMode.width)); // synced: untouched
    expect(ReaderKeys.instance.isDefault, isFalse);

    await open(tester, page: SettingsPage.about);
    await tester.tap(find.widgetWithText(TextButton, 'Reset'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(s.display.night, isTrue); // cancelled: nothing changed
    expect(ReaderKeys.instance.isDefault, isFalse);
    expect(HiddenLibraries.instance.ids, {'L1'});
    expect(conn.autoSwitch, isTrue);

    await tester.tap(find.widgetWithText(TextButton, 'Reset'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(TextButton, 'Reset').last); // confirm
    await tester.pumpAndSettle();
    final back = s.display;
    expect([back.night, back.posterSize, back.screenOn, back.nightSchedule, back.textScale, back.accent],
        [false, PosterSize.medium, 0, false, 1.0, Accent.blue]);
    expect(ReaderKeys.instance.isDefault, isTrue, reason: "the reader's keys");
    expect(ReaderKeys.instance.actionFor(LogicalKeyboardKey.keyN), isNull);
    expect(HiddenLibraries.instance.ids, isEmpty, reason: 'every library shown again');
    expect(HomeSections.instance['ondeck'], isTrue);
    expect(p.getString('view.library.all'), isNull);
    expect(conn.autoSwitch, isFalse, reason: "If Komga can't be reached: Ask");
    expect(d.capBytes, Downloads.defaultCap);
    expect(d.deleteRead, DeleteRead.never);
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
