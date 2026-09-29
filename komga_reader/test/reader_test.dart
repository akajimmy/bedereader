import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:komga_reader/api.dart';
import 'package:komga_reader/page_image.dart';
import 'package:komga_reader/screens/library.dart';
import 'package:komga_reader/screens/reader.dart';
import 'package:komga_reader/settings.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Komga stand-in: a 3-page book whose pages never finish loading (enough to drive the controls).
class FakeKomga extends Komga {
  FakeKomga() : super('http://test', 'k');
  final theBook = {'id': 'B1', 'seriesId': 'S1', 'seriesTitle': 'Test', 'metadata': {'number': '1', 'title': 'T'}};
  static String direction = 'LEFT_TO_RIGHT'; // the series' reading direction in Komga
  @override
  Future<Map<String, dynamic>?> book(String id) async => theBook;
  @override
  Future<Map<String, dynamic>?> oneSeries(String id) async => {'id': id, 'metadata': {'readingDirection': direction}};
  @override
  Future<List<dynamic>> pages(String bookId) async => [{'number': 1}, {'number': 2}, {'number': 3}];
  @override
  Future<Uint8List> pageBytes(String bookId, int number) => Future.any([]); // never completes
  @override
  Future<void> setProgress(String bookId, int page, {bool completed = false}) async => saves.add(page);
  final saves = <int>[];
  final marked = <String>[];
  int nextCalls = 0;
  @override
  Future<void> markRead(String bookId) async => marked.add(bookId);
  @override
  Future<Map<String, dynamic>?> nextBook(String bookId, {String? readListId}) async {
    nextCalls++;
    askedReadList = readListId;
    return next;
  }

  Map<String, dynamic>? next; // the book after this one (null = last one)
  String? askedReadList = 'not asked';
  @override
  Future<Map<String, dynamic>?> previousBook(String bookId, {String? readListId}) async => null;
  @override
  Future<Map<String, dynamic>> clientSettings() async => {};
  @override
  Future<void> putClientSetting(String key, String value) async {}
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  late FakeKomga api;

