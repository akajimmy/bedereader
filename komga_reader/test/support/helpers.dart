import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:komga_reader/enhance.dart';
import 'package:komga_reader/page_curl.dart';

/// Deletes a test's temp folder after it. Windows can hold a file just written for a moment (a virus scanner,
/// the indexer): "being used by another process" failed a passing test in its tear-down (2026-10-02). So it tries
/// again for a while, and if the folder still can't go, says so and leaves it rather than failing the test.
Future<void> deleteTemp(Directory dir) async {
  for (var i = 0; ; i++) {
    try {
      if (await dir.exists()) await dir.delete(recursive: true);
      return;
    } on FileSystemException catch (e) {
      if (i >= 20) {
        // ignore: avoid_print
        print('left behind (still in use): ${dir.path} - $e');
        return;
      }
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
  }
}

/// Sets the test window to [size] logical pixels (device pixel ratio 1), put back when the test ends.
void setView(WidgetTester tester, Size size) {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
}

/// Waits on the real clock, in [step]s, until [done] - and FAILS the test (naming [reason]) if it hasn't happened
/// after [timeout] worth of steps. With a [tester], each step runs in `runAsync` and pumps after it (real work -
/// decoding, files - finishes in real time, and what it starts only moves on when pumped); without one, for plain
/// `test`s, it just waits.
///
/// The cap counts steps, not the wall clock: the time spent pumping between them comes on top, so a machine busy
/// running the other test files gets the same number of looks (a wall-clock cap made a downloads test flaky).
///
/// The local versions it replaces returned quietly on timeout, so the next expectation failed for the wrong reason,
/// or not at all (test audit, 2026-09-30).
Future<void> waitUntil(bool Function() done, {WidgetTester? tester, Duration timeout = const Duration(seconds: 2),
    Duration step = const Duration(milliseconds: 20), String? reason}) async {
  final steps = timeout.inMicroseconds ~/ step.inMicroseconds;
  for (var i = 0; !done(); i++) {
    if (i >= steps) fail('waited ${timeout.inMilliseconds} ms ($steps looks) for ${reason ?? 'a condition'}');
    if (tester == null) {
      await Future<void>.delayed(step);
    } else {
      await tester.runAsync(() => Future<void>.delayed(step));
      await tester.pump();
    }
  }
}

/// Whether [finder] finds anything now (for [waitUntil] conditions).
bool shows(Finder finder) => finder.evaluate().isNotEmpty;

/// One page of a Komga listing, all of it.
Map<String, dynamic> onePage(List<Map<String, dynamic>> items) =>
    {'content': items, 'totalElements': items.length, 'last': true};

// ---- pictures

/// A [w] x [h] picture drawn by [paint]. Real work: inside a widget test, call it in `tester.runAsync`.
Future<ui.Image> paintedImage(int w, int h, void Function(Canvas canvas) paint) async {
  final rec = ui.PictureRecorder();
  paint(Canvas(rec));
  return rec.endRecording().toImage(w, h);
}

/// A [w] x [h] picture of one colour. Real work: inside a widget test, call it in `tester.runAsync` (or use
/// [testImage]).
Future<ui.Image> solidImage(int w, int h, [Color color = Colors.white]) => paintedImage(w, h,
    (canvas) => canvas.drawRect(Rect.fromLTWH(0, 0, w.toDouble(), h.toDouble()), Paint()..color = color));

/// [image] as PNG file bytes (what Komga sends for a page).
Future<Uint8List> pngBytes(ui.Image image) async =>
    (await image.toByteData(format: ui.ImageByteFormat.png))!.buffer.asUint8List();

/// [solidImage] as PNG bytes.
Future<Uint8List> solidPng(int w, int h, [Color color = Colors.white]) async => pngBytes(await solidImage(w, h, color));

/// [solidImage] made on the real clock from inside a widget test.
Future<ui.Image> testImage(WidgetTester tester, int w, int h, [Color color = Colors.white]) async =>
    (await tester.runAsync(() => solidImage(w, h, color)))!;

// ---- shaders

/// For `setUpAll`: loads the app's shader programs for real, once, before any test's fake clock.
///
/// [Enhancer] and [PageCurl] each keep the Future of their first load in a static. If that first load starts inside a
/// widget test it belongs to that test's fake clock, never completes, and every later test that needs the shader waits
/// on it forever (found in hold_test and reader_test - test audit, 2026-09-30).
Future<void> preloadShaders() async {
  TestWidgetsFlutterBinding.ensureInitialized();
  await PageCurl.program();
  final img = await solidImage(4, 4, const Color(0xFFD8C8A8));
  (await Enhancer.colours(img, const [0, 0, 0], const [1, 1, 1]))?.dispose(); // loads every Enhancer program
  img.dispose();
}
