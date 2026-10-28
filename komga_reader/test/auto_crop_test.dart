// Crop edges' Auto (user, 2026-10-28 - lib/reader/auto_crop.dart; dialled in on real books with the prototype,
// reports\10-28-autocrop-review): pages measured, each cut to its content plus an even border.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:komga_reader/page_image.dart';
import 'package:komga_reader/reader/auto_crop.dart';
import 'package:komga_reader/screens/reader.dart';
import 'package:komga_reader/settings.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/helpers.dart';
import 'support/no_network.dart';
import 'support/reader_server.dart';

const w = 300, h = 450;
const aged = [225, 187, 153], white = [255, 255, 255];

/// A page [w] x [h]: [paper] with a block of ink from ([l], [t]) to ([r], [b]) (pixels, exclusive); [extra] paints more.
Uint8List page({List<int> paper = aged, int l = 30, int t = 45, int r = 270, int b = 405,
    void Function(void Function(int x, int y, List<int> c) set)? extra}) {
  final px = Uint8List(w * h * 4);
  void set(int x, int y, List<int> c) {
    final i = (y * w + x) * 4;
    px[i] = c[0];
    px[i + 1] = c[1];
    px[i + 2] = c[2];
    px[i + 3] = 255;
  }

  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      set(x, y, x >= l && x < r && y >= t && y < b ? const [30, 30, 30] : paper);
    }
  }
  extra?.call(set);
  return px;
}

PageMeasure measured({List<int> paper = aged, int l = 30, int t = 45, int r = 270, int b = 405,
        void Function(void Function(int x, int y, List<int> c) set)? extra}) =>
    measurePage(page(paper: paper, l: l, t: t, r: r, b: b, extra: extra), w, h);

