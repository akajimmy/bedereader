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
import 'package:komga_reader/widgets/display_panel.dart' show NightMode;
import 'package:komga_reader/widgets/drawer.dart';
import 'package:komga_reader/widgets/poster.dart' show PosterSizeButton;
import 'package:komga_reader/widgets/setting_rows.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/helpers.dart';
import 'support/no_network.dart';
import 'support/status_server.dart';

/// A tall window, wide enough for the side list of pages: a whole page fits, nothing to scroll to.
void tall(WidgetTester tester, {double width = 1000}) => setView(tester, Size(width, 2400));

Future<void> open(WidgetTester tester, {SettingsPage page = SettingsPage.server, VoidCallback? onSignOut,
    // (the screen itself opens on Reading; these tests start on Server unless they say)
    Komga? api}) async {
  await tester.pumpWidget(MaterialApp(home: AppSettingsScreen(api: api ?? noNetwork(StatusServer.new),
      onSignOut: onSignOut ?? () {},
      initialPage: page)));
  await tester.pump();
}

/// Each page's name in the list (to move between pages; a switch, so a new page doesn't compile here until added).
String pageName(SettingsPage p) => switch (p) {
      SettingsPage.reading => 'Reading',
      SettingsPage.comics => 'Comics',
      SettingsPage.ebooks => 'eBooks',
      SettingsPage.keys => 'Remote and keys',
      SettingsPage.server => 'Server and sync',
      SettingsPage.library => 'Library & Home',
      SettingsPage.downloads => 'Downloads',
      SettingsPage.look => 'Look',
      SettingsPage.about => 'About',
    };

