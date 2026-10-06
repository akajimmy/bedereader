// The EPUB reader turned back and forth quickly across chapters while the book is still being counted (user, build
// 65 on the PC: "flipping back and forth a bit caused it to get stuck" - a spinner where the page was, for good).
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:komga_reader/epub/source.dart';
import 'package:komga_reader/screens/epub_reader.dart';
import 'package:komga_reader/settings.dart';
import 'package:komga_reader/widgets/error_text.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/no_network.dart';

/// [n] short chapters (two or three pages each), each file taking [slow] to come.
class SlowBook implements EpubSource {
  SlowBook(this.n, this.slow);
  final int n;
  final Duration slow;
  @override
  Future<EpubInfo> info() async =>
      EpubInfo(spine: [for (var i = 0; i < n; i++) 'c$i.xhtml'], toc: const []);
  @override
  Future<Uint8List> resource(String path) async {
    await Future<void>.delayed(slow);
    final i = path.replaceAll(RegExp(r'\D'), '');
    final body = List.filled(6, '<p>${List.filled(45, 'word$i').join(' ')}</p>').join();
    return Uint8List.fromList(utf8.encode('<html><body><h1>Chapter $i</h1>$body</body></html>'));
  }
}

/// The same, but chapter 2's file fails while [down] (Komga slow to answer, say).
class FlakyBook extends SlowBook {
  FlakyBook() : super(4, Duration.zero);
  bool down = true;
  @override
  Future<Uint8List> resource(String path) async {
    if (path == 'c2.xhtml' && down) throw Exception('Komga took too long to answer');
    return super.resource(path);
  }
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    AppSettings.instance.setDisplay(const DisplayPrefs());
    // instant turns: the slide's animation doesn't advance on these tests' clock (taps every 50 ms restarted it)
    AppSettings.instance.setEpub(const EpubPrefs(turn: EpubTurn.none));
  });
  tearDown(() => AppSettings.instance.setEpub(const EpubPrefs()));

  Future<void> step(WidgetTester tester, int ms) async {
    await tester.runAsync(() => Future<void>.delayed(Duration(milliseconds: ms)));
    await tester.pump(const Duration(milliseconds: 50));
  }

  bool stuck() => find.byType(PageView).evaluate().isEmpty;

  testWidgets("a chapter that fails to load shows why, with Retry - not a spinner for good (it used to stay stuck: "
      'the failed try was kept); Retry brings it', (tester) async {
    tester.view.physicalSize = const Size(800, 1200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final source = FlakyBook();
    await tester.pumpWidget(MaterialApp(home: EpubReaderScreen(api: plainKomga(),
        book: const {'id': 'B', 'name': 'Book', 'media': {'mediaProfile': 'EPUB'}}, source: source,
        saveProgress: false)));
    for (var i = 0; i < 40 && stuck(); i++) {
      await step(tester, 20);
    }
    // forward until chapter 2 (its first try fails, whether the counting or the turn asks first)
    for (var i = 0; i < 20 && find.text('Retry').evaluate().isEmpty; i++) {
      await tester.tapAt(const Offset(750, 450));
      await step(tester, 20);
    }
    await tester.tapAt(const Offset(400, 450));
    await step(tester, 20);
    final where = tester.widgetList<Text>(find.byType(Text)).map((t) => t.data).toList();
    await tester.tapAt(const Offset(400, 450));
    await step(tester, 20);
    expect(find.text('Retry'), findsOneWidget, reason: 'the failure shows, with Retry; position: $where; on screen: '
        '${tester.widgetList<Text>(find.byType(Text)).map((t) => t.data).toList()} '
        '${find.byType(CircularProgressIndicator).evaluate().length} spinners, ${find.byType(PageView).evaluate().length} '
        'page views');
    expect(find.byType(ErrorText), findsOneWidget, reason: 'why, in plain words');
    source.down = false; // Komga answers again
    await tester.tap(find.text('Retry'));
    for (var i = 0; i < 20 && find.text('Retry').evaluate().isNotEmpty; i++) {
      await step(tester, 20);
    }
    expect(find.text('Retry'), findsNothing, reason: 'the chapter shows after Retry');
    expect(stuck(), isFalse);
    await tester.pumpWidget(const SizedBox());
    for (var i = 0; i < 20; i++) {
      await step(tester, 10);
    }
  });

  for (final pattern in ['forward then back', 'back and forth']) {
    testWidgets('turning quickly ($pattern) across chapters while the book is still being counted never leaves the '
        'reader on a spinner', (tester) async {
      tester.view.physicalSize = const Size(1600, 900); // a PC window
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(MaterialApp(home: EpubReaderScreen(api: plainKomga(),
          book: const {'id': 'B', 'name': 'Book', 'media': {'mediaProfile': 'EPUB'}},
          source: SlowBook(12, const Duration(milliseconds: 15)), saveProgress: false)));
      for (var i = 0; i < 40 && stuck(); i++) {
        await step(tester, 20);
      }
      expect(stuck(), isFalse, reason: 'opened');
      final moves = pattern == 'forward then back'
          ? [...List.filled(14, 1), ...List.filled(14, -1)]
          : [for (var i = 0; i < 30; i++) i % 3 == 2 ? -1 : 1];
      for (final m in moves) {
        await tester.tapAt(Offset(m > 0 ? 1550 : 50, 450));
        await step(tester, 5);
      }
      // given time to settle, it must be showing a page again
      for (var i = 0; i < 100 && stuck(); i++) {
        await step(tester, 20);
      }
      expect(stuck(), isFalse, reason: 'a page, not a spinner');
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      for (var i = 0; i < 20; i++) {
        await step(tester, 10);
      }
    });
  }
}
