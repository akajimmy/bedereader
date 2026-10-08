// The EPUB settings (EpubPrefs): saved form, synced through Komga's client settings with the reading defaults, the
// reader and Settings > Books using them.
import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:komga_reader/reader/epub_renderer.dart';
import 'package:komga_reader/screens/reader.dart';
import 'package:komga_reader/settings.dart';
import 'package:komga_reader/widgets/epub_settings.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/epub_books.dart' show MemorySource, twoChapters;
import 'support/client_settings.dart';
import 'support/no_network.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    AppSettings.instance.setDisplay(const DisplayPrefs());
  });
  tearDown(() => AppSettings.instance.clearAccount());

  test('saved form: every setting survives it; an older save (none) gets the defaults - Literata, dark, my own '
      'formatting, slide; a size out of range gets the default', () {
    const changed = EpubPrefs(font: EpubFont.garamond, size: 24, lineSpacing: 1.7, margins: EpubMargins.wide,
        colours: EpubColours.sepia, align: EpubAlign.left, paragraphs: EpubParagraphs.book, hyphenate: false,
        turn: EpubTurn.none, paragraphGap: EpubParagraphGap.large);
    expect(EpubPrefs.fromJson(changed.toJson()), changed);
    final d = EpubPrefs.fromJson(const {});
    expect((d.font, d.colours, d.align, d.paragraphs, d.hyphenate, d.turn, d.size), (EpubFont.literata,
        EpubColours.dark, EpubAlign.justified, EpubParagraphs.mine, true, EpubTurn.slide, 19.0));
    expect(EpubPrefs.fromJson(const {'size': 400}).size, 19);
    // the old "Book's formatting" switch isn't migrated (user, 2026-10-07): ignored, the defaults
    final was = EpubPrefs.fromJson(const {'bookFormatting': true});
    expect((was.align, was.paragraphs), (EpubAlign.justified, EpubParagraphs.mine));
  });

  test("margins: on a wide screen the setting still shows - lines stop at its length (Narrow longest, Wide "
      "shortest) and the rest goes to the margins; on a narrow one it's the setting's own margin (user: the margin "
      "setting didn't seem to do anything)", () {
    double side(EpubMargins m, double w) => EpubRenderer.sideMargin(EpubPrefs(margins: m), w);
    for (final w in [800.0, 1200.0, 2000.0]) {
      expect(side(EpubMargins.narrow, w), lessThan(side(EpubMargins.normal, w)), reason: 'at $w');
      expect(side(EpubMargins.normal, w), lessThan(side(EpubMargins.wide, w)), reason: 'at $w');
    }
    expect(side(EpubMargins.wide, 360), EpubMargins.wide.side, reason: 'a phone: the margin itself');
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

  testWidgets("the text size is this device's (user, 2026-10-07): Komga's copy of the EPUB set brings the rest, not "
      'the size', (tester) async {
    final api = noNetwork(() => SettingsServer({
      AppSettings.komgaKey: jsonEncode({'v': 1, 'series': {},
          'epub': const EpubPrefs(size: 28, font: EpubFont.lora).toJson()}),
    }));
    SharedPreferences.setMockInitialValues({
      'readerPrefs': jsonEncode({'v': 1, 'series': {}, 'epub': const EpubPrefs(size: 16).toJson()}),
    });
    await tester.runAsync(() => AppSettings.instance.load(api));
    expect(AppSettings.instance.epub.font, EpubFont.lora, reason: "Komga's copy of the rest");
    expect(AppSettings.instance.epub.size, 16, reason: "this device's size, not Komga's 28");
  });

  testWidgets("synced: a change goes to Komga with the reading defaults (key 'epub'); Komga's copy arrives on load",
      (tester) async {
    final api = noNetwork(() => SettingsServer({
      AppSettings.komgaKey: jsonEncode({'v': 1, 'default': const ReaderPrefs().toJson(), 'series': {},
          'epub': const EpubPrefs(size: 24).toJson()}),
    }));
    await tester.runAsync(() => AppSettings.instance.load(api));
    expect(AppSettings.instance.epub.font, isNot(EpubFont.lora), reason: 'not set yet');
    expect(AppSettings.instance.epub.size, 19, reason: "the size is this device's, not Komga's 24");
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
    await tester.pumpWidget(MaterialApp(home: ReaderScreen(api: plainKomga(),
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
    await settle();
    expect(await total(), greaterThan(before));
    expect(tester.widget<Scaffold>(find.byType(Scaffold)).backgroundColor, EpubColours.light.background);
    await tester.pumpWidget(const SizedBox()); // closed: the background counting stops
    for (var i = 0; i < 10; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 5)));
      await tester.pump(const Duration(milliseconds: 10));
    }
  });
}
