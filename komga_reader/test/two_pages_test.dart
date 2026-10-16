// Comics in two pages side by side (user, 2026-10-16 - NOTES, "Dual-page mode"; the pairing: spreads_test.dart).
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:komga_reader/page_curl.dart';
import 'package:komga_reader/page_image.dart';
import 'package:komga_reader/reader/comic_renderer.dart';
import 'package:komga_reader/screens/reader.dart';
import 'package:komga_reader/settings.dart';
import 'package:komga_reader/synced_ids.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/helpers.dart';
import 'support/no_network.dart';
import 'support/reader_server.dart';

/// A 9-page book whose 7th page is a spread: the cover, 1|2, 3|4, 5 alone (an odd run before the spread, anchored),
/// the spread, 7|8 - as pages from 1: [1] [2|3] [4|5] ... see [expectedSpreads].
class SpreadBook extends ReaderServer {
  // (from 1) 1 cover, 2-6 single (five: odd - one alone after the cover), 7 wide, 8-9
  static const wide = {7};
  @override
  Future<List<dynamic>> pages(String bookId) async => [
        for (var n = 1; n <= 9; n++) {'number': n, 'width': wide.contains(n) ? 2400 : 1200, 'height': 1800},
      ];
}

void main() {
  setUpAll(preloadShaders);
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    ComicRenderer.twoPagesAllowed = true; // (off for every other test file - flutter_test_config.dart)
    PairShift.instance.reset();
  });
  tearDown(() {
    ComicRenderer.twoPagesAllowed = false;
    AppSettings.instance.setDisplay(const DisplayPrefs());
    ReaderServer.direction = 'LEFT_TO_RIGHT';
  });

  late SpreadBook api;

  Future<void> open(WidgetTester tester, {Size size = const Size(1600, 1000)}) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    api = noNetwork(SpreadBook.new);
    await tester.pumpWidget(const SizedBox()); // (a reader opened before in the test: gone, not reused)
    await tester.pumpWidget(MaterialApp(home: ReaderScreen(api: api, book: api.theBook)));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
  }

  /// The position text with the controls up ("Pg. 2-3/9 · 33%"), the controls hidden again after.
  Future<String> position(WidgetTester tester) async {
    await tester.sendKeyEvent(LogicalKeyboardKey.enter); // OK: the controls
    await tester.pump();
    final t = tester.widgetList<Text>(find.textContaining('Pg. ')).single.data!;
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    return t;
  }

  Future<void> turn(WidgetTester tester, {bool back = false}) async {
    await tester.sendKeyEvent(back ? LogicalKeyboardKey.arrowLeft : LogicalKeyboardKey.arrowRight);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
  }

  testWidgets('a wide screen: two pages side by side - the cover alone, then pairs anchored on the spread, the spread '
      'alone; a turn goes a pair on; progress is the later page shown, so the last pair finishes the book',
      (tester) async {
    await open(tester);
    expect(await position(tester), startsWith('Pg. 1/9'), reason: 'the cover alone');
    final seen = <String>[];
    for (var i = 0; i < 5; i++) {
      await turn(tester);
      seen.add((await position(tester)).split(' ·').first);
    }
    // 2 alone (the dropped inside cover), 3|4, 5|6 meeting the spread, the spread, 8|9
    expect(seen, ['Pg. 2/9', 'Pg. 3-4/9', 'Pg. 5-6/9', 'Pg. 7/9', 'Pg. 8-9/9']);
    expect(api.saves.last, 9, reason: 'the later page of the pair');
    expect(api.finished, isNotEmpty, reason: 'the last pair shown: read to the end');
    await turn(tester, back: true);
    expect((await position(tester)).split(' ·').first, 'Pg. 7/9', reason: 'back a spread');
  });

  testWidgets('a tall screen (Wide screen, the default): one page at a time; Always: two there too; Off: one on a wide '
      'screen too', (tester) async {
    await open(tester, size: const Size(1000, 1600));
    await turn(tester);
    expect(await position(tester), startsWith('Pg. 2/9'));
    await turn(tester);
    expect(await position(tester), startsWith('Pg. 3/9'), reason: 'page by page');

    final s = AppSettings.instance;
    s.setDisplay(s.display.withKind(BookKind.comics, s.display.comics.copyWith(twoPages: TwoPages.always)));
    await tester.pump();
    await tester.pump();
    expect(await position(tester), startsWith('Pg. 3-4/9'), reason: 'Always: the pair page 3 is in');

    await open(tester);
    s.setDisplay(s.display.withKind(BookKind.comics, s.display.comics.copyWith(twoPages: TwoPages.off)));
    await tester.pump();
    await tester.pump();
    await turn(tester);
    expect(await position(tester), startsWith('Pg. 2/9'));
    await turn(tester);
    expect(await position(tester), startsWith('Pg. 3/9'), reason: 'Off: page by page on a wide screen');
  });

  testWidgets('turned from wide to tall mid-book: the same page, now alone; and back: its pair', (tester) async {
    await open(tester);
    await turn(tester);
    await turn(tester); // 3|4
    expect(await position(tester), startsWith('Pg. 3-4/9'));
    tester.view.physicalSize = const Size(1000, 1600);
    await tester.pump();
    await tester.pump();
    expect(await position(tester), startsWith('Pg. 4/9'), reason: 'the later page of the pair, the page being read');
    tester.view.physicalSize = const Size(1600, 1000);
    await tester.pump();
    await tester.pump();
    expect(await position(tester), startsWith('Pg. 3-4/9'));
  });

  testWidgets('"Shift pairing by one" on the bottom bar (two pages up only): the pages before the spread pair the other '
      'way, kept for this book - and pairing after the spread stays', (tester) async {
    await open(tester);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    await tester.tap(find.byTooltip('Shift pairing by one'));
    await tester.pump();
    await tester.pump();
    expect(PairShift.instance.shifted('B1'), isTrue);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    final seen = <String>[];
    for (var i = 0; i < 5; i++) {
      await turn(tester);
      seen.add((await position(tester)).split(' ·').first);
    }
    expect(seen, ['Pg. 2-3/9', 'Pg. 4-5/9', 'Pg. 6/9', 'Pg. 7/9', 'Pg. 8-9/9']);

    await open(tester, size: const Size(1000, 1600));
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    expect(find.byTooltip('Shift pairing by one'), findsNothing, reason: 'one page at a time: nothing to shift');
  });

  testWidgets('Save page with a pair up asks which: the left, the right, or both; right to left, the earlier page is '
      'on the right', (tester) async {
    await open(tester);
    await turn(tester);
    await turn(tester); // 3|4
    Future<List<String>> choices() async {
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();
      // (no settling: the pages never load, their spinners turn for good)
      Future<void> frames() async {
        for (var i = 0; i < 8; i++) {
          await tester.pump(const Duration(milliseconds: 100));
        }
      }

      await tester.tap(find.byTooltip('Comic settings'));
      await frames();
      await tester.ensureVisible(find.text('Save page'));
      await tester.tap(find.text('Save page'));
      await frames();
      final options = [
        for (final o in tester.widgetList<SimpleDialogOption>(find.byType(SimpleDialogOption)))
          ((o.child as Text).data!),
      ];
      Navigator.of(tester.element(find.text('Which page?'))).pop(); // (nothing picked: nothing saved)
      for (var i = 0; i < 8; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      return options;
    }

    expect(await choices(), ['Left (page 3)', 'Right (page 4)', 'Both, as one picture']);
    ReaderServer.direction = 'RIGHT_TO_LEFT';
    await open(tester);
    await turn(tester, back: true); // (right to left: Left is forward)
    await turn(tester, back: true);
    expect(await choices(), ['Left (page 4)', 'Right (page 3)', 'Both, as one picture']);
  });

  test('two pages joined: the shorter scaled to the taller one\'s height, side by side, edge to edge', () async {
    Future<ui.Image> image(int w, int h) {
      final rec = ui.PictureRecorder();
      Canvas(rec).drawRect(Rect.fromLTWH(0, 0, w.toDouble(), h.toDouble()), Paint()..color = const Color(0xFF808080));
      return rec.endRecording().toImage(w, h);
    }

    final joined = await joinPages([await image(100, 150), await image(200, 300)]);
    expect((joined.width, joined.height), (400, 300), reason: '100 x 150 at 300 high is 200 wide, then 200');
  });
}