void main() {
  group('a page measured', () {
    test("its margins: where the ink starts on each side, shares of the page's width and height", () {
      final m = measured(l: 30, t: 45, r: 255, b: 405);
      expect(m.margins, [closeTo(0.1, 1e-9), closeTo(0.1, 1e-9), closeTo(0.15, 1e-9), closeTo(0.1, 1e-9)]);
      expect(m.paper, aged.map((v) => v.toDouble()).toList());
    });

    test('art running off a side: that side bleeds (none)', () {
      final m = measured(l: 0, b: h);
      expect(m.margins[0], isNull);
      expect(m.margins[3], isNull);
      expect(m.margins[1], closeTo(0.1, 1e-9));
    });

    test("aged paper's smooth shading is paper (the scan lit unevenly - Atomic Mouse's bottom margins), small print in "
        'it is not', () {
      // a lighter band below the ink, as the scan's light falls off
      void band(void Function(int, int, List<int>) set) {
        for (var y = 415; y < 445; y++) {
          for (var x = 0; x < w; x++) {
            set(x, y, const [240, 208, 176]);
          }
        }
      }

      expect(measured(extra: band).margins[3], closeTo(0.1, 1e-9), reason: 'the band is paper');
      final printed = measured(extra: (set) {
        band(set);
        for (var y = 420; y < 424; y++) {
          for (var x = 40; x < 200; x += 2) {
            set(x, y, const [90, 70, 60]); // small print, speckled at this size
          }
        }
      });
      expect(printed.margins[3], closeTo((h - 424) / h, 1e-9), reason: 'the print is content');
    });

    test("a thin dark strip at the scan's edge, paper inside it, isn't content", () {
      final m = measured(extra: (set) {
        for (var y = 0; y < h; y++) {
          for (var x = 2; x < 5; x++) {
            set(x, y, const [20, 20, 20]);
          }
        }
      });
      expect(m.margins[0], closeTo(0.1, 1e-9));
    });
  });

  group("the book's cuts", () {
    test('each page cut to its content plus the border all round - never into it', () {
      final cuts = bookCuts([for (var i = 0; i < 6; i++) measured()]);
      for (final c in cuts) {
        expect(c, isNotNull);
        // the border, a share of the page width: off the side margins as they are; top and bottom in the width's units
        expect(c!.left, closeTo(0.1 - defaultBorder, 0.004));
        expect(c.right, closeTo(0.1 - defaultBorder, 0.004));
        expect(c.top * h, closeTo(45 - defaultBorder * w, 1.5));
        expect(c.bottom * h, closeTo(45 - defaultBorder * w, 1.5));
      }
    });

    test('a page whose art bleeds is never cut on that side; a full-bleed one (the cover) is shown whole', () {
      final cuts = bookCuts([measured(l: 0, t: 0, r: w, b: h), measured(r: w), for (var i = 0; i < 5; i++) measured()]);
      expect(cuts[0], isNull, reason: 'the cover');
      expect(cuts[1]!.right, 0);
      expect(cuts[1]!.left, greaterThan(0));
    });

    test('taking more than 15% off a side is a mistake: not cut (user, 2026-10-28: "assume it\'s a mistake (don\'t just '
        'crop to the cap)")', () {
      final cuts = bookCuts([for (var i = 0; i < 4; i++) measured(l: 57, t: 86, r: 243, b: 364)]); // ~19% margins
      expect(cuts, everyElement(isNull));
    });

    test("a page whose edge colour is dark art, not paper, is shown whole (Punisher's flat dark backgrounds)", () {
      final cuts = bookCuts([measured(paper: const [40, 38, 36]), for (var i = 0; i < 5; i++) measured()]);
      expect(cuts[0], isNull);
      expect(cuts.skip(1), everyElement(isNotNull));
    });

    test("a page number in the border isn't cut through: the cut moves out past it (Dragon Ball's page numbers)", () {
      // a number 8 px wide, rows 412-417 - inside the border's reach (the cut would be at ~37 px from the bottom)
      PageMeasure numbered() => measured(paper: white, extra: (set) {
            for (var y = 412; y < 418; y++) {
              for (var x = 146; x < 154; x++) {
                set(x, y, const [0, 0, 0]);
              }
            }
          });
      final c = bookCuts([for (var i = 0; i < 5; i++) numbered()]).first!;
      expect(c.bottom * h, lessThanOrEqualTo(h - 418), reason: 'below the number');
      expect(c.bottom, greaterThan(0));
    });

    test('Crop edges: a fixed step cuts every side (a strip: the sides only); Auto, the page\'s own - or nothing', () {
      const auto = ReaderPrefs(crop: ReaderPrefs.autoCrop);
      const own = PageCut(0.1, 0.05, 0.08, 0.06);
      expect(cutFor(const ReaderPrefs(crop: 0.04), own), PageCut.even(0.04));
      expect(cutFor(const ReaderPrefs(crop: 0.04), null, sidesOnly: true), const PageCut(0.04, 0, 0.04, 0));
      expect(cutFor(auto, own), own);
      expect(cutFor(auto, null), PageCut.none, reason: 'a page shown whole');
      expect(cutFor(auto, own, sidesOnly: true), PageCut.none, reason: "a webtoon's strip isn't");
      expect(croppedSize(1000, 1500, own), const Size(820, 1335));
    });
  });

  group('remembered', () {
    setUp(() => SharedPreferences.setMockInitialValues({}));

    test('a book\'s cuts are kept for its page count and border; another border or count: measured again', () {
      final cuts = [const PageCut(0.1, 0.05, 0.08, 0.06), null];
      final v = AutoCropStore.encode(0.025, cuts);
      expect(AutoCropStore.decode(v, 2, 0.025), cuts);
      expect(AutoCropStore.decode(v, 2, 0.03), isNull);
      expect(AutoCropStore.decode(v, 3, 0.025), isNull);
    });

    test('a run measures every page once, remembers the result, and a second run uses it; a page that fails is shown '
        'whole and the book is not remembered', () async {
      final api = noNetwork(_Thumbs.new);
      var measures = 0;
      Future<PageMeasure?> measure(Uint8List bytes, AutoCropTimes _) async {
        measures++;
        return bytes.isEmpty ? null : measured();
      }

      final first = await AutoCropRun(api, 'B1', [1, 2, 3, 4, 5], border: 0.025, measure: measure).finished;
      expect(measures, 5);
      expect(first, everyElement(isNotNull));
      final again = await AutoCropRun(api, 'B1', [1, 2, 3, 4, 5], border: 0.025, measure: measure).finished;
      expect(measures, 5, reason: 'remembered');
      expect(again, first);

      api.failing = 2;
      final failed = await AutoCropRun(api, 'B2', [1, 2, 3, 4, 5], border: 0.025, measure: measure).finished;
      expect(failed[1], isNull);
      expect(await AutoCropStore.load('B2', 5, 0.025), isNull);
    });
  });

  group('in the reader', () {
    setUp(() => SharedPreferences.setMockInitialValues({}));
    tearDown(() {
      AutoCropRun.measureForTests = null;
      AppSettings.instance.setDefault(const ReaderPrefs());
    });

    testWidgets('on Auto, a book opens on "Finding page borders" with its progress, then its pages; opened again, it '
        "has nothing to wait for (user, 2026-10-28: \"wait, then open cropped\")", (tester) async {
      AutoCropRun.measureForTests = (bytes, _) async => measured();
      AppSettings.instance.setDefault(const ReaderPrefs(crop: ReaderPrefs.autoCrop));
      final api = noNetwork(_Thumbs.new)..held = Completer<void>();
      await tester.pumpWidget(MaterialApp(home: ReaderScreen(api: api, book: api.theBook)));
      await tester.pump();
      await tester.pump();
      expect(find.text('Finding page borders'), findsOneWidget);
      expect(find.byKey(const ValueKey('autocrop-counting')), findsOneWidget);
      api.held!.complete();
      await tester.pump();
      await tester.pump();
      expect(find.text('Finding page borders'), findsNothing);
      expect(api.asked, 3);

      await tester.pumpWidget(const SizedBox());
      await tester.pumpWidget(MaterialApp(home: ReaderScreen(api: api, book: api.theBook)));
      await tester.pump();
      await tester.pump();
      expect(find.text('Finding page borders'), findsNothing);
      expect(api.asked, 3, reason: 'remembered: not measured again');
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('Auto chosen part way through a book: after "Finding page borders", the page being read shows, cut - it '
        'stayed black until it was turned (the tablet, build 170: Auto chosen on page 3 of a book opened at page 1)',
        (tester) async {
      _Pages.png = (await tester.runAsync(() => solidPng(200, 300, const Color(0xFFE0D0B0))))!;
      AutoCropRun.measureForTests = (bytes, _) async => measured();
      final api = noNetwork(_Pages.new);
      Future<void> settle() async {
        for (var i = 0; i < 12; i++) {
          await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
          await tester.pump(const Duration(milliseconds: 100));
        }
      }

      await tester.pumpWidget(MaterialApp(home: ReaderScreen(api: api, book: api.theBook)));
      await settle();
      for (var i = 0; i < 2; i++) {
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
        await settle();
      }
      AppSettings.instance.setOverride('S1', layout: true, image: true);
      AppSettings.instance.setSeriesImage('S1', AppSettings.instance.prefsFor('S1').copyWith(crop: ReaderPrefs.autoCrop));
      await tester.pump();
      expect(find.text('Finding page borders'), findsOneWidget);
      await settle();
      expect(find.text('Finding page borders'), findsNothing);
      final page = tester.widget<PageCanvas>(find.byType(PageCanvas));
      expect(page.autoCut, isNotNull, reason: 'the page being read, drawn and cut');
      expect(page.data.image.width, 200);
      AppSettings.instance.useDefaults('S1');
      await tester.pumpWidget(const SizedBox());
    });
  });
}

/// The reader's 3-page book with pages that load ([png] each) and thumbnails at once.
class _Pages extends ReaderServer {
  static late Uint8List png;
  @override
  Future<Uint8List> pageBytes(String bookId, int number) async => png;
  @override
  Future<Uint8List> pageThumbBytes(String bookId, int number) async => png;
}

/// The reader's 3-page book whose page thumbnails arrive (once [held] completes, if set); page [failing] fails.
class _Thumbs extends ReaderServer {
  Completer<void>? held;
  int asked = 0, failing = 0;
  @override
  Future<Uint8List> pageThumbBytes(String bookId, int number) async {
    asked++;
    await held?.future;
    if (number == failing) throw Exception('no thumbnail');
    return Uint8List(4);
  }
}
