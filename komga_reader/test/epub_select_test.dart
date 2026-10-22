// Selecting text on an EPUB page and copying it (user, 2026-10-08): the page is a Selectable under a SelectionArea
// (lib/reader/epub_selection.dart); taps, swipes and keys go on as before.
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:komga_reader/dictionary.dart';
import 'package:komga_reader/epub/count_store.dart';
import 'package:komga_reader/epub/source.dart';
import 'package:komga_reader/reader/epub_renderer.dart';
import 'package:komga_reader/reader/epub_selection.dart';
import 'package:komga_reader/screens/reader.dart';
import 'package:komga_reader/settings.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/client_settings.dart';
import 'support/epub_books.dart';
import 'support/no_network.dart';

const _long = 'The extraordinary fishermen remembered uncomfortable temperatures and particularly unpredictable '
    'weather conditions throughout their understandable conversations. ';

MemorySource _book() => MemorySource({
      'c1.xhtml': '<html><body><p>Ant bee cow.</p><p>Dog eel fox.</p>'
          '<p>${List.filled(8, _long).join()}</p>${List.filled(12, para('word', 40)).join()}</body></html>',
    }, const EpubInfo(spine: ['c1.xhtml'], toc: []));

/// A Komga where the book is the series' last (the end card asks).
class _LastKomga extends TestKomga with ClientSettingsStore {
  @override
  Future<Map<String, dynamic>?> nextBook(String bookId, {String? readListId}) async => null;
  @override
  ImageProvider thumbImage(String ref) => MemoryImage(onePixelPng);
}

