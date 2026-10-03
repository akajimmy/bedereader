import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:komga_reader/widgets/poster.dart';

import 'support/helpers.dart';

/// Posters are never enlarged (user, 2026-10-02: Large tiles looked blurry - Komga's thumbnails are 195 x 300, a
/// Large tile at 100% scaling up to 221 x 331): a picture smaller than its tile shows at its own size, centred; one
/// that covers the tile fills it as before; anything over 500 px tall is first shrunk to 500.
void main() {
  /// [picture] (pixels) as a poster in a [tile] (logical pixels) on a screen of [dpr]; returns the drawn picture's
  /// rect relative to the tile, and its RawImage.
  Future<(Rect, RawImage)> show(WidgetTester tester, Size picture, Size tile, {double dpr = 1}) async {
    tester.view.physicalSize = const Size(1600, 1600);
    tester.view.devicePixelRatio = dpr;
    addTearDown(tester.view.reset);
    final png = (await tester.runAsync(() => solidPng(picture.width.round(), picture.height.round(), Colors.teal)))!;
    await tester.pumpWidget(MaterialApp(home: Align(alignment: Alignment.topLeft,
        child: SizedBox.fromSize(key: const ValueKey('tile'), size: tile, child: PosterImage(MemoryImage(png))))));
    await waitUntil(() => find.byType(RawImage).evaluate().isNotEmpty, tester: tester, reason: 'the picture decodes');
    final at = tester.getTopLeft(find.byKey(const ValueKey('tile')));
    return (tester.getRect(find.byType(RawImage)).shift(-at), tester.widget<RawImage>(find.byType(RawImage)));
  }

  testWidgets("Komga's 195 x 300 thumbnail in a Large tile (221 x 331): its own size, centred - not stretched",
      (tester) async {
    final (r, raw) = await show(tester, const Size(195, 300), const Size(221, 331));
    expect(r.size, const Size(195, 300));
    expect(r.center, const Offset(110.5, 165.5), reason: 'centred');
    expect(raw.image!.height, 300, reason: 'decoded at its own size');
  });

  testWidgets('the same thumbnail in a Medium tile (170 x 277): it covers the tile, so it fills it as before',
      (tester) async {
    final (r, raw) = await show(tester, const Size(195, 300), const Size(170, 277));
    expect(r, const Rect.fromLTWH(0, 0, 170, 277));
    expect(raw.fit, BoxFit.cover);
  });

  testWidgets('an uploaded poster 649 x 1000: shrunk to 500 px tall first, then fills a tile it covers',
      (tester) async {
    final (r, raw) = await show(tester, const Size(649, 1000), const Size(221, 331));
    expect(raw.image!.height, 500, reason: 'at most 500 px tall');
    expect(r, const Rect.fromLTWH(0, 0, 221, 331));
    final (r2, raw2) = await show(tester, const Size(649, 1000), const Size(400, 600)); // a tile bigger than 500 tall
    expect(raw2.image!.height, 500);
    expect(r2.height, 500, reason: 'never enlarged past 500');
  });

  testWidgets('on a 2x screen, one picture pixel to one physical pixel', (tester) async {
    final (r, _) = await show(tester, const Size(195, 300), const Size(221, 331), dpr: 2);
    expect(r.size, const Size(97.5, 150), reason: '195 x 300 pixels = 97.5 x 150 logical at 2x');
  });
}
