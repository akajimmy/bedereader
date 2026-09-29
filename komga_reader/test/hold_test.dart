import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:komga_reader/api.dart';
import 'package:komga_reader/page_image.dart';
import 'package:komga_reader/settings.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Opening a book with Enhance colours: the page waits (spinner) instead of flashing uncorrected; the book's levels
/// are measured from five pages at once and remembered, so the next open has nothing to fetch.
class PagesKomga extends Komga {
  PagesKomga(this.png) : super('http://test', 'k');
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

Future<Uint8List> greyPng() async {
  final rec = ui.PictureRecorder();
  Canvas(rec)
    ..drawRect(const Rect.fromLTWH(0, 0, 40, 60), Paint()..color = const Color(0xFFD8C8A8)) // cream
    ..drawRect(const Rect.fromLTWH(0, 0, 10, 60), Paint()..color = const Color(0xFF302818)); // ink
  final img = await rec.endRecording().toImage(40, 60);
  return (await img.toByteData(format: ui.ImageByteFormat.png))!.buffer.asUint8List();
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('book levels: five pages fetched together, then remembered for the next open', (tester) async {
    await tester.runAsync(() async {
      final api = PagesKomga(await greyPng());
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
      final rec = ui.PictureRecorder();
      Canvas(rec)
        ..drawRect(const Rect.fromLTWH(0, 0, 200, 300), Paint()..color = const Color(0xFFFFFFFF)) // margin
        ..drawRect(const Rect.fromLTWH(10, 15, 180, 270), Paint()..color = const Color(0xFF204060)); // the art
      img = await rec.endRecording().toImage(200, 300);
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
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 200)));
    await tester.pump();
    final shown = tester.widget<RawImage>(find.byType(RawImage)).image!;
    expect((shown.width, shown.height), (180, 270));
  });

  testWidgets('Enhance colours on: the page waits for its colours instead of showing uncorrected', (tester) async {
    late ui.Image img;
    await tester.runAsync(() async {
      final rec = ui.PictureRecorder();
      Canvas(rec).drawRect(const Rect.fromLTWH(0, 0, 40, 60), Paint()..color = const Color(0xFFD8C8A8));
      img = await rec.endRecording().toImage(40, 60);
    });
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
  });

  testWidgets('a page off screen waits for the page turn to finish before its colours are made', (tester) async {
    // the hitch: the page after next was processed on the GPU during the curl / wipe (user, 2026-09-29)
    late ui.Image img;
    await tester.runAsync(() async {
      final rec = ui.PictureRecorder();
      Canvas(rec).drawRect(const Rect.fromLTWH(0, 0, 40, 60), Paint()..color = const Color(0xFFD8C8A8));
      img = await rec.endRecording().toImage(40, 60);
    });
    final turn = Completer<void>(); // a page turn playing
    var asked = 0;
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: PageCanvas(
      data: PageData(img, Uint8List(0)),
      prefs: const ReaderPrefs(autoLevels: true),
      scroll: ScrollController(),
      levels: () async => Levels.identity,
      idle: () { asked++; return turn.future; },
    ))));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 300)));
    await tester.pump();
    expect(asked, 1);
    expect(find.byType(RawImage), findsNothing); // still waiting: nothing processed mid-turn
    turn.complete(); // the turn is over
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 300)));
    await tester.pump();
    expect(find.byType(RawImage), findsOneWidget); // processed now
  });
}
