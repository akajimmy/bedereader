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
    const changed = EpubPrefs(font: EpubFont.garamond, size: 24, lineSpacing: 1.7, margins: EpubMargins.wide,
        colours: EpubColours.sepia, align: EpubAlign.left, hyphenate: false,
        turn: EpubTurn.none, paragraphGap: EpubParagraphGap.book);
    expect(EpubPrefs.fromJson(changed.toJson()), changed);
    final d = EpubPrefs.fromJson(const {});
    expect((d.font, d.colours, d.align, d.paragraphGap, d.hyphenate, d.turn, d.size), (EpubFont.literata,
        EpubColours.dark, EpubAlign.justified, EpubParagraphGap.none, true, EpubTurn.slide, 19.0));
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

  test('wider margins than before (user, 2026-10-08): on the tablet in portrait (800 wide, size 19), Widest leaves '
      'a quarter of the width each side, against 17% for Wide', () {
    double side(EpubMargins m) => EpubRenderer.sideMargin(EpubPrefs(margins: m), 800);
    expect(side(EpubMargins.wide) / 800, closeTo(0.17, 0.01));
    expect(side(EpubMargins.widest) / 800, greaterThanOrEqualTo(0.25));
  });

  test('a wide screen shows the page as a sheet (user, 2026-10-11): the text column with the margins a page that wide '
      'would have, centred, full height; none where the page fills the screen; the surround a shade off the page',
      () {
    expect(EpubRenderer.sheetRect(const EpubPrefs(margins: EpubMargins.book), const Size(1920, 1080)), isNull,
        reason: "Margins: Book's - the book's own margins, as a browser: no sheet");
    for (final m in EpubMargins.values.where((m) => m != EpubMargins.book)) {
      final e = EpubPrefs(margins: m, size: 24);
      const wide = Size(1920, 1080);
      final s = EpubRenderer.sheetRect(e, wide)!;
      expect(s.center.dx, closeTo(wide.width / 2, 0.01), reason: '${m.name}: centred');
      expect(s.height, wide.height);
      // the text sits in the sheet as on a page just that wide
      expect(EpubRenderer.sideMargin(e, wide.width) - s.left, closeTo(EpubRenderer.sideMargin(e, s.width), 0.01),
          reason: '${m.name}: the margins inside the sheet');
      expect(EpubRenderer.sheetRect(e, Size(s.width + 10, 1080)), isNull, reason: '${m.name}: no room, no sheet');
    }
    expect(EpubRenderer.sheetRect(const EpubPrefs(margins: EpubMargins.wide, size: 24), const Size(800, 1230)), isNull,
        reason: 'the tablet in portrait: the page fills the screen');
    for (final c in EpubColours.values) {
      final page = c.background, round = EpubRenderer.surround(page);
      expect((round.computeLuminance() - page.computeLuminance()).abs(), greaterThan(0.002), reason: c.name);
      if (c != EpubColours.black) expect(round.computeLuminance(), lessThan(page.computeLuminance()), reason: c.name);
    }
  });

  test('the margins setting leaves the top and bottom alone (user, 2026-10-08)', () {
    expect(EpubMargins.topBottom, 40);
  });

  test('line spacing: five steps, 1 to 2; a spacing saved before them shows as the nearest step', () {
    expect(EpubPrefs.spacings, [1.0, 1.25, 1.5, 1.75, 2.0]);
    expect(nearestSpacing(1.45), 1.5);
    expect(nearestSpacing(1.7), 1.75);
    expect(EpubPrefs.fromJson(const {'lineSpacing': 1.45}).lineSpacing, 1.45, reason: 'kept as saved');
  });

  test("paragraph spacing: the book's, then five steps (user, 2026-10-11); a saved choice keeps its spacing", () {
    expect([for (final g in EpubParagraphGap.values) g.ems], [null, 0, 0.25, 0.5, 1, 1.5]);
    expect(EpubPrefs.fromJson(const {'paragraphGap': 'small'}).paragraphGap.ems, 0.5);
    expect(EpubPrefs.fromJson(const {'paragraphGap': 'large'}).paragraphGap.ems, 1);
  });

  testWidgets("the font choices keep their size in the reader's side sheet (380 wide): they wrap under the label, "
      'not shrunk to fit beside it (user: shrunk until they could not be read)', (tester) async {
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: Align(alignment: Alignment.topLeft, child: SizedBox(
        width: 380,
        child: Builder(builder: (c) => SingleChildScrollView(
            child: Column(children: epubPanelRows(c, AppSettings.instance)))))))));
    await tester.pump();
    for (final f in EpubFont.values) {
      // on screen (getRect takes in any scaling round it; getSize wouldn't)
      expect(tester.getRect(find.widgetWithText(ChoiceChip, f.label)).height, greaterThanOrEqualTo(30),
          reason: '${f.label}: full size');
    }
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

  testWidgets("the EPUBs' old page corner isn't taken over on load (user, 2026-10-07: no migrations) - each kind "
      'keeps its own, or its default', (tester) async {
    final api = noNetwork(() => SettingsServer({}));
    Future<(PageNote, PageNote)> loaded(Map<String, dynamic> display) async {
      SharedPreferences.setMockInitialValues({
        'displayPrefs': jsonEncode(display),
        'readerPrefs': jsonEncode({'v': 1, 'series': {}, 'epub': {'corner': 'off'}}),
      });
      await tester.runAsync(() => AppSettings.instance.load(api, fetch: false));
      final d = AppSettings.instance.display;
      return (d.comics.pageNote, d.ebooks.pageNote);
    }

    expect(await loaded({'pageNumber': true}), (PageNote.afterTurn, PageNote.always), reason: 'the defaults');
    expect(await loaded({'comics': {'pageNote': 'always'}, 'ebooks': {'pageNote': 'afterTurn'}}),
        (PageNote.always, PageNote.afterTurn), reason: "each kind's own");
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
