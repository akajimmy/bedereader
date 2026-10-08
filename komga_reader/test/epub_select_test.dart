// Selecting text on an EPUB page and copying it (user, 2026-10-08): the page is a Selectable under a SelectionArea
// (lib/reader/epub_selection.dart); taps, swipes and keys go on as before.
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:komga_reader/epub/count_store.dart';
import 'package:komga_reader/epub/source.dart';
import 'package:komga_reader/reader/epub_selection.dart';
import 'package:komga_reader/screens/reader.dart';
import 'package:komga_reader/settings.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/epub_books.dart';
import 'support/no_network.dart';

const _long = 'The extraordinary fishermen remembered uncomfortable temperatures and particularly unpredictable '
    'weather conditions throughout their understandable conversations. ';

MemorySource _book() => MemorySource({
      'c1.xhtml': '<html><body><p>Ant bee cow.</p><p>Dog eel fox.</p>'
          '<p>${List.filled(8, _long).join()}</p>${List.filled(12, para('word', 40)).join()}</body></html>',
    }, const EpubInfo(spine: ['c1.xhtml'], toc: []));

/// A Komga where the book is the series' last (the end card asks).
class _LastKomga extends TestKomga {
  @override
  Future<Map<String, dynamic>?> nextBook(String bookId, {String? readListId}) async => null;
  @override
  ImageProvider thumbImage(String ref) => MemoryImage(onePixelPng);
}

void main() {
  late EpubCountStore counts;
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
    await tester.pumpWidget(MaterialApp(home: ReaderScreen(api: noNetwork(() => _LastKomga()),
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

  testWidgets('Windows: a mouse drag selects, Ctrl+C copies; a click lets go of it', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    try {
      await open(tester);
      final from = box(tester, 'Ant').centerLeft, to = box(tester, 'eel').centerRight;
      final g = await tester.startGesture(from - const Offset(3, 0), kind: PointerDeviceKind.mouse);
      await tester.pump(const Duration(milliseconds: 50));
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
