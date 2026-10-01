import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:komga_reader/page_image.dart';
import 'package:komga_reader/settings.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/helpers.dart';
import 'support/no_network.dart';

/// Opening a book with Enhance colours: the page waits (spinner) instead of flashing uncorrected; the book's levels
/// are measured from five pages at once and remembered, so the next open has nothing to fetch.
class PagesKomga extends TestKomga {
  PagesKomga(this.png);
  final Uint8List png;
  int fetches = 0, inFlight = 0, maxInFlight = 0;
  @override
  Future<Uint8List> pageBytes(String bookId, int number) async {
    fetches++;
    inFlight++;
    if (inFlight > maxInFlight) maxInFlight = inFlight;
    await Future<void>.delayed(const Duration(milliseconds: 5));
    inFlight--;
    return png;
  }
}

Future<Uint8List> greyPng() async => pngBytes(await paintedImage(40, 60, (canvas) => canvas
  ..drawRect(const Rect.fromLTWH(0, 0, 40, 60), Paint()..color = const Color(0xFFD8C8A8)) // cream
  ..drawRect(const Rect.fromLTWH(0, 0, 10, 60), Paint()..color = const Color(0xFF302818)))); // ink

/// Real work (decoding, the GPU passes) finishes in real time: lets it run in short steps until [done], up to about
/// 2 s, rather than one fixed wait that a slow machine can outlast (test audit, 2026-09-30) - and fails if it never
/// happens.
Future<void> until(WidgetTester tester, bool Function() done, String reason) =>
    waitUntil(done, tester: tester, step: const Duration(milliseconds: 50), reason: reason);

void main() {
  // Enhance colours loads its shaders once and keeps that future: load them for real first, or the load belongs to
  // the first test that colours a page, and the tests after it wait on that test's fake clock forever (test audit,
  // 2026-09-30 - found when the Enhance colours test started letting its page finish)
  setUpAll(preloadShaders);
  setUp(() => SharedPreferences.setMockInitialValues({}));

  // moved from reader_test: page_image's tone and levels, no reader needed (test audit, 2026-09-30)
  test('tone: neutral prefs are identity; levels stretch lo..hi to 0..1', () {
    expect(Tone.of(const ReaderPrefs(), Levels.identity).isIdentity, isTrue);
    final t = Tone.of(const ReaderPrefs(), const Levels([0.1, 0.1, 0.2], [0.9, 0.9, 0.8]));
    for (var c = 0; c < 3; c++) {
      final lo = [0.1, 0.1, 0.2][c], hi = [0.9, 0.9, 0.8][c];
      expect(lo * t.scale[c] + t.offset[c], closeTo(0, 1e-9));
      expect(hi * t.scale[c] + t.offset[c], closeTo(1, 1e-9));
    }
  });

  test('book auto-levels take the median page', () {
    final l = Levels.combine([
      const Levels([0.1, 0.1, 0.1], [0.9, 0.9, 0.9]),
      const Levels([0.2, 0.2, 0.2], [0.8, 0.8, 0.8]),
      const Levels([0.5, 0.5, 0.5], [0.95, 0.95, 0.95]), // an odd page doesn't drag the book
    ]);
    expect(l.lo, [0.2, 0.2, 0.2]);
    expect(l.hi, [0.9, 0.9, 0.9]);
  });

  testWidgets('book levels: five pages fetched together, then remembered for the next open', (tester) async {
    await tester.runAsync(() async {
      final png = await greyPng();
      final api = noNetwork(() => PagesKomga(png));
      final first = await PageLoader(api, 'B1', List.generate(20, (i) => i + 1)).bookLevels();
      expect(api.fetches, 5);
      expect(api.maxInFlight, greaterThan(1)); // in parallel, not one after another
      final again = await PageLoader(api, 'B1', List.generate(20, (i) => i + 1)).bookLevels(); // reopened
      expect(api.fetches, 5); // nothing fetched
      expect(again.lo, first.lo);
      expect(again.hi, first.hi);
    });
  });

  testWidgets('Crop edges: 5% off every side, and the cropped page is what gets drawn', (tester) async {
    late ui.Image img;
    await tester.runAsync(() async {
      img = await paintedImage(200, 300, (canvas) => canvas
        ..drawRect(const Rect.fromLTWH(0, 0, 200, 300), Paint()..color = const Color(0xFFFFFFFF)) // margin
        ..drawRect(const Rect.fromLTWH(10, 15, 180, 270), Paint()..color = const Color(0xFF204060))); // the art
      final cut = await cropEdges(img, 0.05);
      expect((cut.width, cut.height), (180, 270));
      final d = (await cut.toByteData(format: ui.ImageByteFormat.rawRgba))!;
      expect(d.getUint8(0), 0x20); // the top-left corner is now art, not margin
    });
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: PageCanvas(
      data: PageData(img, Uint8List(0)),
      prefs: const ReaderPrefs(crop: 0.05),
      scroll: ScrollController(),
    ))));
    expect(find.byType(RawImage), findsNothing); // waits for the crop, never shows the margin
    await until(tester, () => shows(find.byType(RawImage)), 'the cropped page');
    final shown = tester.widget<RawImage>(find.byType(RawImage)).image!;
    expect((shown.width, shown.height), (180, 270));
  });

  testWidgets('Enhance colours on: the page waits for its colours instead of showing uncorrected', (tester) async {
    final img = await testImage(tester, 40, 60, const Color(0xFFD8C8A8));
    final levels = Completer<Levels>(); // the book's measurement, still running
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: PageCanvas(
      data: PageData(img, Uint8List(0)),
      prefs: const ReaderPrefs(autoLevels: true),
      scroll: ScrollController(),
      levels: () => levels.future,
    ))));
    await tester.pump();
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(find.byType(RawImage), findsNothing); // not the uncorrected page
    // test audit, 2026-09-30: and once the colours are in, the page shows (it used to stop at the spinner)
    levels.complete(Levels.identity);
    await until(tester, () => shows(find.byType(RawImage)), 'the coloured page');
    expect(find.byType(RawImage), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsNothing);
  });

  testWidgets('a page off screen waits for the page turn to finish before its colours are made', (tester) async {
    // the hitch: the page after next was processed on the GPU during the curl / wipe (user, 2026-09-29)
    final img = await testImage(tester, 40, 60, const Color(0xFFD8C8A8));
    final turn = Completer<void>(); // a page turn playing
    var asked = 0;
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: PageCanvas(
      data: PageData(img, Uint8List(0)),
      prefs: const ReaderPrefs(autoLevels: true),
      scroll: ScrollController(),
      levels: () async => Levels.identity,
      idle: () { asked++; return turn.future; },
    ))));
    // a fixed wait on purpose: it gives processing that ignored the turn the time to show up; a slow machine can
    // only make it pass more easily, never fail (test audit, 2026-09-30)
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 300)));
    await tester.pump();
    expect(asked, 1);
    expect(find.byType(RawImage), findsNothing); // still waiting: nothing processed mid-turn
    turn.complete(); // the turn is over
    await until(tester, () => shows(find.byType(RawImage)), 'the page, once the turn is over');
    expect(find.byType(RawImage), findsOneWidget); // processed now
  });
}
