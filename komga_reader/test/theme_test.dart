// The app's theme (main.dart buildTheme).
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:komga_reader/main.dart';
import 'package:komga_reader/settings.dart';

void main() {
  testWidgets("a progress bar's unfilled part isn't the accent - every bar looked full (Downloads' storage bar at 10%, "
      'build 83)', (tester) async {
    for (final accent in [Accent.yellow, Accent.blue]) {
      final key = GlobalKey();
      await tester.pumpWidget(MaterialApp(
        theme: buildTheme(accent),
        themeAnimationDuration: Duration.zero, // (the second accent at once, not faded in from the first)
        home: Center(
          child: RepaintBoundary(
            key: key,
            child: const SizedBox(width: 200, height: 4, child: LinearProgressIndicator(value: 0.1, minHeight: 4)),
          ),
        ),
      ));
      final pixels = await tester.runAsync(() async {
        final image = await (key.currentContext!.findRenderObject()! as RenderRepaintBoundary).toImage();
        final data = (await image.toByteData(format: ui.ImageByteFormat.rawRgba))!;
        Color at(int x) => Color.fromARGB(
            data.getUint8((2 * 200 + x) * 4 + 3), data.getUint8((2 * 200 + x) * 4),
            data.getUint8((2 * 200 + x) * 4 + 1), data.getUint8((2 * 200 + x) * 4 + 2));
        final out = (filled: at(5), empty: at(150));
        image.dispose();
        return out;
      });
      expect(pixels!.filled, accent.colour, reason: '$accent: the used part in the accent');
      expect(pixels.empty, isNot(accent.colour), reason: '$accent: the rest not');
    }
  });
}
