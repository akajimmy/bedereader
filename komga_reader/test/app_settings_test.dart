import 'dart:convert';
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
import 'package:shared_preferences/shared_preferences.dart';

import 'support/helpers.dart';
import 'support/no_network.dart';
import 'support/settings_pages.dart';
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

  testWidgets("a tap on a setting's control sets the stored value; on Comics and eBooks each kind its own (user, "
      "2026-10-07) - the other kind's stays", (tester) async {
    // one table for the tap-and-read-back tests of Comics / eBooks (each kind its own), the EPUB settings, the comic
    // defaults' page colour, Reading, Library & Home and Look (test audit, 2026-10-07)
    tall(tester);
    final s = AppSettings.instance;
    final before = s.defaults;
    s.setDisplay(const DisplayPrefs());
    addTearDown(() {
      s.setDisplay(const DisplayPrefs());
      s.setEpub(const EpubPrefs());
      s.setDefault(before);
    });
    Finder segment<T>(String label) => find.descendant(of: find.byType(SegmentedButton<T>), matching: find.text(label));
    String spots(BookKind k) => s.display.kind(k).hiddenSpots.join(',');
    final steps = <(SettingsPage, Finder, Object? Function(), Object?)>[
      // Comics: each kind its own position text, progress bar
      (SettingsPage.comics, find.widgetWithText(FilterChip, 'Book title'),
          () => (spots(BookKind.comics), spots(BookKind.ebooks)), ('centre', '')),
      (SettingsPage.comics, find.widgetWithText(SwitchListTile, 'Page strip'), () => s.display.pageStrip, true),
      (SettingsPage.comics, find.widgetWithText(SwitchListTile, 'Progress bar'),
          () => (s.display.comics.progressBar, s.display.ebooks.progressBar), (true, false)),
      (SettingsPage.comics, segment<PageTurn>('None'), () => s.display.pageTurn, PageTurn.flip), // "None" is the flip
      // the page colours, for every series that follows the defaults (synced; user, 2026-10-05)
      (SettingsPage.comics, find.bySemanticsLabel('White background'),
          () => (s.defaults.background, s.prefsFor('S-follows-defaults').background),
          (ReaderBackground.white, ReaderBackground.white)),
      // eBooks: the other kind's position text, progress bar and page corner
      (SettingsPage.ebooks, find.widgetWithText(FilterChip, 'Chapter progress'),
          () => (spots(BookKind.comics), spots(BookKind.ebooks)), ('centre', 'right')),
      (SettingsPage.ebooks, find.widgetWithText(FilterChip, 'Chapter progress'),
          () => (spots(BookKind.comics), spots(BookKind.ebooks)), ('centre', '')),
      (SettingsPage.ebooks, find.widgetWithText(SwitchListTile, 'Progress bar'),
          () => (s.display.comics.progressBar, s.display.ebooks.progressBar), (true, true)),
      (SettingsPage.ebooks, segment<PageNote>('Off'),
          () => (s.display.comics.pageNote, s.display.ebooks.pageNote), (PageNote.afterTurn, PageNote.off)),
      // eBooks: the EPUB settings (the alignment on its own: user, 2026-10-07)
      (SettingsPage.ebooks, find.widgetWithText(ChoiceChip, 'Lora'), () => s.epub.font, EpubFont.lora),
      (SettingsPage.ebooks, find.byTooltip('Larger'), () => s.epub.size, 20),
      (SettingsPage.ebooks, segment<EpubAlign>('Left'),
          () => (s.epub.align, s.epub.paragraphs), (EpubAlign.left, EpubParagraphs.mine)),
      (SettingsPage.ebooks, find.widgetWithText(SwitchListTile, 'Auto-hyphenation'), () => s.epub.hyphenate, false),
      (SettingsPage.ebooks, find.text('Loose'), () => s.epub.lineSpacing, 1.7),
      // Reading
      (SettingsPage.reading, find.descendant(of: find.byType(SegmentedButton<MidBook>), matching: find.text('Yes')),
          () => s.display.midBook, MidBook.markRead),
      (SettingsPage.reading, find.text('10 min'), () => s.display.screenOn, 10),
      // Library & Home: the poster size, and the three caption lines each on or off (user, 2026-10-07)
      (SettingsPage.library, find.text('Large'), () => s.display.posterSize, PosterSize.large),
      (SettingsPage.library, find.widgetWithText(FilterChip, 'Series #'),
          () => (s.display.posterSeries, s.display.posterTitle, s.display.posterDate), (false, true, true)),
      (SettingsPage.library, find.widgetWithText(FilterChip, 'Release date'),
          () => (s.display.posterSeries, s.display.posterTitle, s.display.posterDate), (false, true, false)),
      // Look
      (SettingsPage.look, find.text('115%'), () => s.display.textScale, 1.15),
      (SettingsPage.look, find.bySemanticsLabel('Green'), () => s.display.accent, Accent.green),
    ];
    expect((s.display.posterSeries, s.display.posterTitle, s.display.posterDate), (true, true, true));
    await open(tester, page: steps.first.$1);
    var on = steps.first.$1;
    for (final (i, (page, control, read, expected)) in steps.indexed) {
      if (page != on) {
        await tester.tap(find.widgetWithText(ListTile, pageName(page)));
        await tester.pumpAndSettle();
        on = page;
      }
      await tester.tap(control);
      await tester.pumpAndSettle();
      expect(read(), expected, reason: 'step $i (${page.name}): $control');
    }
    await tester.pump(const Duration(seconds: 3)); // the settings sync timer
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
    // every one of this device's settings away from its default (test audit, 2026-10-07: a field left at its default
    // could be dropped from a reset and nothing failed)
    const away = DisplayPrefs(night: true, warmth: 0.2, brightness: 0.6, pageTurn: PageTurn.curl, doubleTapZoom: false,
        midBook: MidBook.keep, screenOn: 5, posterSize: PosterSize.large, posterSeries: false, posterTitle: false,
        posterDate: false, nightSchedule: true, nightFrom: 1200, nightTo: 360, textScale: 1.3, accent: Accent.green,
        pagePreviews: false, pageStrip: true,
        comics: KindPrefs(pageNote: PageNote.off, rotation: Rotation.landscape, clock: ShowWhen.always,
            progressBar: true, hiddenSpots: ['left']),
        ebooks: KindPrefs(pageNote: PageNote.off, rotation: Rotation.portrait, clock: ShowWhen.off, progressBar: true,
            hiddenSpots: ['right']));
    const awayEpub = EpubPrefs(font: EpubFont.lora, size: 24, lineSpacing: 1.7, margins: EpubMargins.wide,
        colours: EpubColours.sepia, align: EpubAlign.left, paragraphs: EpubParagraphs.book, hyphenate: false,
        turn: EpubTurn.none, paragraphGap: EpubParagraphGap.small);
    const awayDefaults = ReaderPrefs(fit: FitMode.width, brightness: 0.1, contrast: 0.1, sharpen: true,
        autoLevels: true, direction: ReadingDirection.rtl, crop: 0.05, background: ReaderBackground.white);
    // which page's reset puts back each of this device's settings (by its saved name); null: no page's
    const resetBy = <String, String?>{
      'brightness': 'Reading', 'screenOn': 'Reading', 'midBook': 'Reading',
      'pageTurn': 'Comics', 'doubleTapZoom': 'Comics', 'pagePreviews': 'Comics', 'pageStrip': 'Comics',
      'comics': 'Comics',
      'ebooks': 'eBooks',
      'night': 'Look', 'nightSchedule': 'Look', 'nightFrom': 'Look', 'nightTo': 'Look', 'warmth': 'Look',
      'textScale': 'Look', 'accent': 'Look',
      'posterSize': null, 'posterSeries': null, 'posterTitle': null, 'posterDate': null,
    };
    final none = const DisplayPrefs().toJson(), moved = away.toJson();
    expect(resetBy.keys.toSet(), moved.keys.toSet(), reason: 'every setting placed in the table');
    for (final k in moved.keys) {
      expect(jsonEncode(moved[k]), isNot(jsonEncode(none[k])), reason: '$k: away from its default');
    }
    for (final e in const EpubPrefs().toJson().entries) {
      expect(jsonEncode(awayEpub.toJson()[e.key]), isNot(jsonEncode(e.value)), reason: 'epub ${e.key}: away');
    }
    for (final e in const ReaderPrefs().toJson().entries) {
      expect(jsonEncode(awayDefaults.toJson()[e.key]), isNot(jsonEncode(e.value)), reason: 'defaults ${e.key}: away');
    }
    s.setDisplay(away);
    s.setEpub(awayEpub);
    s.setDefault(awayDefaults);
    s.setSeries('S7', const ReaderPrefs(fit: FitMode.height));
    final done = <String>{};
    /// After the resets of [done]: their settings at the defaults, every other one as it was set.
    void checkAll() {
      final now = s.display.toJson();
      for (final k in resetBy.keys) {
        final back = done.contains(resetBy[k]);
        expect(jsonEncode(now[k]), jsonEncode(back ? none[k] : moved[k]),
            reason: '$k: ${back ? 'put back by Reset ${resetBy[k]}' : 'untouched by Reset ${done.join(', ')}'}');
      }
      expect(s.defaults, done.contains('Comics') ? const ReaderPrefs() : awayDefaults, reason: 'the comic defaults');
      expect(s.epub, done.contains('eBooks') ? const EpubPrefs() : awayEpub, reason: 'the EPUB settings');
      expect(s.series['S7']?.fit, FitMode.height, reason: "a series' own settings stay");
    }
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
    checkAll(); // cancelled: nothing changed
    for (final page in ['Reading', 'Comics', 'eBooks', 'Look']) {
      await reset(page);
      done.add(page);
      checkAll();
    }
    await tester.pump(const Duration(seconds: 3)); // the settings sync timer
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
    expect(find.text('9:00 PM'), findsOneWidget); // its start, 21:00, in the test's 12-hour format
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

  testWidgets('Comics: the comic defaults are edited here; series with their own settings can all be reset',
      (tester) async {
    tall(tester);
    final s = AppSettings.instance;
    addTearDown(() { // put back even if the test fails part way
      s.setDefault(const ReaderPrefs());
      s.series.remove('S1');
      s.series.remove('S2');
    });
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
        textScale: 1.3, accent: Accent.green));
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
    expect((s.epub.size, s.epub.font), (24.0, EpubFont.lora), reason: 'the EPUB set is synced: untouched');
    await tester.pump(const Duration(seconds: 5)); // the snackbar and the settings sync timer
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

  group('the remote keeps its place (code review 2026-10-05, #26)', () {
    /// The remote's focus is on what [f] finds (the focused control's box holds its centre).
    bool on(WidgetTester tester, Finder f) {
      final r = FocusManager.instance.primaryFocus?.rect;
      // its own box, not a row's that happens to hold it
      return r != null && r.contains(tester.getCenter(f)) && r.width < tester.getSize(f).width + 80;
    }

    testWidgets("a key chip removed with OK: the focus goes to its row's Add, not lost with the chip", (tester) async {
      tall(tester);
      addTearDown(ReaderKeys.instance.reset);
      await open(tester, page: SettingsPage.keys);
      await tester.pumpAndSettle();
      Focus.of(tester.element(find.text('PgDn'))).requestFocus();
      await tester.pump();
      expect(on(tester, find.text('PgDn')), isTrue);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(find.text('PgDn'), findsNothing);
      final focused = FocusManager.instance.primaryFocus!.rect;
      expect(focused.top, greaterThan(tester.getRect(find.text('Next page')).bottom), reason: 'in the Next page row');
      expect(focused.bottom, lessThan(tester.getRect(find.text('Previous page')).top));
      final add = find.descendant(of: find.ancestor(of: find.text('Next page'), matching: find.byType(Column)).first,
          matching: find.text('Add'));
      expect(on(tester, add), isTrue, reason: 'on Add');
    });

    testWidgets('a Home section moved to the top with ▲: the focus stays on that ▲', (tester) async {
      tall(tester);
      await open(tester, page: SettingsPage.library);
      await tester.pumpAndSettle();
      final second = HomeSections.names[HomeSections.instance.order[1]]!;
      final up = find.byTooltip('Move $second up');
      Focus.of(tester.element(find.descendant(of: up, matching: find.byType(Icon)))).requestFocus(); // the button's own
      await tester.pump();
      expect(on(tester, up), isTrue);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(HomeSections.names[HomeSections.instance.order.first], second, reason: 'moved to the top');
      expect(on(tester, up), isTrue, reason: 'still there for the remote');
    });
  });

  testWidgets("Reading: the screen takes the reader's brightness while its slider is in use - touched, or the remote "
      'on it - and goes back once let go, left, or the page changed (user, 2026-10-07 QA: it showed nothing)',
      (tester) async {
    tall(tester);
    final s = AppSettings.instance;
    s.setDisplay(const DisplayPrefs(brightness: 0.4));
    addTearDown(() => s.setDisplay(const DisplayPrefs()));
    await open(tester, page: SettingsPage.reading);
    await tester.pumpAndSettle();
    final slider = find.byType(Slider);
    expect(s.brightnessShown, isFalse, reason: 'Settings: the system brightness');
    final g = await tester.startGesture(tester.getCenter(slider));
    await tester.pump();
    expect(s.brightnessShown, isTrue, reason: 'a finger on the slider');
    await g.up();
    await tester.pump();
    expect(s.brightnessShown, isFalse, reason: 'let go');
    // the remote's focus on it (the slider's own node)
    final sliderEl = slider.evaluate().single;
    final node = FocusManager.instance.rootScope.descendants.firstWhere((n) {
      var inside = false;
      n.context?.visitAncestorElements((e) => !(inside = e == sliderEl));
      return inside;
    });
    node.requestFocus();
    await tester.pump();
    expect(s.brightnessShown, isTrue, reason: 'the remote on the slider');
    await tester.tap(find.widgetWithText(ListTile, 'Look')); // another page: the slider gone
    await tester.pumpAndSettle();
    expect(s.brightnessShown, isFalse, reason: 'never left on with the page gone');
  });

  testWidgets('Library & Home and Downloads have their reset too (user, 2026-10-07): asked first; posters, the '
      'libraries shown and Home sections back - On deck (synced) untouched; the download settings back - the books stay',
      (tester) async {
    tall(tester);
    final s = AppSettings.instance, d = Downloads.instance;
    final dir = (await tester.runAsync(() => Directory.systemTemp.createTemp('komga_page_reset')))!;
    addTearDown(() async {
      d.store = null;
      s.setDisplay(const DisplayPrefs());
      await deleteTemp(dir);
    });
    await tester.runAsync(() async {
      await d.attach(noNetwork(StatusServer.new), root: dir, start: false);
      await d.setCap(Downloads.gb);
      await d.setWifiOnly(true);
      await d.setDeleteRead(DeleteRead.always);
    });
    s.setDisplay(const DisplayPrefs(posterSize: PosterSize.large, posterTitle: false, screenOn: 5));
    await HiddenLibraries.instance.setHidden('L1', true);
    await HomeSections.instance.set('ondeck', false);
    Future<void> reset(String page) async {
      await tester.tap(find.widgetWithText(ListTile, page));
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(find.widgetWithText(TextButton, 'Reset $page'), 200,
          scrollable: find.byType(Scrollable).last);
      await tester.tap(find.widgetWithText(TextButton, 'Reset $page'));
      await tester.pumpAndSettle();
      expect(find.text('Reset $page?'), findsOneWidget);
      await tester.tap(find.widgetWithText(TextButton, 'Reset').last);
      await tester.runAsync(pumpEventQueue);
      await tester.pumpAndSettle();
    }

    await open(tester, page: SettingsPage.library);
    await reset('Library & Home');
    expect((s.display.posterSize, s.display.posterTitle), (PosterSize.medium, true));
    expect(HiddenLibraries.instance.ids, isEmpty, reason: 'every library shown again');
    expect(HomeSections.instance['ondeck'], isTrue);
    expect(s.display.screenOn, 5, reason: "another page's setting stays");
    await reset('Downloads');
    expect((d.capBytes, d.wifiOnly, d.deleteRead), (Downloads.defaultCap, false, DeleteRead.never));
  });
}
