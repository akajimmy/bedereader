// The EPUB settings (EpubPrefs): saved form, synced through Komga's client settings with the reading defaults, the
// reader and Settings > Books using them.
import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:komga_reader/epub/count_store.dart';
import 'package:komga_reader/reader/epub_renderer.dart';
import 'package:komga_reader/screens/reader.dart';
import 'package:komga_reader/settings.dart';
import 'package:komga_reader/widgets/epub_settings.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/epub_books.dart' show MemorySource, twoChapters;
import 'support/client_settings.dart';
import 'support/no_network.dart';

void main() {
  setUpAll(() => EpubRenderer.doubleTapWait = Duration.zero); // a middle tap: the controls at once (no double tap here)
  late EpubCountStore counts;
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    AppSettings.instance.setDisplay(const DisplayPrefs());
    counts = EpubCountStore.instance;
    EpubCountStore.instance = MemoryCountStore(); // the book counted afresh, never on disk
  });
  tearDown(() {
    AppSettings.instance.clearAccount();
    EpubCountStore.instance = counts;
  });

  test("saved form: every setting survives it; an older save (none) gets the defaults - Literata, dark, justified, "
      "no paragraph spacing (Default), slide; a size out of range gets the default", () {
    const changed = EpubPrefs(font: EpubFont.garamond, size: 24, lineSpacing: 1.75, margins: EpubMargins.wide,
        colours: EpubColours.sepia, align: EpubAlign.left, hyphenate: false,
        paragraphGap: EpubParagraphGap.book, twoPages: TwoPages.always,
        chapterStart: ChapterStart.rightPage);
    expect(EpubPrefs.fromJson(changed.toJson()), changed);
    expect(EpubPrefs.fromJson(changed.toJson()).twoPages, TwoPages.always, reason: 'dual page mode (2026-10-16)');
    expect(EpubPrefs.fromJson(const {}).twoPages, TwoPages.wideScreen, reason: 'saved before it: Wide screen');
    expect(EpubPrefs.fromJson(changed.toJson()).chapterStart, ChapterStart.rightPage, reason: 'chapters (2026-10-18)');
    expect(EpubPrefs.fromJson(const {}).chapterStart, ChapterStart.nextPage, reason: 'saved before it: the next page');
    final d = EpubPrefs.fromJson(const {});
    expect((d.font, d.colours, d.align, d.paragraphGap, d.hyphenate, d.size), (EpubFont.literata,
        EpubColours.dark, EpubAlign.justified, EpubParagraphGap.none, true, 19.0));
    // the page turn: this device's since 2026-10-21 (it was synced here): a save of it is left alone
    expect(EpubPrefs.fromJson(const {'turn': 'curl'}), const EpubPrefs());
    expect(DisplayPrefs.fromJson(const {'epubTurn': 'curl'}).epubTurn, EpubTurn.curl);
    expect(const DisplayPrefs().epubTurn, EpubTurn.slide);
    expect(EpubPrefs.fromJson(const {'size': 400}).size, 19);
    // the old "Book's formatting" switch isn't migrated (user, 2026-10-07): ignored, the defaults
    final was = EpubPrefs.fromJson(const {'bookFormatting': true});
    expect(was.align, EpubAlign.justified);
  });

  test("margins: on a wide screen the setting still shows - lines stop at its length (Narrow longest, Wide "
      "shortest) and the rest goes to the margins; on a narrow one it's the setting's own margin (user: the margin "
      "setting didn't seem to do anything)", () {
    double side(EpubMargins m, double w) => EpubRenderer.sideMargin(EpubPrefs(margins: m), w);
    for (final w in [360.0, 800.0, 1280.0, 2000.0]) {
      for (var i = 1; i < EpubMargins.values.length; i++) {
        final (a, b) = (EpubMargins.values[i - 1], EpubMargins.values[i]);
        expect(side(a, w), lessThan(side(b, w)), reason: '${a.name} < ${b.name} at $w');
      }
    }
    expect(side(EpubMargins.wide, 360), 360 * EpubMargins.wide.share, reason: 'a phone: the setting\'s share');
  });

  test('wider margins than before (user, 2026-10-08): on the tablet in portrait (800 wide, size 19), Wider leaves '
      'a fifth of the width each side, against 17% for Wide (Widest went - 2026-10-21)', () {
    double side(EpubMargins m) => EpubRenderer.sideMargin(EpubPrefs(margins: m), 800);
    expect(side(EpubMargins.wide) / 800, closeTo(0.17, 0.01));
    expect(side(EpubMargins.wider) / 800, greaterThanOrEqualTo(0.2));
  });

  test('Inset page from the screen (user, 2026-10-22: "the inset page height should be based on screen height (not '
      'quite full height) and the width should be based on the height (use a common physical book ratio)"): 24 short '
      'of the height above and below, 2:3 wide, centred; a screen too narrow keeps the height and narrows it; two '
      'pages up the pair and the gutter fit together; Never: none; Wide screen: only wider than tall', () {
    const wide = Size(1600, 1000), tall = Size(800, 1200);
    // one page on a wide screen: 952 tall, 2:3 -> 634.7 wide, centred
    final one = EpubRenderer.sheetRect(wide, wide, InsetPage.always)!;
    expect(one.top, 24);
    expect(one.height, 952);
    expect(one.width, closeTo(952 * 2 / 3, 0.01), reason: '2:3');
    expect(one.center.dx, closeTo(800, 0.01), reason: 'centred');
    expect(EpubRenderer.sheetRect(wide, wide, InsetPage.wideScreen), one, reason: 'wider than tall');
    expect(EpubRenderer.sheetRect(tall, tall, InsetPage.wideScreen), isNull, reason: 'taller than wide');
    expect(EpubRenderer.sheetRect(wide, wide, InsetPage.never), isNull);
    // a tall screen, Always: 1152 tall would be 768 wide - more than 800 less the gaps: the height kept, narrowed
    final upright = EpubRenderer.sheetRect(tall, tall, InsetPage.always)!;
    expect((upright.top, upright.height), (24, 1152), reason: 'the height kept');
    expect(upright.width, 800 - 48, reason: 'narrowed to the screen, 24 at the sides');
    // two pages up on 1600 x 1000, a gutter of 24: each half's sheet 2:3 (634.7 x 2 + 24 fits in 1600 - 48)
    final half = EpubRenderer.sheetRect(const Size(800, 1000), wide, InsetPage.always, dual: true, gutter: 24)!;
    expect(half.width, closeTo(952 * 2 / 3, 0.01));
    // ... and on 1200 x 1000 they don't: narrowed together - the pair, the gutter and the outer gaps fill the width
    final tight = EpubRenderer.sheetRect(const Size(600, 1000), const Size(1200, 1000), InsetPage.always, dual: true,
        gutter: 24)!;
    expect(2 * tight.width + 24 + 48, closeTo(1200, 0.01));
    expect(tight.height, 952, reason: 'the height kept');
  });

  test("inside an inset page the margin setting is the share of the sheet's width, no line-length cap (user, "
      '2026-10-22)', () {
    for (final m in EpubMargins.values.where((m) => m != EpubMargins.book)) {
      expect(EpubRenderer.sideMargin(EpubPrefs(margins: m), 635, inSheet: true), 635 * m.share, reason: m.name);
    }
    // the cap would have widened the margins on a wide sheet; inside one it doesn't
    expect(EpubRenderer.sideMargin(const EpubPrefs(margins: EpubMargins.narrow), 2000, inSheet: true),
        lessThan(EpubRenderer.sideMargin(const EpubPrefs(margins: EpubMargins.narrow), 2000)));
  });

  test('the surround: the dark grey page on black (user, 2026-10-16: "full black"); a light page on a shade darker; '
      'the black page on a shade lighter', () {
    expect(EpubRenderer.surround(EpubColours.dark.background), const Color(0xFF000000));
    for (final c in EpubColours.values) {
      final page = c.background, round = EpubRenderer.surround(page);
      expect((round.computeLuminance() - page.computeLuminance()).abs(), greaterThan(0.002), reason: c.name);
      if (c != EpubColours.black) expect(round.computeLuminance(), lessThan(page.computeLuminance()), reason: c.name);
    }
  });

  test('the margins setting leaves the top and bottom alone (user, 2026-10-08)', () {
    expect(EpubMargins.topBottom, 40);
  });

  test('line spacing: three steps (user, 2026-10-21: Tight, Normal, Loose); another spacing saved reads as Normal', () {
    expect(EpubPrefs.spacings, [1.25, 1.5, 1.75]);
    expect(nearestSpacing(1.7), 1.75);
    expect(EpubPrefs.fromJson(const {'lineSpacing': 1.45}).lineSpacing, 1.5, reason: 'not a step: Normal');
  });

  test("paragraph spacing: the book's, then None, Normal, Large (user, 2026-10-21); a saved choice keeps its spacing",
      () {
    expect([for (final g in EpubParagraphGap.values) g.ems], [null, 0, 0.5, 1.5]);
    expect(EpubPrefs.fromJson(const {'paragraphGap': 'small'}).paragraphGap.ems, 0.5);
    expect(EpubPrefs.fromJson(const {'paragraphGap': 'huge'}).paragraphGap.ems, 1.5);
  });

  testWidgets('font face (user, 2026-10-21: "show current, when tapped, give choice"): the current font in its own '
      'face; tapped, every font in its own face with a line of sample text, the current one marked; picked, it\'s '
      'set and the list closes', (tester) async {
    addTearDown(() => AppSettings.instance.setEpub(const EpubPrefs()));
    AppSettings.instance.setEpub(const EpubPrefs(font: EpubFont.literata));
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: Align(alignment: Alignment.topLeft, child: SizedBox(
        width: 460,
        child: ListenableBuilder(listenable: AppSettings.instance, builder: (c, _) => SingleChildScrollView(
            child: Column(children: epubPanelRows(c, AppSettings.instance)))))))));
    await tester.pump();
    Text shown(String label) => tester.widget<Text>(find.text(label).first);
    expect(shown('Literata').style!.fontFamily, 'Literata', reason: 'the current font, in its face');
    expect(find.text('Lora'), findsNothing, reason: 'the others not listed until asked');
    await tester.tap(find.byType(FontPicker));
    await tester.pumpAndSettle();
    for (final f in EpubFont.values) {
      final name = find.descendant(of: find.byType(PopupMenuItem<EpubFont>), matching: find.text(f.label));
      expect(name, findsOneWidget, reason: f.label);
      expect(tester.widget<Text>(name).style!.fontFamily, f.family, reason: '${f.label} in its own face');
    }
    expect(find.text('The quick brown fox'), findsNWidgets(EpubFont.values.length), reason: 'sample text');
    expect(find.descendant(of: find.byType(PopupMenuItem<EpubFont>), matching: find.byIcon(Icons.check)),
        findsOneWidget, reason: 'the current one marked');
    await tester.tap(find.descendant(of: find.byType(PopupMenuItem<EpubFont>), matching: find.text('Lora')));
    await tester.pumpAndSettle();
    expect(AppSettings.instance.epub.font, EpubFont.lora);
    expect(find.byType(PopupMenuItem<EpubFont>), findsNothing, reason: 'closed');
    expect(shown('Lora').style!.fontFamily, 'Lora');
  });

  Future<void> wait(WidgetTester tester, Duration d) async {
    for (var t = Duration.zero; t < d; t += const Duration(milliseconds: 250)) {
      await tester.runAsync(() => Future<void>.delayed(Duration.zero));
      await tester.pump(const Duration(milliseconds: 250));
    }
  }

  testWidgets("the text size is synced like the rest of the EPUB set (user, 2026-10-07 QA: one size again): Komga's "
      'copy brings it', (tester) async {
    final api = noNetwork(() => SettingsServer({
      AppSettings.komgaKey: jsonEncode({'v': 1, 'series': {},
          'epub': const EpubPrefs(size: 28, font: EpubFont.lora).toJson()}),
    }));
    SharedPreferences.setMockInitialValues({
      'readerPrefs': jsonEncode({'v': 1, 'series': {}, 'epub': const EpubPrefs(size: 16).toJson()}),
    });
    await tester.runAsync(() => AppSettings.instance.load(api));
    expect(AppSettings.instance.epub.font, EpubFont.lora, reason: "Komga's copy of the rest");
    expect(AppSettings.instance.epub.size, 28, reason: "Komga's size, not the device's 16");
  });

  testWidgets("synced: a change goes to Komga with the reading defaults (key 'epub'); Komga's copy arrives on load",
      (tester) async {
    final api = noNetwork(() => SettingsServer({
      AppSettings.komgaKey: jsonEncode({'v': 1, 'default': const ReaderPrefs().toJson(), 'series': {},
          'epub': const EpubPrefs(size: 24).toJson()}),
    }));
    await tester.runAsync(() => AppSettings.instance.load(api));
    expect(AppSettings.instance.epub.font, isNot(EpubFont.lora), reason: 'not set yet');
    expect(AppSettings.instance.epub.size, 24, reason: "Komga's copy, the size included");
    AppSettings.instance.setEpub(AppSettings.instance.epub.copyWith(font: EpubFont.lora));
    await wait(tester, const Duration(seconds: 3));
    final sent = jsonDecode(api.written[AppSettings.komgaKey]!) as Map;
    expect(EpubPrefs.fromJson(Map<String, dynamic>.from(sent['epub'] as Map)).font, EpubFont.lora);
    expect(sent['default'], isNotNull, reason: 'the reading defaults stay');
  });

  testWidgets("the EPUBs' old page corner isn't taken over on load (user, 2026-10-07: no migrations), nor the kinds' "
      'own (2026-10-21: one for both) - the default, or the shared one', (tester) async {
    final api = noNetwork(() => SettingsServer({}));
    Future<PageNote> loaded(Map<String, dynamic> display) async {
      SharedPreferences.setMockInitialValues({
        'displayPrefs': jsonEncode(display),
        'readerPrefs': jsonEncode({'v': 1, 'series': {}, 'epub': {'corner': 'off'}}),
      });
      await tester.runAsync(() => AppSettings.instance.load(api, fetch: false));
      final d = AppSettings.instance.display;
      return d.pageNote;
    }

    expect(await loaded({'pageNumber': true}), PageNote.afterTurn, reason: 'the default');
    expect(await loaded({'comics': {'pageNote': 'always'}, 'ebooks': {'pageNote': 'off'}}), PageNote.afterTurn,
        reason: "the kinds' own: left unread");
    expect(await loaded({'pageNote': 'always'}), PageNote.always, reason: 'the shared one');
  });

  testWidgets("a change made while Komga can't be reached stays (Komga's older copy doesn't replace it) and goes "
      'once it can', (tester) async {
    final api = noNetwork(() => SettingsServer({
      AppSettings.komgaKey: jsonEncode({'v': 1, 'series': {}, 'epub': const EpubPrefs(size: 16).toJson()}),
    }));
    await tester.runAsync(() => AppSettings.instance.load(api));
    api.down = true;
    AppSettings.instance.setEpub(AppSettings.instance.epub.copyWith(colours: EpubColours.sepia));
    await wait(tester, const Duration(seconds: 3));
    api.down = false;
    // Home reloads: Komga's copy asked for again (on the test's clock, so the send it schedules runs here)
    unawaited(AppSettings.instance.load(api));
    await wait(tester, const Duration(milliseconds: 500));
    expect(AppSettings.instance.epub.colours, EpubColours.sepia, reason: "this device's unsent change stays");
    await wait(tester, const Duration(seconds: 3));
    final sent = jsonDecode(api.written[AppSettings.komgaKey]!) as Map;
    expect((sent['epub'] as Map)['colours'], 'sepia', reason: 'puts ${api.puts} gets ${api.gets} '
        'error ${AppSettings.instance.syncError}');
  });

  testWidgets('the reader follows the settings: a bigger size lays the book out again (more pages), the theme '
      'colours the page', (tester) async {
    tester.view.physicalSize = const Size(800, 1200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final MemorySource source = twoChapters();
    await tester.pumpWidget(MaterialApp(home: ReaderScreen(api: noNetwork(EmptySettingsKomga.new),
        book: const {'id': 'B1', 'name': 'Book', 'media': {'mediaProfile': 'EPUB'}}, epubSource: source, saveProgress: false)));
    Future<void> settle() async {
      for (var i = 0; i < 40; i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
        await tester.pump();
      }
    }
    Future<int> total() async {
      await tester.tapAt(const Offset(400, 600));
      await tester.pump();
      final t = tester.widgetList<Text>(find.byKey(const ValueKey('pos-left-text'))).single.data!;
      await tester.tapAt(const Offset(400, 600));
      await tester.pump();
      return int.parse(RegExp(r'/(\d+) ·').firstMatch(t)!.group(1)!);
    }
    await settle();
    final before = await total();
    AppSettings.instance.setEpub(AppSettings.instance.epub.copyWith(size: 28, colours: EpubColours.light));
    await tester.pump(); // the page drawn with the change: the pause starts
    await tester.pump(EpubRenderer.settleDelay); // laid out once the settings stop changing
    await settle();
    expect(await total(), greaterThan(before));
    expect(tester.widget<Scaffold>(find.byType(Scaffold)).backgroundColor, EpubColours.light.background);
    await tester.pumpWidget(const SizedBox()); // closed: the background counting stops
    for (var i = 0; i < 10; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 5)));
      await tester.pump(const Duration(milliseconds: 10));
    }
  });

  testWidgets('settings changed in quick succession lay the book out once, when they stop - not at every step (user, '
      '2026-10-07: the size up several steps); meanwhile the page stays as it was', (tester) async {
    tester.view.physicalSize = const Size(800, 1200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final store = EpubCountStore.instance as MemoryCountStore;
    await tester.pumpWidget(MaterialApp(home: ReaderScreen(api: noNetwork(EmptySettingsKomga.new),
        book: const {'id': 'B1', 'name': 'Book', 'media': {'mediaProfile': 'EPUB'}}, epubSource: twoChapters(),
        saveProgress: false)));
    Future<void> settle() async {
      for (var i = 0; i < 40; i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
        await tester.pump();
      }
    }
    await settle();
    expect(find.byType(PageView), findsOneWidget, reason: 'open');
    final before = store.loads;
    final s = AppSettings.instance;
    for (final size in [20.0, 22.0, 24.0, 26.0]) { // four steps up, each well inside the pause
      s.setEpub(s.epub.copyWith(size: size));
      await tester.pump(EpubRenderer.settleDelay ~/ 4);
      await settle();
    }
    expect(store.loads, before, reason: 'not laid out while the size was still changing');
    expect(find.byType(PageView), findsOneWidget, reason: 'the page stays meanwhile');
    await tester.pump(EpubRenderer.settleDelay);
    await settle();
    expect(store.loads, before + 1, reason: 'one layout, for the last size');
    expect(find.byType(PageView), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    for (var i = 0; i < 10; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 5)));
      await tester.pump(const Duration(milliseconds: 10));
    }
  });
}
