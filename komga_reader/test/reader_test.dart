import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:komga_reader/api.dart';
import 'package:komga_reader/offline/offline_komga.dart' show NotAvailableOffline;
import 'package:komga_reader/page_curl.dart';
import 'package:komga_reader/page_image.dart';
import 'package:komga_reader/screens/library.dart';
import 'package:komga_reader/screen.dart';
import 'package:komga_reader/screens/reader.dart';
import 'package:komga_reader/settings.dart';
import 'package:komga_reader/widgets/reader_clock.dart';
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
  Future<void> setProgress(String bookId, int page, {bool completed = false}) async {
    saves.add(page);
    if (completed) finished.add(page);
  }

  final finished = <int>[]; // saves that marked the book read
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

/// [FakeKomga] whose next book (B2) has a cover page to fetch.
class CoverKomga extends FakeKomga {
  static late Uint8List cover;
  final coverAsked = <String>[];
  @override
  Future<Uint8List> pageBytes(String bookId, int number) {
    if (bookId != 'B2' || number != 1) return super.pageBytes(bookId, number);
    coverAsked.add(bookId);
    return Future.value(cover);
  }
}

/// [FakeKomga] with Komga gone mid-book (pages fail), or before the book opened ([bookDown]).
class DownKomga extends FakeKomga {
  bool bookDown = false;
  @override
  Future<Map<String, dynamic>?> book(String id) async =>
      bookDown ? throw KomgaUnreachable('http://192.168.1.10:25600') : theBook;
  @override
  Future<Uint8List> pageBytes(String bookId, int number) async => throw KomgaUnreachable('http://192.168.1.10:25600');
}

/// [FakeKomga] offline, with the next book not downloaded.
class NotDownloadedKomga extends FakeKomga {
  @override
  Future<Map<String, dynamic>?> nextBook(String bookId, {String? readListId}) async =>
      throw NotAvailableOffline('The next book');
}

/// [FakeKomga] with a series B1, B2 (already read), B3 (not read).
class ChainKomga extends FakeKomga {
  static Map<String, dynamic> b(String id, String n, {bool read = false}) => {
        'id': id, 'seriesTitle': 'Test', 'metadata': {'number': n, 'title': 'Book $n'},
        'readProgress': read ? {'page': 3, 'completed': true} : null,
      };
  @override
  Future<Map<String, dynamic>?> nextBook(String bookId, {String? readListId}) async {
    nextCalls++;
    return switch (bookId) { 'B1' => b('B2', '2', read: true), 'B2' => b('B3', '3'), _ => null };
  }
}

/// [FakeKomga] with B0 (not read) and BR (read) before B1: previous of B1 is BR, previous of BR is B0.
class BackChainKomga extends FakeKomga {
  final opened = <String>[];
  @override
  Future<Map<String, dynamic>?> previousBook(String bookId, {String? readListId}) async => switch (bookId) {
        'B1' => ChainKomga.b('BR', '0.5', read: true),
        'BR' => ChainKomga.b('B0', '0'),
        _ => null,
      };
  @override
  Future<Map<String, dynamic>?> book(String id) async {
    opened.add(id);
    return id == 'B1' ? theBook : ChainKomga.b(id, id);
  }
}

/// [FakeKomga] whose pages load (a small picture), with page thumbnails for the slider previews.
class ImageKomga extends FakeKomga {
  static late Uint8List png;
  final thumbsAsked = <int>[];
  @override
  Future<Uint8List> pageBytes(String bookId, int number) async => png;
  @override
  Future<Uint8List> pageThumbBytes(String bookId, int number) async {
    thumbsAsked.add(number);
    return png;
  }
}