void main() {
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await HomeSections.instance.load();
  });

  testWidgets('side menu: Settings and About each open their screen; Settings opens on Reading', (tester) async {
    final scaffold = GlobalKey<ScaffoldState>();
    await tester.pumpWidget(MaterialApp(home: Scaffold(key: scaffold,
        drawer: AppDrawer(api: noNetwork(StatusServer.new), onSignOut: () {}), body: const SizedBox())));
    scaffold.currentState!.openDrawer();
    await tester.pumpAndSettle();
    await tester.tap(find.text('Settings'));
    await tester.pumpAndSettle();
    expect(find.byType(AppSettingsScreen), findsOneWidget);
    expect(tester.widget<ListTile>(find.widgetWithText(ListTile, 'Reading')).selected, isTrue);

    await tester.pageBack();
    await tester.pumpAndSettle();
    scaffold.currentState!.openDrawer();
    await tester.pumpAndSettle();
    await tester.tap(find.text('About'));
    await tester.pumpAndSettle();
    expect(find.byType(AboutScreen), findsOneWidget);
  });

  testWidgets('wide: a tap on a page in the side list shows that page, one at a time; Downloads only once set up',
      (tester) async {
    tall(tester);
    await open(tester);
    await tester.pumpAndSettle();
    expect(find.widgetWithText(ListTile, 'Downloads'), findsNothing);
    expect(find.text('Connected as nick@test'), findsOneWidget); // Server: the status
    for (final p in SettingsPage.values) {
      if (p == SettingsPage.downloads) continue;
      await tester.tap(find.widgetWithText(ListTile, pageName(p)).first);
      await tester.pumpAndSettle();
      expect(tester.widget<ListTile>(find.widgetWithText(ListTile, pageName(p)).first).selected, isTrue);
      if (p != SettingsPage.server) {
        expect(find.text('Connected as nick@test'), findsNothing, reason: 'one page at a time (${p.name})');
      }
    }
  });

  testWidgets('Comics and eBooks: each its own position text, page corner and progress bar; the page strip switch '
      '(user, 2026-10-07)', (tester) async {
    tall(tester);
    final s = AppSettings.instance;
    s.setDisplay(const DisplayPrefs());
    addTearDown(() => s.setDisplay(const DisplayPrefs()));
    Future<void> tap(Finder f) async {
      await tester.tap(f);
      await tester.pumpAndSettle();
    }

    await open(tester, page: SettingsPage.comics);
    await tap(find.widgetWithText(FilterChip, 'Title'));
    expect(s.display.comics.hiddenSpots, ['centre']);
    expect(s.display.ebooks.hiddenSpots, isEmpty);
    await tap(find.widgetWithText(SwitchListTile, 'Page strip'));
    expect(s.display.pageStrip, isTrue);
    await tap(find.widgetWithText(SwitchListTile, 'Progress bar'));
    expect((s.display.comics.progressBar, s.display.ebooks.progressBar), (true, false));

    await tap(find.widgetWithText(ListTile, 'eBooks'));
    await tap(find.widgetWithText(FilterChip, 'Chapter page'));
    expect(s.display.ebooks.hiddenSpots, ['right']);
    await tap(find.widgetWithText(FilterChip, 'Chapter page'));
    expect(s.display.ebooks.hiddenSpots, isEmpty);
    expect(s.display.comics.hiddenSpots, ['centre']);
    await tap(find.widgetWithText(SwitchListTile, 'Progress bar'));
    expect((s.display.comics.progressBar, s.display.ebooks.progressBar), (true, true));
    await tap(find.descendant(of: find.byType(SegmentedButton<PageNote>), matching: find.text('Off')));
    expect((s.display.comics.pageNote, s.display.ebooks.pageNote), (PageNote.afterTurn, PageNote.off));
  });

  testWidgets("a reset on each page (user, 2026-10-07): asked first; it puts back that page's settings and no others",
      (tester) async {
    tall(tester);
    final s = AppSettings.instance;
    addTearDown(() {
      s.setDisplay(const DisplayPrefs());
      s.setEpub(const EpubPrefs());
      s.setDefault(const ReaderPrefs());
      s.series.remove('S7');
    });
    const away = DisplayPrefs(screenOn: 5, midBook: MidBook.keep, night: true, accent: Accent.teal,
        pageTurn: PageTurn.curl, pageStrip: true, comics: KindPrefs(progressBar: true),
        ebooks: KindPrefs(progressBar: true));
    s.setDisplay(away);
    s.setEpub(const EpubPrefs(font: EpubFont.lora, size: 24));
    s.setDefault(const ReaderPrefs(fit: FitMode.width));
    s.setSeries('S7', const ReaderPrefs(fit: FitMode.height));
    Future<void> reset(String page, {bool confirm = true}) async {
      await tester.tap(find.widgetWithText(ListTile, page));
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(find.widgetWithText(TextButton, 'Reset $page'), 200,
          scrollable: find.byType(Scrollable).last);
      await tester.tap(find.widgetWithText(TextButton, 'Reset $page'));
      await tester.pumpAndSettle();
      expect(find.text('Reset $page?'), findsOneWidget);
      await tester.tap(find.widgetWithText(TextButton, confirm ? 'Reset' : 'Cancel').last);
      await tester.pumpAndSettle();
    }

    await open(tester, page: SettingsPage.reading);
    await reset('Reading', confirm: false);
    expect(s.display.screenOn, 5, reason: 'cancelled');
    await reset('Reading');
    expect((s.display.screenOn, s.display.midBook), (0, MidBook.ask));
    expect((s.display.night, s.display.pageTurn), (true, PageTurn.curl), reason: "other pages' settings stay");

    await reset('Comics');
    expect((s.display.pageTurn, s.display.pageStrip, s.display.comics.progressBar), (PageTurn.swipe, false, false));
    expect(s.defaults.fit, FitMode.screen);
    expect(s.series['S7']?.fit, FitMode.height, reason: "a series' own settings stay");
    expect(s.display.ebooks.progressBar, isTrue);
    expect(s.epub.font, EpubFont.lora);

    await reset('eBooks');
    expect((s.epub.font, s.epub.size), (EpubFont.literata, 19.0));
    expect(s.display.ebooks.progressBar, isFalse);
    expect(s.display.night, isTrue);

    await reset('Look');
    expect((s.display.night, s.display.accent), (false, Accent.blue));
    await tester.pump(const Duration(seconds: 3)); // the settings sync timer
  });

  testWidgets("eBooks: the font, size and the book's formatting set the EPUB settings (synced)", (tester) async {
    tall(tester);
    final s = AppSettings.instance;
    addTearDown(() => s.setEpub(const EpubPrefs()));
    await open(tester, page: SettingsPage.ebooks);
    await tester.tap(find.widgetWithText(ChoiceChip, 'Lora'));
    await tester.pump();
    expect(s.epub.font, EpubFont.lora);
    await tester.tap(find.byTooltip('Larger'));
    await tester.pump();
    expect(s.epub.size, 20);
    // "Book's formatting" in three (user, 2026-10-07): the alignment on its own
    await tester.tap(find.descendant(of: find.byType(SegmentedButton<EpubAlign>), matching: find.text('Left')));
    await tester.pump();
    expect((s.epub.align, s.epub.paragraphs), (EpubAlign.left, EpubParagraphs.mine));
    await tester.tap(find.widgetWithText(SwitchListTile, 'Hyphenation'));
    await tester.pump();
    expect(s.epub.hyphenate, isFalse);
    await tester.tap(find.text('Loose'));
    await tester.pump();
    expect(s.epub.lineSpacing, 1.7);
  });

  testWidgets('narrow: the pages as a table of contents at the top', (tester) async {
    tall(tester, width: 420);
    await open(tester);
    expect(find.byType(ChoiceChip), findsNWidgets(8)); // no Downloads here (downloads not set up in tests)
    await tester.tap(find.widgetWithText(ChoiceChip, 'Comics'));
    await tester.pumpAndSettle();
    expect(find.text('Turning pages'), findsOneWidget);
    expect(tester.widget<ChoiceChip>(find.widgetWithText(ChoiceChip, 'Comics')).selected, isTrue);
    expect(tester.takeException(), isNull); // no overflow at phone width
  });

  testWidgets("server status (Settings > Server): connected, key refused, unreachable - Retry checks again",
      (tester) async {
    // moved from about_test: the status left About for Settings (test audit, 2026-09-30)
    tall(tester);
    final api = noNetwork(StatusServer.new);
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
    await open(tester, page: SettingsPage.comics);
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

  testWidgets("night mode: Off / On / Scheduled, one choice on Look (user, 2026-10-07) - the same setting as the "
      "reader's moon", (tester) async {
    tall(tester);
    final s = AppSettings.instance;
    s.setDisplay(const DisplayPrefs());
    addTearDown(() => s.setDisplay(const DisplayPrefs()));
    await open(tester, page: SettingsPage.look);
    final seg = find.byType(SegmentedButton<NightMode>);
    Future<void> pick(String t) async {
      await tester.tap(find.descendant(of: seg, matching: find.text(t)));
      await tester.pumpAndSettle();
    }

    NightMode shown() => tester.widget<SegmentedButton<NightMode>>(seg).selected.single;
    expect(shown(), NightMode.off);
    expect(find.text('Warmth'), findsNothing);
    await pick('On');
    expect((s.display.night, s.display.nightSchedule), (true, false));
    expect(find.text('Warmth'), findsOneWidget); // shown while night mode is on
    expect(find.text('From / to'), findsNothing);
    await pick('Scheduled');
    expect(s.display.nightSchedule, isTrue);
    expect(find.text('From / to'), findsOneWidget);
    expect(find.text('Warmth'), findsOneWidget);
    await pick('Off');
    expect((s.display.night, s.display.nightSchedule), (false, false));
    expect(find.text('Warmth'), findsNothing);
    s.setDisplay(s.display.copyWith(night: true)); // e.g. switched on with the reader's moon
    await tester.pump();
    expect(shown(), NightMode.on);
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

  testWidgets('Comics: the reading defaults are edited here; series with their own settings can all be reset',
      (tester) async {
    tall(tester);
    final s = AppSettings.instance;
    s.setDefault(const ReaderPrefs());
    s.setSeries('S1', const ReaderPrefs(fit: FitMode.width));
    s.setSeries('S2', const ReaderPrefs(sharpen: true));
    await open(tester, page: SettingsPage.comics);
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

  testWidgets('Comics: the page colours are set there, for every series that follows the defaults (synced) '
      '(user, 2026-10-05)', (tester) async {
    tall(tester);
    final s = AppSettings.instance;
    final before = s.defaults;
    addTearDown(() => s.setDefault(before));
    await open(tester, page: SettingsPage.comics);
    await tester.tap(find.bySemanticsLabel('White background'));
    await tester.pumpAndSettle();
    expect(s.defaults.background, ReaderBackground.white);
    expect(s.prefsFor('S-follows-defaults').background, ReaderBackground.white);
    await tester.pump(const Duration(seconds: 3)); // the settings sync timer
  });

  testWidgets('Comics, Reading and Library & Home: the device settings are set here', (tester) async {
    tall(tester);
    final s = AppSettings.instance;
    s.setDisplay(const DisplayPrefs());
    addTearDown(() => s.setDisplay(const DisplayPrefs()));
    await open(tester, page: SettingsPage.comics);
    Future<void> tap(Finder f) async {
      await tester.tap(f);
      await tester.pumpAndSettle();
    }

    await tap(find.descendant(of: find.byType(SegmentedButton<PageTurn>), matching: find.text('None')));
    expect(s.display.pageTurn, PageTurn.flip); // "None" is the flip
    await tap(find.widgetWithText(ListTile, 'Reading'));
    await tap(find.text('Mark read'));
    expect(s.display.midBook, MidBook.markRead);
    await tap(find.text('10 min'));
    expect(s.display.screenOn, 10);
    await tap(find.widgetWithText(ListTile, 'Library & Home'));
    await tap(find.text('Large'));
    expect(s.display.posterSize, PosterSize.large);
    // the three caption lines, each on or off (user, 2026-10-07)
    expect((s.display.posterSeries, s.display.posterTitle, s.display.posterDate), (true, true, true));
    await tap(find.widgetWithText(FilterChip, 'Series #'));
    expect(s.display.posterSeries, isFalse);
    await tap(find.widgetWithText(FilterChip, 'Release date'));
    expect(s.display.posterDate, isFalse);
    expect(s.display.posterTitle, isTrue);
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
      s.setDisplay(const DisplayPrefs());
      s.setEpub(const EpubPrefs());
      s.series.remove('S9');
    });
    await tester.runAsync(() async {
      await d.attach(noNetwork(StatusServer.new), root: dir, start: false);
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
    s.setEpub(const EpubPrefs(size: 24, font: EpubFont.lora)); // the size is this device's; the font is synced
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
    expect((s.epub.size, s.epub.font), (19.0, EpubFont.lora), reason: "the eBook text size is this device's");
    await tester.pump(const Duration(seconds: 5)); // the snackbar and the settings sync timer
  });

  testWidgets('Look: text size and accent colour are set here; the schedule shows its times when on', (tester) async {
    tall(tester);
    final s = AppSettings.instance;
    s.setDisplay(const DisplayPrefs());
    addTearDown(() => s.setDisplay(const DisplayPrefs()));
    await open(tester, page: SettingsPage.look);
    await tester.tap(find.text('115%'));
    await tester.pumpAndSettle();
    expect(s.display.textScale, 1.15);
    await tester.tap(find.bySemanticsLabel('Teal'));
    await tester.pumpAndSettle();
    expect(s.display.accent, Accent.teal);
    expect(find.text('From / to'), findsNothing);
    await tester.tap(find.text('Scheduled'));
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