  Future<void> openReader(WidgetTester tester, {String? readListId, Map<String, dynamic>? next}) async {
    api = FakeKomga()..next = next;
    await tester.pumpWidget(MaterialApp(
      home: Builder(builder: (context) => TextButton(
        onPressed: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => ReaderScreen(api: api, book: api.theBook, readListId: readListId))),
        child: const Text('open'),
      )),
    ));
    await tester.tap(find.text('open'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
  }

  Future<void> key(WidgetTester tester, LogicalKeyboardKey k) async {
    await tester.sendKeyEvent(k);
    await tester.pump();
  }

  bool focused(String label) => FocusManager.instance.primaryFocus?.debugLabel == label;

  testWidgets('remote: OK toggles controls; left/right along a bar (stopping at the ends), up/down between bars',
      (tester) async {
    await openReader(tester);
    expect(find.byTooltip('Next book'), findsNothing);

    await key(tester, LogicalKeyboardKey.enter); // OK = show
    expect(find.byTooltip('Next book'), findsOneWidget);
    expect(focused('reader-keys'), isTrue); // nothing selected yet

    await key(tester, LogicalKeyboardKey.enter); // OK with nothing selected = hide
    expect(find.byTooltip('Next book'), findsNothing);

    await key(tester, LogicalKeyboardKey.enter);
    await key(tester, LogicalKeyboardKey.arrowRight);
    expect(focused('ctl-close'), isTrue); // from nothing: Right -> start of the top bar
    await key(tester, LogicalKeyboardKey.arrowLeft);
    expect(focused('ctl-close'), isTrue); // stops at the left end
    for (var i = 0; i < 8; i++) {
      await key(tester, LogicalKeyboardKey.arrowRight);
    }
    expect(focused('ctl-delete'), isTrue); // stops at the right end
    await key(tester, LogicalKeyboardKey.arrowDown);
    expect(focused('ctl-nextBook'), isTrue); // same position in the bottom bar (5th of 5)
    await key(tester, LogicalKeyboardKey.arrowLeft);
    expect(focused('ctl-reader'), isTrue);
    await key(tester, LogicalKeyboardKey.arrowUp);
    expect(focused('ctl-read'), isTrue); // back up, same position (4th)
    await key(tester, LogicalKeyboardKey.arrowUp);
    expect(focused('reader-keys'), isTrue); // Up from the top bar = nothing selected
    await key(tester, LogicalKeyboardKey.arrowDown);
    expect(focused('ctl-prevBook'), isTrue); // from nothing: Down -> start of the bottom bar
    await key(tester, LogicalKeyboardKey.arrowDown);
    expect(focused('reader-keys'), isTrue); // Down from the bottom bar = nothing selected
    await key(tester, LogicalKeyboardKey.enter);
    expect(find.byTooltip('Next book'), findsNothing); // OK with nothing selected hides
  });

  testWidgets('remote: OK on a control presses it (fit button cycles the fit mode)', (tester) async {
    await openReader(tester);
    await key(tester, LogicalKeyboardKey.enter);
    await key(tester, LogicalKeyboardKey.arrowRight);
    await key(tester, LogicalKeyboardKey.arrowRight);
    expect(focused('ctl-fit'), isTrue);
    expect(find.byTooltip('Fit screen'), findsOneWidget);
    await key(tester, LogicalKeyboardKey.enter);
    expect(find.byTooltip('Fit width'), findsOneWidget);
    expect(AppSettings.instance.prefsFor('S1').fit, FitMode.width);
    expect(find.byTooltip('Next book'), findsOneWidget); // controls stay up
    await tester.pump(const Duration(seconds: 3)); // let the settings sync timer fire
  });

  testWidgets('back with controls up only hides them; back again closes the book', (tester) async {
    await openReader(tester);
    await key(tester, LogicalKeyboardKey.enter);
    expect(find.byTooltip('Next book'), findsOneWidget);
    await tester.binding.handlePopRoute();
    await tester.pump();
    expect(find.byTooltip('Next book'), findsNothing);
    expect(find.byType(ReaderScreen), findsOneWidget);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.byType(ReaderScreen), findsNothing);
  });

  test('tone: neutral prefs are identity; levels stretch lo..hi to 0..1', () {
    expect(Tone.of(const ReaderPrefs(), Levels.identity).isIdentity, isTrue);
    final t = Tone.of(const ReaderPrefs(), const Levels([0.1, 0.1, 0.2], [0.9, 0.9, 0.8]));
    for (var c = 0; c < 3; c++) {
      final lo = [0.1, 0.1, 0.2][c], hi = [0.9, 0.9, 0.8][c];
      expect(lo * t.scale[c] + t.offset[c], closeTo(0, 1e-9));
      expect(hi * t.scale[c] + t.offset[c], closeTo(1, 1e-9));
    }
  });

  test('brightness: top of the slider drives the backlight, the bottom adds the dim layer', () {
    expect(const DisplayPrefs().backlight, -1); // automatic
    expect(const DisplayPrefs(brightness: 1).backlight, closeTo(1, 1e-9));
    expect(const DisplayPrefs(brightness: 0.5).dimOverlay, 0);
    expect(const DisplayPrefs(brightness: 0.1).backlight, 0.01);
    expect(const DisplayPrefs(brightness: 0).dimOverlay, closeTo(0.75, 1e-9));
  });

  test('reader prefs survive the JSON round trip used for Komga sync', () {
    const p = ReaderPrefs(fit: FitMode.height, brightness: 0.1, contrast: -0.2, sharpen: true, autoLevels: true);
    expect(ReaderPrefs.fromJson(p.toJson()), p);
  });

  testWidgets('opening and closing without turning a page saves nothing', (tester) async {
    await openReader(tester);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.byType(ReaderScreen), findsNothing);
    expect(api.saves, isEmpty);
  });

  testWidgets('after a page turn, progress is saved', (tester) async {
    await openReader(tester);
    await key(tester, LogicalKeyboardKey.arrowRight);
    await tester.pump(const Duration(milliseconds: 300)); // page animation (pages spin forever, so no pumpAndSettle)
    await tester.pump(const Duration(seconds: 2)); // the 1.5 s settle timer
    expect(api.saves, [2]);
  });

  testWidgets('Next book mid-book asks; Keep in progress does not mark read', (tester) async {
    await openReader(tester);
    await key(tester, LogicalKeyboardKey.enter);
    await tester.tap(find.byTooltip('Next book'));
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('Mark #1 as read?'), findsOneWidget);
    await tester.tap(find.text('Keep in progress'));
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump(const Duration(milliseconds: 400));
    expect(api.marked, isEmpty);
    expect(api.nextCalls, 1);
    expect(find.text('End of the series'), findsOneWidget); // no next book: closes with a message
    await tester.pump(const Duration(seconds: 1)); // route exit animation
    expect(find.byType(ReaderScreen), findsNothing);
    await tester.pump(const Duration(seconds: 5)); // snackbar timer
  });

  Future<void> toEndCard(WidgetTester tester) async {
    for (var i = 0; i < 3; i++) { // 3 pages, then the end card
      await key(tester, LogicalKeyboardKey.arrowRight);
      await tester.pump(const Duration(milliseconds: 400));
    }
    await tester.pump();
  }

  final second = {'id': 'B2', 'seriesTitle': 'Test', 'metadata': {'number': '2', 'title': 'The Second One'}};

  testWidgets('end card: shows the next book in the series - title and poster', (tester) async {
    await openReader(tester, next: second);
    await toEndCard(tester);
    expect(find.text('Up next in the series'), findsOneWidget);
    expect(find.text('Test #2'), findsOneWidget);
    expect(find.text('The Second One'), findsOneWidget);
    expect(find.byType(Image), findsOneWidget); // its poster
    expect(api.askedReadList, isNull); // opened outside a read list: the series
    await tester.pump(const Duration(seconds: 2));
  });

  testWidgets('end card: opened from a read list, the next book comes from the read list', (tester) async {
    await openReader(tester, readListId: 'RL1', next: second);
    await toEndCard(tester);
    expect(find.text('Up next in this read list'), findsOneWidget);
    expect(api.askedReadList, 'RL1');
    await tester.pump(const Duration(seconds: 2));
  });

  testWidgets('end card: the last book says so', (tester) async {
    await openReader(tester);
    await toEndCard(tester);
    expect(find.text('End of the series'), findsOneWidget);
    expect(find.text('→ : close the book'), findsOneWidget);
    await tester.pump(const Duration(seconds: 2));
  });

  test('series status text counts unread and in-progress books separately', () {
    expect(seriesStatus({'booksCount': 12, 'booksUnreadCount': 0, 'booksInProgressCount': 0}), '12 books · read');
    expect(seriesStatus({'booksCount': 12, 'booksUnreadCount': 0, 'booksInProgressCount': 2}), '12 books · 2 in progress');
    expect(seriesStatus({'booksCount': 12, 'booksUnreadCount': 3, 'booksInProgressCount': 1}),
        '12 books · 3 unread · 1 in progress');
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

  test('build-4 sharpen slider values load as the new on/off switch', () {
    expect(ReaderPrefs.fromJson({'s': 0.4}).sharpen, isTrue);
    expect(ReaderPrefs.fromJson({'s': 0}).sharpen, isFalse);
  });

  for (final size in const [Size(800, 1280), Size(1280, 800), Size(400, 860), Size(860, 400)]) {
    testWidgets('reader controls fit on ${size.width.toInt()}x${size.height.toInt()} without overflow', (tester) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await openReader(tester);
      await key(tester, LogicalKeyboardKey.enter);
      expect(find.text('Close'), findsOneWidget);
      expect(find.byTooltip('Previous book'), findsOneWidget);
      expect(tester.takeException(), isNull); // a RenderFlex overflow would surface here
    });
  }

  testWidgets('previous book at the start of the series says so and stays', (tester) async {
    await openReader(tester);
    await key(tester, LogicalKeyboardKey.enter);
    await tester.tap(find.byTooltip('Previous book'));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('This is the first book of the series'), findsOneWidget);
    expect(find.byType(ReaderScreen), findsOneWidget);
    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets('desktop: one mouse-wheel notch turns one page', (tester) async {
    await openReader(tester);
    final centre = tester.getCenter(find.byType(ReaderScreen));
    final mouse = TestPointer(1, PointerDeviceKind.mouse);
    await tester.sendEventToBinding(mouse.hover(centre));
    await tester.sendEventToBinding(mouse.scroll(const Offset(0, 100)));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400)); // page animation
    expect(tester.widget<PageView>(find.byType(PageView)).controller!.page, 1.0);
    await tester.pump(const Duration(seconds: 2)); // progress save after the page settles
    expect(api.saves, [2]);
  });

  testWidgets('desktop: F11 toggles full screen, and the top bar gets a full-screen button', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    final calls = <bool>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(const MethodChannel('komga_reader/screen'), (call) async {
      if (call.method == 'fullscreen') {
        calls.add(call.arguments as bool);
        return call.arguments;
      }
      return null;
    });
    await openReader(tester);
    await key(tester, LogicalKeyboardKey.f11);
    await tester.pump();
    expect(calls, [true]);
    await key(tester, LogicalKeyboardKey.enter); // controls
    expect(find.byTooltip('Leave full screen (F11)'), findsOneWidget);
    await key(tester, LogicalKeyboardKey.escape); // hides the controls first
    await key(tester, LogicalKeyboardKey.escape); // then closes the book, which also leaves full screen
    await tester.pump(const Duration(seconds: 1));
    expect(find.byType(ReaderScreen), findsNothing);
    expect(calls, [true, false]);
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(const MethodChannel('komga_reader/screen'), null);
    debugDefaultTargetPlatformOverride = null;
  });

  test('desktop brightness: the slider only dims (no backlight)', () {
    DisplayPrefs.backlightControl = false;
    expect(const DisplayPrefs(brightness: 1).dimOverlay, 0);
    expect(const DisplayPrefs(brightness: 0.5).dimOverlay, closeTo(0.375, 1e-9));
    expect(const DisplayPrefs(brightness: 0.5).backlight, -1); // never touches the backlight
    DisplayPrefs.backlightControl = true;
  });

  testWidgets('page turn: Straight flip cuts to the next page with no slide', (tester) async {
    AppSettings.instance.setDisplay(AppSettings.instance.display.copyWith(pageTurn: PageTurn.flip));
    addTearDown(() => AppSettings.instance.setDisplay(AppSettings.instance.display.copyWith(pageTurn: PageTurn.swipe)));
    await openReader(tester);
    await key(tester, LogicalKeyboardKey.arrowRight);
    expect(tester.widget<PageView>(find.byType(PageView)).controller!.page, 1.0); // already there, same frame
  });

  testWidgets('page turn: Swipe slides (half-way through after a few frames)', (tester) async {
    await openReader(tester);
    await key(tester, LogicalKeyboardKey.arrowRight);
    await tester.pump(const Duration(milliseconds: 60));
    final page = tester.widget<PageView>(find.byType(PageView)).controller!.page!;
    expect(page > 0 && page < 1, isTrue);
    await tester.pump(const Duration(seconds: 3));
  });

  test('page-turn choice survives the device settings round trip; older settings default to Swipe', () {
    expect(DisplayPrefs.fromJson(const DisplayPrefs(pageTurn: PageTurn.flip).toJson()).pageTurn, PageTurn.flip);
    expect(DisplayPrefs.fromJson({'night': true}).pageTurn, PageTurn.swipe);
  });

  group('right to left', () {
    setUp(() => FakeKomga.direction = 'RIGHT_TO_LEFT');
    tearDown(() {
      FakeKomga.direction = 'LEFT_TO_RIGHT';
      AppSettings.instance.series.remove('S1');
    });

    double page(WidgetTester tester) => tester.widget<PageView>(find.byType(PageView)).controller!.page!;

    testWidgets('Komga says right to left: pages run backwards, Left goes forward, Right goes back', (tester) async {
      await openReader(tester);
      expect(tester.widget<PageView>(find.byType(PageView)).reverse, isTrue);
      await key(tester, LogicalKeyboardKey.arrowLeft);
      await tester.pump(const Duration(milliseconds: 400));
      expect(page(tester), 1.0);
      await key(tester, LogicalKeyboardKey.arrowRight);
      await tester.pump(const Duration(milliseconds: 400));
      expect(page(tester), 0.0);
      await key(tester, LogicalKeyboardKey.arrowDown); // Down has no direction: still forward
      await tester.pump(const Duration(milliseconds: 400));
      expect(page(tester), 1.0);
      await tester.pump(const Duration(seconds: 2));
    });

    testWidgets('tap zones flip: the left third goes forward', (tester) async {
      await openReader(tester);
      final box = tester.getRect(find.byType(PageView));
      await tester.tapAt(Offset(box.left + box.width * 0.1, box.center.dy));
      await tester.pump(); // the page animation starts on the next frame
      await tester.pump(const Duration(milliseconds: 600));
      expect(page(tester), 1.0);
      await tester.pump(const Duration(seconds: 2));
    });

    testWidgets('a per-series "Left to right" overrides Komga', (tester) async {
      AppSettings.instance.series['S1'] = const ReaderPrefs(direction: ReadingDirection.ltr);
      await openReader(tester);
      expect(tester.widget<PageView>(find.byType(PageView)).reverse, isFalse);
      await key(tester, LogicalKeyboardKey.arrowRight);
      await tester.pump(const Duration(milliseconds: 400));
      expect(page(tester), 1.0);
      await tester.pump(const Duration(seconds: 2));
    });
  });

  testWidgets('a per-series "Right to left" works even when Komga says left to right', (tester) async {
    AppSettings.instance.series['S1'] = const ReaderPrefs(direction: ReadingDirection.rtl);
    addTearDown(() => AppSettings.instance.series.remove('S1'));
    await openReader(tester);
    expect(tester.widget<PageView>(find.byType(PageView)).reverse, isTrue);
  });

  test('reading direction survives the settings round trip; older settings are Auto', () {
    expect(ReaderPrefs.fromJson(const ReaderPrefs(direction: ReadingDirection.rtl).toJson()).direction, ReadingDirection.rtl);
    expect(ReaderPrefs.fromJson({'fit': 'width'}).direction, ReadingDirection.auto);
    expect(const ReaderPrefs(direction: ReadingDirection.rtl, contrast: 0.2).imageReset().direction, ReadingDirection.rtl);
  });
}