void main() {
  // the reader starts loading the curl shader when it opens; load it once for real first, or that load starts inside
  // a test's fake clock, never finishes, and the curl tests wait on it forever
  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    await PageCurl.program();
  });
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

  testWidgets("end card: the next book's cover page replaces the (small, blurry) thumbnail once it's in",
      (tester) async {
    late Uint8List png;
    await tester.runAsync(() async {
      final rec = ui.PictureRecorder();
      Canvas(rec).drawRect(const Rect.fromLTWH(0, 0, 20, 30), Paint()..color = const Color(0xFF3060A0));
      final img = await rec.endRecording().toImage(20, 30);
      png = (await img.toByteData(format: ui.ImageByteFormat.png))!.buffer.asUint8List();
    });
    CoverKomga.cover = png;
    api = CoverKomga()..next = second;
    await tester.pumpWidget(MaterialApp(home: ReaderScreen(api: api, book: api.theBook)));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    await toEndCard(tester);
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
    await tester.pump();
    expect((api as CoverKomga).coverAsked, ['B2']); // page 1 of the next book - once
    final images = tester.widgetList<Image>(find.byType(Image)).toList();
    expect(images.length, 2); // the thumbnail underneath, the cover over it
    expect(images.last.image, isA<ResizeImage>()); // decoded at about the size shown
    expect((images.last.image as ResizeImage).imageProvider, isA<MemoryImage>());
    await tester.pump(const Duration(seconds: 2));
  });

  testWidgets("end card offline: the next book isn't downloaded - it says so, no poster, and → closes the book",
      (tester) async {
    api = NotDownloadedKomga();
    await tester.pumpWidget(MaterialApp(home: Builder(builder: (context) => TextButton(
      onPressed: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => ReaderScreen(api: api, book: api.theBook))),
      child: const Text('open'),
    ))));
    await tester.tap(find.text('open'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    await toEndCard(tester);
    expect(find.text("The next book in the series isn't downloaded"), findsOneWidget);
    expect(find.byType(Image), findsNothing);
    await key(tester, LogicalKeyboardKey.arrowRight);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.byType(ReaderScreen), findsNothing); // closed
    expect(api.marked, ['B1']); // and this one is read
    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets("a page that won't load says why, with Retry and Details (user's mock-up)", (tester) async {
    api = DownKomga();
    await tester.pumpWidget(MaterialApp(home: ReaderScreen(api: api, book: api.theBook)));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.text("This page didn't load: can't reach Komga."), findsOneWidget);
    expect(find.text('Retry'), findsOneWidget);
    expect(find.text('Details'), findsOneWidget);
    await tester.pump(const Duration(seconds: 3));
  });

  testWidgets("a book that won't open says so on the screen, with Retry and Close", (tester) async {
    api = DownKomga()..bookDown = true;
    await tester.pumpWidget(MaterialApp(home: ReaderScreen(api: api, book: api.theBook)));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.text('Couldn\'t open "Test #1": can\'t reach Komga.'), findsOneWidget);
    expect(find.text('Retry'), findsOneWidget);
    expect(find.text('Close'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsNothing); // not a spinner forever
    await tester.pump(const Duration(seconds: 3));
  });

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

  testWidgets('closing from the end card marks the book read, even straight after the last page', (tester) async {
    await openReader(tester);
    await toEndCard(tester); // 400 ms per turn: the last page's 1.5 s save never ran
    expect(api.finished, isEmpty);
    await key(tester, LogicalKeyboardKey.escape); // close
    await tester.pump(const Duration(seconds: 1));
    expect(find.byType(ReaderScreen), findsNothing);
    expect(api.finished, [3]); // page 3 of 3, read
  });

  double flashOpacity(WidgetTester tester, String text) => tester
      .widget<AnimatedOpacity>(find.ancestor(of: find.text(text), matching: find.byType(AnimatedOpacity)).first)
      .opacity;

  testWidgets('page number: "2 / 3" shows for a moment after a turn, then fades', (tester) async {
    await openReader(tester);
    await key(tester, LogicalKeyboardKey.arrowRight);
    await tester.pump(const Duration(milliseconds: 300));
    expect(flashOpacity(tester, '2 / 3'), 1.0);
    final at = tester.getRect(find.text('2 / 3')), screen = tester.getRect(find.byType(ReaderScreen));
    expect(at.left - screen.left, lessThan(60)); // bottom left (user, 2026-09-30)
    expect(screen.bottom - at.bottom, lessThan(60));
    await tester.pump(const Duration(seconds: 2));
    expect(flashOpacity(tester, '2 / 3'), 0.0);
  });

  testWidgets('page number: switched off, it stays hidden', (tester) async {
    final s = AppSettings.instance;
    s.setDisplay(s.display.copyWith(pageNumber: false));
    addTearDown(() => s.setDisplay(s.display.copyWith(pageNumber: true)));
    await openReader(tester);
    await key(tester, LogicalKeyboardKey.arrowRight);
    await tester.pump(const Duration(milliseconds: 300));
    expect(flashOpacity(tester, '2 / 3'), 0.0);
    await tester.pump(const Duration(seconds: 2));
  });

  testWidgets('opened with read books hidden, the next book skips read ones; otherwise it is simply the next',
      (tester) async {
    for (final skip in [true, false]) {
      api = ChainKomga();
      await tester.pumpWidget(MaterialApp(home: ReaderScreen(api: api, book: api.theBook, skipRead: skip)));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      await toEndCard(tester);
      await tester.pump();
      if (skip) {
        expect(find.text('Next unread in the series'), findsOneWidget);
        expect(find.text('Test #3'), findsOneWidget); // #2 is read: skipped
      } else {
        expect(find.text('Up next in the series'), findsOneWidget);
        expect(find.text('Test #2'), findsOneWidget); // read or not, the next in order
      }
      await tester.pump(const Duration(seconds: 2));
      await tester.pumpWidget(const SizedBox());
    }
  });

  testWidgets('previous book: with read books hidden it skips read ones too; otherwise the one before', (tester) async {
    for (final skip in [true, false]) {
      final api = BackChainKomga();
      await tester.pumpWidget(MaterialApp(home: ReaderScreen(api: api, book: api.theBook, skipRead: skip)));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      await key(tester, LogicalKeyboardKey.enter);
      await tester.tap(find.byTooltip('Previous book'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      expect(api.opened.last, skip ? 'B0' : 'BR', reason: 'skipRead: $skip');
      await tester.pump(const Duration(seconds: 2));
      await tester.pumpWidget(const SizedBox());
    }
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

  testWidgets('desktop: full screen is app-wide - the button toggles it, Esc closes the book and it stays on',
      (tester) async {
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
    await key(tester, LogicalKeyboardKey.enter); // controls
    await tester.tap(find.byTooltip('Full screen (F11)'));
    await tester.pump();
    await tester.pump();
    expect(calls, [true]);
    expect(fullscreen.value, isTrue);
    expect((await SharedPreferences.getInstance()).getBool('desktop.fullscreen'), isTrue); // remembered
    expect(find.byTooltip('Leave full screen (F11)'), findsOneWidget);
    await key(tester, LogicalKeyboardKey.escape); // hides the controls first
    await key(tester, LogicalKeyboardKey.escape); // then closes the book - full screen stays (user)
    await tester.pump(const Duration(seconds: 1));
    expect(find.byType(ReaderScreen), findsNothing);
    expect(calls, [true]);
    expect(fullscreen.value, isTrue);
    await tester.tap(find.text('open')); // the next book opens in full screen
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    await key(tester, LogicalKeyboardKey.enter);
    expect(find.byTooltip('Leave full screen (F11)'), findsOneWidget);
    fullscreen.value = false;
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

  testWidgets('page turn animation: Instant flip cuts to the next page with no slide', (tester) async {
    AppSettings.instance.setDisplay(AppSettings.instance.display.copyWith(pageTurn: PageTurn.flip));
    addTearDown(() => AppSettings.instance.setDisplay(AppSettings.instance.display.copyWith(pageTurn: PageTurn.swipe)));
    await openReader(tester);
    await key(tester, LogicalKeyboardKey.arrowRight);
    expect(tester.widget<PageView>(find.byType(PageView)).controller!.page, 1.0); // already there, same frame
  });

  for (final turn in PageTurn.values) {
    testWidgets('page turn ${turn.name}: only the look differs - tap, swipe and arrows all turn', (tester) async {
      AppSettings.instance.setDisplay(AppSettings.instance.display.copyWith(pageTurn: turn));
      addTearDown(() => AppSettings.instance.setDisplay(AppSettings.instance.display.copyWith(pageTurn: PageTurn.swipe)));
      await openReader(tester);
      double page() => tester.widget<PageView>(find.byType(PageView)).controller!.page!;
      final size = tester.getSize(find.byType(PageView));
      Future<void> settle() async { for (var i = 0; i < 40; i++) { await tester.pump(const Duration(milliseconds: 50)); } }

      await tester.tapAt(Offset(size.width * 0.9, size.height / 2)); // right side: forward
      await settle();
      expect(page(), 1.0, reason: 'tap');
      await tester.fling(find.byType(PageView), Offset(-size.width * 0.6, 0), 1500); // swipe: forward
      await settle();
      expect(page(), 2.0, reason: 'swipe after a tap');
      await key(tester, LogicalKeyboardKey.arrowLeft); // back
      await settle();
      expect(page(), 1.0, reason: 'arrow');
      await tester.fling(find.byType(PageView), Offset(size.width * 0.6, 0), 1500); // swipe: back
      await settle();
      expect(page(), 0.0, reason: 'swipe after an arrow');
      await tester.pump(const Duration(seconds: 2));
    });
  }

  group('3D page curl', () {
    setUp(() => AppSettings.instance.setDisplay(AppSettings.instance.display.copyWith(pageTurn: PageTurn.curl)));
    tearDown(() => AppSettings.instance.setDisplay(AppSettings.instance.display.copyWith(pageTurn: PageTurn.swipe)));

    Future<void> openCurling(WidgetTester tester) async {
      expect(PageCurl.loaded, isNotNull); // loaded for real in setUpAll
      await openReader(tester);
      await tester.pump();
    }

    double page(WidgetTester tester) => tester.widget<PageView>(find.byType(PageView)).controller!.page!;
    Finder curling() => find.byWidgetPredicate((w) => w is CustomPaint && w.painter is PageCurlPainter);

    testWidgets('a tap plays the curl and lands on the next page', (tester) async {
      await openCurling(tester);
      final size = tester.getSize(find.byType(PageView));
      await tester.tapAt(Offset(size.width * 0.9, size.height / 2));
      await tester.pump();
      expect(curling(), findsOneWidget); // this page curling away over the next
      expect(page(tester), 1.0); // the next page is already underneath
      await tester.pump(const Duration(milliseconds: 500));
      await tester.pump();
      expect(curling(), findsNothing);
      expect(page(tester), 1.0);
      await tester.pump(const Duration(seconds: 2));
    });

    testWidgets('a slow drag past halfway turns the page; a short one springs back', (tester) async {
      await openCurling(tester);
      final size = tester.getSize(find.byType(PageView));
      final y = size.height / 2;
      // short and slow: back where it was
      var g = await tester.startGesture(Offset(size.width * 0.8, y));
      for (var i = 1; i <= 10; i++) {
        await g.moveTo(Offset(size.width * 0.8 - i * 8.0, y));
        await tester.pump(const Duration(milliseconds: 50));
      }
      expect(curling(), findsOneWidget); // the page follows the finger
      await g.up();
      await tester.pump(); // the spring-back / finishing animation starts counting from this frame
      await tester.pump(const Duration(milliseconds: 500));
      await tester.pump();
      expect(curling(), findsNothing);
      expect(page(tester), 0.0);
      // long and slow: turned
      g = await tester.startGesture(Offset(size.width * 0.9, y));
      for (var i = 1; i <= 20; i++) {
        await g.moveTo(Offset(size.width * 0.9 - i * size.width * 0.04, y));
        await tester.pump(const Duration(milliseconds: 50));
      }
      await g.up();
      await tester.pump(); // the spring-back / finishing animation starts counting from this frame
      await tester.pump(const Duration(milliseconds: 500));
      await tester.pump();
      expect(page(tester), 1.0);
      await tester.pump(const Duration(seconds: 2));
    });

    testWidgets('a slow drag started mid-screen turns the page (grab anywhere)', (tester) async {
      await openCurling(tester);
      final size = tester.getSize(find.byType(PageView));
      final y = size.height * 0.4;
      final g = await tester.startGesture(Offset(size.width * 0.5, y)); // the middle, not the edge
      for (var i = 1; i <= 16; i++) {
        await g.moveTo(Offset(size.width * 0.5 - i * size.width * 0.025, y)); // to 10% from the left edge
        await tester.pump(const Duration(milliseconds: 60));
      }
      await g.up();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      await tester.pump();
      expect(page(tester), 1.0);
      await tester.pump(const Duration(seconds: 2));
    });

    test('the spine stays down: a steep diagonal is held so neither spine corner lifts', () {
      const w = 600.0, h = 900.0;
      final r = PageCurl.radius(w);
      const grab = Offset(w, h * 0.5);
      double lift(Offset finger, Offset corner) {
        final (p, n) = PageCurl.fold(grab, finger, r)!;
        return (corner - p).dx * n.dx + (corner - p).dy * n.dy;
      }

      const steep = Offset(w * 0.3, h * 1.4); // halfway across, pulled far down
      expect(lift(steep, Offset.zero), greaterThan(0)); // unheld, the top of the spine peels up
      final held = PageCurl.pinned(grab, steep, r, h);
      expect(held.dx, steep.dx); // the turn's progress is untouched
      expect(held.dy, inInclusiveRange(grab.dy, steep.dy)); // only the tilt is reduced
      for (final corner in [Offset.zero, const Offset(0, h)]) {
        expect(lift(held, corner), lessThanOrEqualTo(0.5));
      }
      const gentle = Offset(w * 0.6, h * 0.55);
      expect(PageCurl.pinned(grab, gentle, r, h), gentle); // a slight tilt is left alone
    });

    testWidgets('a diagonal drag turns the page', (tester) async {
      await openCurling(tester);
      final size = tester.getSize(find.byType(PageView));
      final start = Offset(size.width * 0.85, size.height * 0.7);
      final g = await tester.startGesture(start);
      for (var i = 1; i <= 12; i++) {
        await g.moveTo(start + Offset(-i * size.width * 0.04, -i * size.height * 0.035)); // up and to the left
        await tester.pump(const Duration(milliseconds: 40));
      }
      await g.up();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      await tester.pump();
      expect(page(tester), 1.0);
      await tester.pump(const Duration(seconds: 2));
    });

    testWidgets('two quick swipes turn two pages (the second is not lost to the first one still playing)',
        (tester) async {
      await openCurling(tester);
      final size = tester.getSize(find.byType(PageView));
      await tester.flingFrom(Offset(size.width * 0.8, size.height / 2), Offset(-size.width * 0.5, 0), 1500);
      await tester.pump(const Duration(milliseconds: 100)); // first turn mid-way
      await tester.flingFrom(Offset(size.width * 0.8, size.height / 2), Offset(-size.width * 0.5, 0), 1500);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      await tester.pump();
      expect(page(tester), 2.0);
      await tester.pump(const Duration(seconds: 2));
    });

    testWidgets('back: the previous page uncurls over this one', (tester) async {
      await openCurling(tester);
      await key(tester, LogicalKeyboardKey.arrowRight);
      await tester.pump(const Duration(milliseconds: 500));
      await tester.pump();
      expect(page(tester), 1.0);
      await key(tester, LogicalKeyboardKey.arrowLeft);
      await tester.pump(); // the previous page's snapshot is taken after this frame
      await tester.pump();
      expect(curling(), findsOneWidget);
      expect(page(tester), 0.0);
      await tester.pump(const Duration(milliseconds: 500));
      await tester.pump();
      expect(curling(), findsNothing);
      expect(page(tester), 0.0);
      await tester.pump(const Duration(seconds: 2));
    });
  });

  testWidgets('every page turn mode keeps the neighbouring pages built (processed before they are turned to)',
      (tester) async {
    for (final turn in PageTurn.values) {
      AppSettings.instance.setDisplay(AppSettings.instance.display.copyWith(pageTurn: turn));
      await openReader(tester);
      expect(tester.widget<PageView>(find.byType(PageView)).allowImplicitScrolling, isTrue, reason: turn.name);
      await tester.pumpWidget(const SizedBox());
    }
    AppSettings.instance.setDisplay(AppSettings.instance.display.copyWith(pageTurn: PageTurn.swipe));
    await tester.pump(const Duration(seconds: 3));
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

  group('with pages that load', () {
    Future<void> openLoaded(WidgetTester tester) async {
      await tester.runAsync(() async {
        final rec = ui.PictureRecorder();
        Canvas(rec).drawRect(const Rect.fromLTWH(0, 0, 200, 300), Paint()..color = const Color(0xFFE0D0B0));
        final img = await rec.endRecording().toImage(200, 300);
        ImageKomga.png = (await img.toByteData(format: ui.ImageByteFormat.png))!.buffer.asUint8List();
      });
      api = ImageKomga();
      await tester.pumpWidget(MaterialApp(home: ReaderScreen(api: api, book: api.theBook)));
      await tester.pump();
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100))); // pages decode for real
      await tester.pump();
      expect(find.byType(PageCanvas), findsWidgets);
    }

    double page(WidgetTester tester) => tester.widget<PageView>(find.byType(PageView)).controller!.page!;
    double scale(WidgetTester tester) =>
        tester.widget<InteractiveViewer>(find.byType(InteractiveViewer).first).transformationController!.value
            .getMaxScaleOnAxis();

    testWidgets('double-tap zooms in on the spot, again zooms back out - no controls, no page turn', (tester) async {
      await openLoaded(tester);
      final c = tester.getCenter(find.byType(PageView));
      Future<void> doubleTap() async {
        await tester.tapAt(c);
        await tester.pump(const Duration(milliseconds: 80));
        await tester.tapAt(c);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 400));
      }

      await doubleTap();
      expect(scale(tester), closeTo(2, 1e-6));
      expect(find.byTooltip('Next book'), findsNothing); // the middle taps didn't show the controls
      await doubleTap();
      expect(scale(tester), closeTo(1, 1e-6));
      expect(page(tester), 0.0);
      await tester.pump(const Duration(seconds: 2));
    });

    testWidgets('double-tap on: a single tap turns after a short wait; switched off: at once', (tester) async {
      await openLoaded(tester);
      final size = tester.getSize(find.byType(PageView));
      final right = Offset(size.width * 0.9, size.height / 2);
      await tester.tapAt(right);
      await tester.pump(const Duration(milliseconds: 100));
      expect(page(tester), 0.0); // still waiting for a possible second tap
      await tester.pump(const Duration(milliseconds: 200)); // the wait is over: the turn starts
      await tester.pump(const Duration(milliseconds: 400));
      expect(page(tester), 1.0);

      final s = AppSettings.instance;
      s.setDisplay(s.display.copyWith(doubleTapZoom: false));
      addTearDown(() => s.setDisplay(s.display.copyWith(doubleTapZoom: true)));
      await tester.tapAt(right);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 60));
      expect(page(tester), greaterThan(1.0)); // already sliding
      await tester.pump(const Duration(seconds: 2));
    });

    testWidgets('slider: picking a page shows its preview over the thumb; letting go jumps there', (tester) async {
      await openLoaded(tester);
      await key(tester, LogicalKeyboardKey.enter); // controls
      const preview = ValueKey('page-preview');
      expect(find.byKey(preview), findsNothing);
      final r = tester.getRect(find.byType(Slider));
      final g = await tester.startGesture(Offset(r.left + 20, r.center.dy)); // the thumb, on page 1
      await g.moveTo(Offset(r.left + 60, r.center.dy));
      await g.moveTo(Offset(r.right - 20, r.center.dy)); // the last page
      await tester.pump();
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50))); // the picture decodes
      await tester.pump();
      expect(find.byKey(preview), findsOneWidget);
      expect(find.text('Page 3'), findsOneWidget);
      expect((api as ImageKomga).thumbsAsked, contains(3));
      final p = tester.getRect(find.byKey(preview));
      expect(p.center.dx, closeTo(r.right - 20, 1)); // over the thumb
      expect(p.bottom, lessThan(r.top)); // above the bar, over the page
      expect(find.descendant(of: find.byKey(preview), matching: find.byType(Image)), findsOneWidget);
      await g.up();
      await tester.pump();
      expect(find.byKey(preview), findsNothing);
      expect(page(tester), 2.0);
      await tester.pump(const Duration(seconds: 2));
    });
  });

  testWidgets('Android: volume down turns forward, up back; switched off, or on a PC, they stay volume keys',
      (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    final s = AppSettings.instance;
    try {
      await openReader(tester);
      double page() => tester.widget<PageView>(find.byType(PageView)).controller!.page!;
      Future<void> turn() async {
        await tester.pump(); // the page animation starts on the next frame
        await tester.pump(const Duration(milliseconds: 400));
      }

      expect(await tester.sendKeyEvent(LogicalKeyboardKey.audioVolumeDown), isTrue); // used: no volume change
      await turn();
      expect(page(), 1.0);
      await tester.sendKeyEvent(LogicalKeyboardKey.audioVolumeUp);
      await turn();
      expect(page(), 0.0);

      s.setDisplay(s.display.copyWith(volumeKeys: false));
      expect(await tester.sendKeyEvent(LogicalKeyboardKey.audioVolumeDown), isFalse); // left to the system
      await turn();
      expect(page(), 0.0);

      s.setDisplay(s.display.copyWith(volumeKeys: true));
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      expect(await tester.sendKeyEvent(LogicalKeyboardKey.audioVolumeDown), isFalse);
      await tester.pump(const Duration(seconds: 2));
    } finally {
      s.setDisplay(s.display.copyWith(volumeKeys: true));
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets('Next book before the last page, set to Mark read or Keep in progress: no question asked',
      (tester) async {
    final s = AppSettings.instance;
    addTearDown(() => s.setDisplay(s.display.copyWith(midBook: MidBook.ask)));
    for (final m in [MidBook.markRead, MidBook.keep]) {
      s.setDisplay(s.display.copyWith(midBook: m));
      await openReader(tester);
      await key(tester, LogicalKeyboardKey.enter);
      await tester.tap(find.byTooltip('Next book'));
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.text('Mark #1 as read?'), findsNothing, reason: m.name);
      expect(api.marked, m == MidBook.markRead ? ['B1'] : isEmpty, reason: m.name);
      expect(api.nextCalls, 1, reason: m.name);
      await tester.pump(const Duration(seconds: 5)); // the "End of the series" snackbar
      await tester.pumpWidget(const SizedBox());
    }
  });

  testWidgets('background: White makes the reader white, with dark text on the end card', (tester) async {
    final s = AppSettings.instance;
    s.setDisplay(s.display.copyWith(background: ReaderBackground.white));
    addTearDown(() => s.setDisplay(s.display.copyWith(background: ReaderBackground.black)));
    await openReader(tester);
    expect(tester.widget<Scaffold>(find.byType(Scaffold).last).backgroundColor, const Color(0xFFFFFFFF));
    await toEndCard(tester);
    expect(tester.widget<Text>(find.text('End of book')).style!.color!.computeLuminance(), lessThan(0.2));
    await tester.pump(const Duration(seconds: 2));
  });

  testWidgets('keep the screen on: for the chosen minutes after the last turn; Off never holds it', (tester) async {
    final calls = <bool>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(const MethodChannel('komga_reader/screen'), (call) async {
      if (call.method == 'keepOn') calls.add(call.arguments as bool);
      return null;
    });
    final s = AppSettings.instance;
    addTearDown(() {
      s.setDisplay(s.display.copyWith(screenOn: 0));
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(const MethodChannel('komga_reader/screen'), null);
    });
    s.setDisplay(s.display.copyWith(screenOn: 5));
    await openReader(tester);
    expect(calls, [true]);
    await tester.pump(const Duration(minutes: 4));
    await key(tester, LogicalKeyboardKey.arrowRight); // a turn: five more minutes
    await tester.pump(const Duration(milliseconds: 400)); // the turn finishes now, not in the next 4-minute frame
    await tester.pump(const Duration(minutes: 4));
    expect(calls, [true]);
    await tester.pump(const Duration(minutes: 2));
    await tester.pump();
    expect(calls, [true, false]); // the device's own timeout takes over
    await key(tester, LogicalKeyboardKey.arrowRight);
    expect(calls, [true, false, true]); // held again
    await tester.pumpWidget(const SizedBox());
    expect(calls.last, isFalse); // closing lets go

    calls.clear();
    s.setDisplay(s.display.copyWith(screenOn: 0));
    await openReader(tester);
    await tester.pump(const Duration(seconds: 2));
    await tester.pumpWidget(const SizedBox());
    expect(calls, isEmpty); // Off: never held
  });

  testWidgets('clock and battery: Always shows it over the page; With the controls only on the top bar; Off never',
      (tester) async {
    final s = AppSettings.instance;
    addTearDown(() => s.setDisplay(s.display.copyWith(clock: ShowWhen.withControls)));
    for (final when in ShowWhen.values) {
      s.setDisplay(s.display.copyWith(clock: when));
      await openReader(tester);
      expect(find.byType(ReaderClock), when == ShowWhen.always ? findsOneWidget : findsNothing, reason: '${when.name}, hidden');
      await key(tester, LogicalKeyboardKey.enter); // the controls
      expect(find.byType(ReaderClock), when == ShowWhen.off ? findsNothing : findsOneWidget, reason: '${when.name}, controls');
      await tester.pumpWidget(const SizedBox());
    }
  });

  testWidgets('progress bar: a line along the bottom while the controls are hidden; the slider takes over with them',
      (tester) async {
    final s = AppSettings.instance;
    s.setDisplay(s.display.copyWith(progressBar: true));
    addTearDown(() => s.setDisplay(s.display.copyWith(progressBar: false)));
    await openReader(tester);
    const bar = ValueKey('reading-progress');
    expect(tester.widget<LinearProgressIndicator>(find.byKey(bar)).value, closeTo(1 / 3, 1e-9)); // page 1 of 3
    await key(tester, LogicalKeyboardKey.arrowRight);
    await tester.pump(const Duration(milliseconds: 400));
    expect(tester.widget<LinearProgressIndicator>(find.byKey(bar)).value, closeTo(2 / 3, 1e-9));
    await key(tester, LogicalKeyboardKey.enter);
    expect(find.byKey(bar), findsNothing); // the controls' slider shows it
    await tester.pump(const Duration(seconds: 2));
  });

  testWidgets('rotation: a lock holds while the book is open, and ends with it', (tester) async {
    final calls = <Object?>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'SystemChrome.setPreferredOrientations') calls.add(call.arguments);
      return null;
    });
    final s = AppSettings.instance;
    addTearDown(() {
      s.setDisplay(s.display.copyWith(rotation: Rotation.auto));
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null);
    });
    s.setDisplay(s.display.copyWith(rotation: Rotation.portrait));
    await openReader(tester);
    expect(calls.last, ['DeviceOrientation.portraitUp', 'DeviceOrientation.portraitDown']);
    s.setDisplay(s.display.copyWith(rotation: Rotation.landscape)); // changed mid-book (the Reader panel)
    await tester.pump();
    expect(calls.last, ['DeviceOrientation.landscapeLeft', 'DeviceOrientation.landscapeRight']);
    await tester.pumpWidget(const SizedBox());
    expect(calls.last, isEmpty); // closed: the app follows the device again
  });

  test('rotation, clock and progress bar survive the saved form; older saves get the defaults', () {
    const d = DisplayPrefs(rotation: Rotation.landscape, clock: ShowWhen.always, progressBar: true);
    final back = DisplayPrefs.fromJson(d.toJson());
    expect([back.rotation, back.clock, back.progressBar], [Rotation.landscape, ShowWhen.always, true]);
    final old = DisplayPrefs.fromJson({'night': true});
    expect([old.rotation, old.clock, old.progressBar], [Rotation.auto, ShowWhen.withControls, false]);
  });

  test('double-tap zoom and volume keys: on unless switched off, and kept on the device', () {
    expect(DisplayPrefs.fromJson({'night': true}).doubleTapZoom, isTrue);
    expect(DisplayPrefs.fromJson({'night': true}).volumeKeys, isTrue);
    final off = DisplayPrefs.fromJson(const DisplayPrefs(doubleTapZoom: false, volumeKeys: false).toJson());
    expect(off.doubleTapZoom, isFalse);
    expect(off.volumeKeys, isFalse);
  });

  test('reading direction survives the settings round trip; older settings are Auto', () {
    expect(ReaderPrefs.fromJson(const ReaderPrefs(direction: ReadingDirection.rtl).toJson()).direction, ReadingDirection.rtl);
    expect(ReaderPrefs.fromJson({'fit': 'width'}).direction, ReadingDirection.auto);
    expect(const ReaderPrefs(direction: ReadingDirection.rtl, contrast: 0.2).imageReset().direction, ReadingDirection.rtl);
  });
}