void main() {
  late EpubCountStore counts;
  late _LastKomga server;
  String? copied;
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    AppSettings.instance.setDisplay(const DisplayPrefs());
    counts = EpubCountStore.instance;
    EpubCountStore.instance = MemoryCountStore();
    copied = null;
  });
  tearDown(() => EpubCountStore.instance = counts);

  Future<void> open(WidgetTester tester) async {
    tester.view.physicalSize = const Size(800, 1200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    // the clipboard: what Copy puts there
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') copied = (call.arguments as Map)['text'] as String?;
      return null;
    });
    addTearDown(() => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null));
    await tester.pumpWidget(MaterialApp(home: ReaderScreen(api: server = noNetwork(() => _LastKomga()),
        book: const {'id': 'B1', 'name': 'Book', 'media': {'mediaProfile': 'EPUB'}}, epubSource: _book(),
        saveProgress: false)));
    for (var i = 0; i < 200; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pump();
      if (find.byType(PageView).evaluate().isNotEmpty && i > 10) break;
    }
    expect(find.byType(PageView), findsOneWidget);
  }

  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 10; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  /// The page on screen.
  RenderSelectablePage shown(WidgetTester tester) => tester
      .renderObjectList<RenderSelectablePage>(find.byType(SelectablePage))
      .firstWhere((r) => r.localToGlobal(Offset.zero).dx.abs() < 1);

  /// Where [word] is drawn on the page on screen (its middle, screen coordinates).
  Rect box(WidgetTester tester, String word) {
    final r = shown(tester);
    final boxes = r.page.text.boxesOf(word);
    expect(boxes, isNotEmpty, reason: '"$word" is on the page');
    return boxes.first.shift(r.localToGlobal(Offset.zero));
  }

  Offset at(WidgetTester tester, String word) => box(tester, word).center;

  /// The page's place, from its first text ("page 1": the book's first words on it).
  bool onFirstPage(WidgetTester tester) => shown(tester).page.text.boxesOf('Ant').isNotEmpty;

  String? selected(WidgetTester tester) => shown(tester).getSelectedContent()?.plainText;

  testWidgets("a long press selects the word under the finger; the pane's Copy puts it on the clipboard",
      (tester) async {
    await open(tester);
    await tester.longPressAt(at(tester, 'eel'));
    await tester.pumpAndSettle(const Duration(milliseconds: 100));
    expect(selected(tester), 'eel');
    expect(find.text('Copy'), findsOneWidget, reason: 'the pane, with Copy');
    await tester.tap(find.text('Copy'));
    await tester.pumpAndSettle(const Duration(milliseconds: 100));
    expect(copied, 'eel');
    expect(onFirstPage(tester), isTrue);
  });

  testWidgets("a selected word's pane has Define: the word's meanings from the dictionary in a sheet over the page; "
      'a long selection has no Define (user, 2026-10-11)', (tester) async {
    final real = EnglishDictionary.loader;
    addTearDown(() {
      EnglishDictionary.loader = real;
      EnglishDictionary.reset();
    });
    EnglishDictionary.reset();
    EnglishDictionary.loader =
        () async => EnglishDictionary.parse('n\ta long snakelike fish\teels slid in the mud\n\neel\t0\n');
    await open(tester);
    await tester.longPressAt(at(tester, 'eel'));
    await tester.pumpAndSettle(const Duration(milliseconds: 100));
    await tester.tap(find.text('Define'));
    await tester.pumpAndSettle(const Duration(milliseconds: 100));
    expect(find.byKey(const ValueKey('define.word.eel')), findsOneWidget);
    expect(find.textContaining('snakelike fish', findRichText: true), findsOneWidget);
    expect(find.text('Copy'), findsNothing, reason: 'the pane gave way to the sheet');
    await tester.tapAt(const Offset(400, 40)); // outside the sheet: closed
    await tester.pumpAndSettle(const Duration(milliseconds: 100));
    expect(find.byKey(const ValueKey('define.list')), findsNothing);

    // a long selection: copy only
    final g = await tester.startGesture(at(tester, 'Ant'));
    await tester.pump(kLongPressTimeout + const Duration(milliseconds: 50));
    await g.moveTo(at(tester, 'fox'));
    await tester.pump();
    await g.up();
    await tester.pumpAndSettle(const Duration(milliseconds: 100));
    expect(selected(tester), contains('fox'));
    expect(find.text('Define'), findsNothing);
  });

  testWidgets("the pane's Highlight keeps the selection on Komga under the book (chapter positions); a tap on it "
      'offers Remove, which takes it away; the Contents panel lists it (user, 2026-10-11)', (tester) async {
    await open(tester);
    await tester.longPressAt(at(tester, 'eel'));
    await tester.pumpAndSettle(const Duration(milliseconds: 100));
    await tester.tap(find.text('Highlight'));
    await tester.pumpAndSettle(const Duration(milliseconds: 100));
    await settle(tester);
    final saved = jsonDecode(server.written['komgareader.highlights.b1']!) as List;
    expect(saved.single['t'], 'eel');
    expect(saved.single['e'] - saved.single['s'], 3, reason: 'three characters of the chapter');
    expect(selected(tester), isNull, reason: 'the selection let go of');

    // in Contents - from another page, so going to the highlight is seen (from its own page the check couldn't fail -
    // audit, 2026-10-11)
    await tester.tapAt(const Offset(760, 600)); // a page on
    await settle(tester);
    expect(onFirstPage(tester), isFalse);
    await tester.tapAt(const Offset(400, 600)); // the controls
    await tester.pumpAndSettle(const Duration(milliseconds: 100));
    await tester.tap(find.byTooltip('Contents'));
    await tester.pumpAndSettle(const Duration(milliseconds: 100));
    expect(find.byKey(const ValueKey('contents.highlights')), findsOneWidget);
    expect(find.text('eel'), findsOneWidget);
    await tester.tap(find.text('eel'));
    await tester.pumpAndSettle(const Duration(milliseconds: 100));
    await settle(tester);
    expect(onFirstPage(tester), isTrue, reason: 'its page');

    // a tap on it: Remove
    await tester.tapAt(at(tester, 'eel'));
    await tester.pumpAndSettle(const Duration(milliseconds: 100));
    expect(onFirstPage(tester), isTrue, reason: 'not a page turn');
    await tester.tap(find.text('Remove highlight'));
    await tester.pumpAndSettle(const Duration(milliseconds: 100));
    await settle(tester);
    expect(jsonDecode(server.written['komgareader.highlights.b1']!), isEmpty);
    await tester.tapAt(at(tester, 'eel'));
    await tester.pumpAndSettle(const Duration(milliseconds: 100));
    expect(find.text('Remove highlight'), findsNothing, reason: 'gone: a tap is a tap again');
  });

  testWidgets('a long press dragged on extends the selection, word by word, across a paragraph boundary', (tester) async {
    await open(tester);
    final g = await tester.startGesture(at(tester, 'bee'));
    await tester.pump(kLongPressTimeout + const Duration(milliseconds: 50));
    expect(selected(tester), 'bee');
    await g.moveTo(at(tester, 'eel'));
    await tester.pump();
    await g.up();
    await tester.pumpAndSettle(const Duration(milliseconds: 100));
    expect(selected(tester), 'bee cow.\nDog eel');
    await tester.tap(find.text('Copy'));
    await tester.pumpAndSettle(const Duration(milliseconds: 100));
    expect(copied, 'bee cow.\nDog eel');
  });

  testWidgets('copy is plain text: a word broken over two lines is copied whole, without its soft hyphen',
      (tester) async {
    await open(tester);
    final page = shown(tester).page;
    expect(page.hyphenMarks, greaterThan(0), reason: 'a word broken at a line end on the page');
    // from the long paragraph's first word to the page's foot
    final g = await tester.startGesture(at(tester, 'The '));
    await tester.pump(kLongPressTimeout + const Duration(milliseconds: 50));
    await g.moveTo(const Offset(700, 1150)); // the page's foot
    await tester.pump();
    await g.up();
    await tester.pumpAndSettle(const Duration(milliseconds: 100));
    await tester.tap(find.text('Copy'));
    await tester.pumpAndSettle(const Duration(milliseconds: 100));
    final source = _long.replaceAll('.', '').split(' ').where((w) => w.isNotEmpty).toSet()..add('word');
    expect(copied, startsWith('The extraordinary'));
    expect(copied, isNot(contains('\u00AD')));
    for (final w in copied!.replaceAll('.', '').split(RegExp(r'\s+')).where((w) => w.isNotEmpty)) {
      expect(source, contains(w), reason: 'every word whole: "$w"');
    }
  });

  testWidgets("with text selected a tap lets go of it and doesn't turn the page; then taps turn pages and open the "
      'controls as before', (tester) async {
    await open(tester);
    await tester.longPressAt(at(tester, 'cow'));
    await tester.pumpAndSettle(const Duration(milliseconds: 100));
    expect(selected(tester), 'cow');
    await tester.tapAt(const Offset(750, 600)); // the right side: a turn, normally
    await settle(tester);
    expect(selected(tester), isNull, reason: 'the selection let go of');
    expect(find.text('Copy'), findsNothing);
    expect(onFirstPage(tester), isTrue, reason: 'no turn');
    await tester.tapAt(const Offset(750, 600));
    await settle(tester);
    expect(onFirstPage(tester), isFalse, reason: 'the next tap turns');
    await tester.tapAt(const Offset(400, 600));
    await settle(tester);
    expect(find.text('Close'), findsOneWidget, reason: 'the middle: the controls');
  });

  testWidgets('a page turn lets go of the selection (a key, a swipe)', (tester) async {
    await open(tester);
    await tester.longPressAt(at(tester, 'Ant'));
    await tester.pumpAndSettle(const Duration(milliseconds: 100));
    expect(selected(tester), 'Ant');
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await settle(tester);
    expect(onFirstPage(tester), isFalse, reason: 'the key turned the page');
    expect(find.text('Copy'), findsNothing);
    expect(tester.renderObjectList<RenderSelectablePage>(find.byType(SelectablePage))
        .where((r) => r.getSelectedContent() != null), isEmpty, reason: 'nothing selected on any page');
    await tester.tapAt(const Offset(50, 600)); // not taken as "let go of the selection": it turns back
    await settle(tester);
    expect(onFirstPage(tester), isTrue);
    // a swipe
    await tester.longPressAt(at(tester, 'Ant'));
    await tester.pumpAndSettle(const Duration(milliseconds: 100));
    expect(selected(tester), 'Ant');
    await tester.fling(find.byType(PageView), const Offset(-500, 0), 2000);
    await settle(tester);
    expect(onFirstPage(tester), isFalse, reason: 'the swipe turned the page');
    expect(find.text('Copy'), findsNothing);
  });

  testWidgets('quick taps turn a page each - a second tap held a moment is not taken as a double tap that selects',
      (tester) async {
    await open(tester);
    await tester.tapAt(const Offset(750, 600));
    await tester.pump(const Duration(milliseconds: 50));
    final g = await tester.startGesture(const Offset(750, 600));
    await tester.pump(const Duration(milliseconds: 150)); // held past the selection's 100 ms
    await g.up();
    await settle(tester);
    expect(find.text('Copy'), findsNothing);
    expect(tester.renderObjectList<RenderSelectablePage>(find.byType(SelectablePage))
        .where((r) => r.getSelectedContent() != null), isEmpty);
  });

  // ---- user, 2026-10-12 (bug reports, on Windows)

  /// A press on [f] as a hand makes it: down, held over a few frames, up (a tap in one frame hid that the pane went
  /// from under the button as it was pressed - build 106, Windows: Highlight and Define did nothing).
  Future<void> press(WidgetTester tester, Finder f, {PointerDeviceKind kind = PointerDeviceKind.touch}) async {
    final g = await tester.startGesture(tester.getCenter(f), kind: kind);
    await tester.pump(const Duration(milliseconds: 40));
    await tester.pump(const Duration(milliseconds: 40));
    await g.up();
    await tester.pumpAndSettle(const Duration(milliseconds: 100));
  }

  testWidgets("the pane's buttons take a press held over a few frames, as a hand presses them - a mouse click on "
      'Windows (a double click selecting), a finger on the tablet (user, build 106: nothing happened)', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    try {
      await open(tester);
      final spot = Offset(400, at(tester, 'weather').dy);
      await tester.tapAt(spot, kind: PointerDeviceKind.mouse);
      await tester.pump(const Duration(milliseconds: 80));
      await tester.tapAt(spot, kind: PointerDeviceKind.mouse);
      await tester.pumpAndSettle(const Duration(milliseconds: 100));
      final word = selected(tester);
      expect(word, isNotNull);
      await press(tester, find.text('Highlight'), kind: PointerDeviceKind.mouse);
      await settle(tester);
      expect(server.written['komgareader.highlights.b1'], isNotNull, reason: 'the click highlighted it');
      expect((jsonDecode(server.written['komgareader.highlights.b1']!) as List).single['t'], word);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
    // a finger (Android)
    await tester.longPressAt(at(tester, 'cow'));
    await tester.pumpAndSettle(const Duration(milliseconds: 100));
    await press(tester, find.text('Copy'));
    expect(copied, 'cow');
  });

  testWidgets("Windows: the selection's pane shows by itself once a mouse drag (held first) lets go - no right-click "
      '- and its Copy copies', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    try {
      await open(tester);
      final g = await tester.startGesture(box(tester, 'Dog').centerLeft + const Offset(1, 0),
          kind: PointerDeviceKind.mouse);
      await tester.pump(kLongPressTimeout + const Duration(milliseconds: 50)); // held: to select (2026-10-22)
      await g.moveTo(box(tester, 'eel').centerRight - const Offset(1, 0));
      await tester.pump();
      expect(find.byKey(const ValueKey('epub-selection-pane')), findsNothing, reason: 'not while the button is down');
      await g.up();
      await tester.pumpAndSettle(const Duration(milliseconds: 100));
      expect(selected(tester), 'Dog eel');
      expect(find.byKey(const ValueKey('epub-selection-pane')), findsOneWidget, reason: 'by itself');
      expect(find.text('Highlight'), findsOneWidget);
      await tester.tap(find.text('Copy'));
      await tester.pumpAndSettle(const Duration(milliseconds: 100));
      expect(copied, 'Dog eel');
      expect(selected(tester), isNull);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets('a selection over a highlight offers Remove highlight, which takes it away (there was no way to it '
      'from a selection)', (tester) async {
    await open(tester);
    await tester.longPressAt(at(tester, 'eel'));
    await tester.pumpAndSettle(const Duration(milliseconds: 100));
    await tester.tap(find.text('Highlight'));
    await tester.pumpAndSettle(const Duration(milliseconds: 100));
    await settle(tester);
    expect(jsonDecode(server.written['komgareader.highlights.b1']!) as List, hasLength(1));
    await tester.longPressAt(at(tester, 'eel'));
    await tester.pumpAndSettle(const Duration(milliseconds: 100));
    expect(find.text('Remove highlight'), findsOneWidget);
    expect(find.text('Highlight'), findsNothing, reason: 'all of it highlighted already');
    await tester.tap(find.text('Remove highlight'));
    await tester.pumpAndSettle(const Duration(milliseconds: 100));
    await settle(tester);
    expect(jsonDecode(server.written['komgareader.highlights.b1']!) as List, isEmpty);
  });

  testWidgets('a highlight is drawn in the app\'s accent colour (it was a fixed yellow)', (tester) async {
    await open(tester);
    await tester.longPressAt(at(tester, 'eel'));
    await tester.pumpAndSettle(const Duration(milliseconds: 100));
    await tester.tap(find.text('Highlight'));
    await tester.pumpAndSettle(const Duration(milliseconds: 100));
    await settle(tester);
    final accent = Theme.of(tester.element(find.byType(PageView))).colorScheme.primary;
    final painters = tester
        .widgetList<CustomPaint>(find.byWidgetPredicate(
            (w) => w is CustomPaint && w.painter.runtimeType.toString() == '_PagePainter'))
        .map((w) => w.painter as dynamic)
        .where((p) => (p.marks as List).isNotEmpty);
    final mark = painters.first.markColour as Color;
    expect((mark.r, mark.g, mark.b), (accent.r, accent.g, accent.b));
  });

  testWidgets('Windows: a mouse click in the middle that moves a pixel or two while pressed still brings up the '
      'controls (the selection took it for a drag - user, build 107: "having to click a couple times"); a double '
      'click where there is no word brings them up too (it cancelled them)', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    try {
      await open(tester);
      Future<void> click(Offset at, {double wobble = 0}) async {
        final g = await tester.startGesture(at, kind: PointerDeviceKind.mouse);
        await tester.pump(const Duration(milliseconds: 30));
        if (wobble > 0) await g.moveBy(Offset(wobble, 0));
        await tester.pump(const Duration(milliseconds: 30));
        await g.up();
      }

      final spot = Offset(400, at(tester, 'weather').dy);
      await click(spot, wobble: 2);
      await tester.pump(EpubRenderer.doubleTapWait);
      await tester.pumpAndSettle(const Duration(milliseconds: 100));
      expect(find.byTooltip('Contents'), findsOneWidget, reason: 'the wobbly click: the controls');
      expect(selected(tester), isNull, reason: 'nothing selected by the wobble');
      await tester.tapAt(const Offset(400, 600), kind: PointerDeviceKind.mouse); // the controls away
      await tester.pumpAndSettle(const Duration(milliseconds: 100));
      expect(find.byTooltip('Contents'), findsNothing);
      // a double click below the text (no word there)
      final blank = Offset(400, tester.getSize(find.byType(PageView)).height - 12);
      await click(blank);
      await tester.pump(const Duration(milliseconds: 80));
      await click(blank);
      await tester.pumpAndSettle(const Duration(milliseconds: 100));
      expect(find.byTooltip('Contents'), findsOneWidget, reason: 'no word: the controls after all');
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets('a right-click brings up the controls and another takes them away, however far the mouse moves while '
      'the button is down (past 18 px the click was lost - user, build 108)', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    try {
      await open(tester);
      Future<void> rightClick(Offset at) async {
        final g = await tester.startGesture(at, kind: PointerDeviceKind.mouse, buttons: kSecondaryMouseButton);
        await tester.pump(const Duration(milliseconds: 30));
        await g.moveBy(const Offset(30, 4));
        await tester.pump(const Duration(milliseconds: 30));
        await g.up();
        await tester.pumpAndSettle(const Duration(milliseconds: 100));
      }

      await rightClick(Offset(400, at(tester, 'weather').dy));
      expect(find.byTooltip('Contents'), findsOneWidget, reason: 'shown');
      expect(selected(tester), isNull, reason: 'no word selected by it');
      await rightClick(const Offset(400, 600));
      expect(find.byTooltip('Contents'), findsNothing, reason: 'hidden again');
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets('a finger tap in the middle opens the controls at once - a word on a touch screen is a long press, not a '
      'double tap (user, build 107)', (tester) async {
    await open(tester);
    await tester.tapAt(Offset(400, at(tester, 'weather').dy));
    await tester.pump();
    await tester.pump();
    expect(find.byTooltip('Contents'), findsOneWidget, reason: 'no wait for a second tap');
  });

  testWidgets('a double click on a word in the middle of the page selects it, with its pane; one click there still '
      'opens the controls (a moment later); the sides still turn at once', (tester) async {
    await open(tester);
    final spot = Offset(400, at(tester, 'weather').dy); // the middle of a full line of the long paragraph
    await tester.tapAt(spot, kind: PointerDeviceKind.mouse);
    await tester.pump(const Duration(milliseconds: 80));
    await tester.tapAt(spot, kind: PointerDeviceKind.mouse);
    await tester.pumpAndSettle(const Duration(milliseconds: 100));
    final word = selected(tester);
    expect(word, isNotNull, reason: 'a word selected');
    expect(word, matches(RegExp(r'^[A-Za-z­]+[.,]?$')), reason: 'one whole word: "$word"');
    expect(find.byKey(const ValueKey('epub-selection-pane')), findsOneWidget);
    expect(find.byTooltip('Contents'), findsNothing, reason: 'no controls');
    await tester.tapAt(const Offset(400, 40), kind: PointerDeviceKind.mouse); // a click lets go of the selection
    await settle(tester);
    expect(selected(tester), isNull);
    await tester.tapAt(spot, kind: PointerDeviceKind.mouse); // one click
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.byTooltip('Contents'), findsNothing, reason: 'not yet: a second click could come');
    await tester.pump(EpubRenderer.doubleTapWait);
    await tester.pumpAndSettle(const Duration(milliseconds: 100));
    expect(find.byTooltip('Contents'), findsOneWidget, reason: 'the controls');
  });

  testWidgets('Windows: a mouse drag that moves at once, over the text, turns the page and selects nothing (user, '
      '2026-10-22: hold to select)', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    try {
      await open(tester);
      final y = box(tester, 'Dog').center.dy;
      final g = await tester.startGesture(Offset(700, y), kind: PointerDeviceKind.mouse);
      for (var i = 1; i <= 20; i++) {
        await g.moveTo(Offset(700 - i * 30.0, y));
        await tester.pump(const Duration(milliseconds: 16));
      }
      await g.up();
      await settle(tester);
      expect(selected(tester), isNull, reason: 'nothing selected');
      expect(onFirstPage(tester), isFalse, reason: 'turned');
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets('Windows: a mouse drag held first selects, Ctrl+C copies; a click lets go of it', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    try {
      await open(tester);
      final from = box(tester, 'Ant').centerLeft, to = box(tester, 'eel').centerRight;
      final g = await tester.startGesture(from - const Offset(3, 0), kind: PointerDeviceKind.mouse);
      await tester.pump(kLongPressTimeout + const Duration(milliseconds: 50)); // held: to select (2026-10-22)
      await g.moveTo(to - const Offset(1, 0));
      await tester.pump();
      await g.up();
      await tester.pump(const Duration(milliseconds: 400));
      expect(selected(tester), 'Ant bee cow.\nDog eel');
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyC);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pump();
      expect(copied, 'Ant bee cow.\nDog eel');
      expect(onFirstPage(tester), isTrue);
      await tester.tapAt(const Offset(750, 600), kind: PointerDeviceKind.mouse);
      await settle(tester);
      expect(selected(tester), isNull);
      expect(onFirstPage(tester), isTrue, reason: "the click let go of the selection, it didn't turn");
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });
}
