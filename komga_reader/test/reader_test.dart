import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:komga_reader/api.dart';
import 'package:komga_reader/offline/offline_komga.dart' show NotAvailableOffline;
import 'package:komga_reader/page_curl.dart';
import 'package:komga_reader/page_image.dart';
import 'package:komga_reader/screen.dart';
import 'package:komga_reader/screens/reader.dart';
import 'package:komga_reader/settings.dart';
import 'package:komga_reader/widgets/night.dart';
import 'package:komga_reader/widgets/reader_clock.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/helpers.dart';
import 'support/no_network.dart';
import 'support/reader_server.dart';

/// [ReaderServer] whose books have a poster ([poster]: Komga's thumbnail), and that records any page asked for.
class PosterKomga extends ReaderServer {
  static late Uint8List poster;
  final pagesAsked = <String>[];
  @override
  ImageProvider thumbImage(String ref) => MemoryImage(poster);
  @override
  Future<Uint8List> pageBytes(String bookId, int number) {
    pagesAsked.add('$bookId p$number');
    return super.pageBytes(bookId, number);
  }
}

/// [ReaderServer] with Komga gone mid-book (pages fail), or before the book opened ([bookDown]); back again
/// ([pagesDown] false), its pages load ([ImageKomga.png]).
class DownKomga extends ReaderServer {
  bool bookDown = false;
  bool pagesDown = true;
  @override
  Future<Map<String, dynamic>?> book(String id) async =>
      bookDown ? throw KomgaUnreachable('http://192.168.1.10:25600') : withProgress(theBook);
  @override
  Future<Uint8List> pageBytes(String bookId, int number) async =>
      pagesDown ? throw KomgaUnreachable('http://192.168.1.10:25600') : ImageKomga.png;
}

/// [ReaderServer] offline, with the next book not downloaded.
class NotDownloadedKomga extends ReaderServer {
  @override
  Future<Map<String, dynamic>?> nextBook(String bookId, {String? readListId}) async =>
      throw NotAvailableOffline('The next book');
}

/// [ReaderServer] with a series B1, B2 (already read), B3 (not read).
class ChainKomga extends ReaderServer {
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

/// [ReaderServer] with B0 (not read) and BR (read) before B1: previous of B1 is BR, previous of BR is B0.
class BackChainKomga extends ReaderServer {
  final opened = <String>[];
  @override
  Future<Map<String, dynamic>?> previousBook(String bookId, {String? readListId}) async => switch (bookId) {
        'B1' => ChainKomga.b('BR', '0.5', read: true),
        'BR' => ChainKomga.b('B0', '0'),
        _ => null,
      };
  @override
  Future<Map<String, dynamic>?> book(String id) async => withProgress(id == 'B1' ? theBook : ChainKomga.b(id, id));
  @override
  Future<List<dynamic>> pages(String bookId) {
    opened.add(bookId); // a book opened (its pages asked for once per opening; book() is asked before saves too)
    return super.pages(bookId);
  }
}

/// [ChainKomga] that returns each book by id (B1 unread, B2 read, B3 unread) and records what's opened; nothing
/// before B1.
class VisitKomga extends ChainKomga {
  final opened = <String>[];
  @override
  Future<Map<String, dynamic>?> book(String id) async =>
      withProgress(id == 'B1' ? theBook : ChainKomga.b(id, id.substring(1), read: id == 'B2'));
  @override
  Future<List<dynamic>> pages(String bookId) {
    opened.add(bookId); // a book opened (its pages asked for once per opening; book() is asked before saves too)
    return super.pages(bookId);
  }

  @override
  Future<Map<String, dynamic>?> previousBook(String bookId, {String? readListId}) async {
    prevCalls++;
    return null;
  }

  int prevCalls = 0;
  final nextAsked = <String>[];
  @override
  Future<Map<String, dynamic>?> nextBook(String bookId, {String? readListId}) {
    nextAsked.add(bookId);
    return super.nextBook(bookId, readListId: readListId);
  }
}

/// [ReaderServer] whose pages load (a small picture), with page thumbnails for the slider previews.
class ImageKomga extends ReaderServer {
  static late Uint8List png;
  ImageKomga({this.pageCount = 3});
  final int pageCount;
  @override
  Future<List<dynamic>> pages(String bookId) async => [for (var n = 1; n <= pageCount; n++) {'number': n}];
  final thumbsAsked = <int>[];
  Completer<void>? thumbsHeld; // set: thumbnails wait for it (a slow server)
  @override
  Future<Uint8List> pageBytes(String bookId, int number) async => png;
  @override
  Future<Uint8List> pageThumbBytes(String bookId, int number) async {
    thumbsAsked.add(number);
    await thumbsHeld?.future;
    return png;
  }
}

/// [VisitKomga] (B1 -> B2 -> B3) whose books after B1 load only once [hold] completes (or fail, [failNext]), and
/// that records which book each progress save went to.
class SlowKomga extends VisitKomga {
  Completer<void>? hold;
  bool failNext = false;
  final savedTo = <String>[];
  @override
  Future<List<dynamic>> pages(String bookId) async {
    if (bookId != 'B1') {
      await hold?.future;
      if (failNext) throw KomgaUnreachable('http://test');
    }
    return super.pages(bookId);
  }

  @override
  Future<void> setProgress(String bookId, int page, {bool completed = false}) {
    savedTo.add(bookId);
    return super.setProgress(bookId, page, completed: completed);
  }
}

/// A book Komga lists with no pages (a damaged file, or not analysed yet).
class EmptyKomga extends ReaderServer {
  @override
  Future<List<dynamic>> pages(String bookId) async => [];
}

/// A real page picture (200 x 300) for [ImageKomga] - and [DownKomga] once it's back.
Future<void> makePagePng(WidgetTester tester) async =>
    ImageKomga.png = (await tester.runAsync(() => solidPng(200, 300, const Color(0xFFE0D0B0))))!;

/// Real work (decoding a page) finishes in real time: lets it run in short steps until [done], up to about 2 s,
/// rather than one fixed wait that a slow machine can outlast (test audit, 2026-09-30) - and fails if it never comes.
Future<void> until(WidgetTester tester, bool Function() done) =>
    waitUntil(done, tester: tester, step: const Duration(milliseconds: 50), reason: 'the real work (decoding)');

void main() {
  // the reader starts loading the curl shader when it opens; load it once for real first, or that load starts inside
  // a test's fake clock, never finishes, and the curl tests wait on it forever
  setUpAll(preloadShaders);
  setUp(() => SharedPreferences.setMockInitialValues({}));

  late ReaderServer api;

  Future<void> openReader(WidgetTester tester, {String? readListId, Map<String, dynamic>? next}) async {
    api = noNetwork(ReaderServer.new)..next = next;
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
    // same position in the bottom bar (5th of 6: previous book, slider, pages, image, reader, next book)
    expect(focused('ctl-reader'), isTrue);
    await key(tester, LogicalKeyboardKey.arrowLeft);
    expect(focused('ctl-image'), isTrue);
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
    // the series follows the default layout: the fit is for this book only, for now - nothing saved
    expect(AppSettings.instance.hasOwn('S1'), isFalse);
    expect(AppSettings.instance.prefsFor('S1').fit, FitMode.screen);
    expect(find.byTooltip('Next book'), findsOneWidget); // controls stay up
    // let the reader's own timers run out (nothing was saved, so no settings sync is pending - test audit, 2026-09-30)
    await tester.pump(const Duration(seconds: 3));
  });

  testWidgets("the top bar's fit button: saved for the series when it overrides the default layout", (tester) async {
    final s = AppSettings.instance;
    s.setOverride('S1', layout: true);
    addTearDown(() => s.series.remove('S1'));
    await openReader(tester);
    await key(tester, LogicalKeyboardKey.enter);
    await tester.tap(find.byTooltip('Fit screen'));
    await tester.pump();
    expect(s.prefsFor('S1').fit, FitMode.width); // the series' own fit, saved
    expect(s.ownsImage('S1'), isFalse); // the image part still follows the defaults
    await tester.pump(const Duration(seconds: 3));
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

  test('brightness: with backlight control the top of the slider drives the backlight and the bottom adds the dim '
      'layer; without it (desktop) the slider only dims', () {
    // one table for both (they were two tests - test audit, 2026-09-30)
    final was = DisplayPrefs.backlightControl;
    addTearDown(() => DisplayPrefs.backlightControl = was); // even if an expect fails
    for (final (control, prefs, part, matcher, why) in [
      (true, const DisplayPrefs(), 'backlight', equals(-1), 'automatic'),
      (true, const DisplayPrefs(brightness: 1), 'backlight', closeTo(1, 1e-9), 'the top'),
      (true, const DisplayPrefs(brightness: 0.5), 'dim', equals(0), 'mid-way: no dimming yet'),
      (true, const DisplayPrefs(brightness: 0.1), 'backlight', equals(0.01), 'the minimum backlight'),
      (true, const DisplayPrefs(brightness: 0), 'dim', closeTo(0.75, 1e-9), 'the bottom: dimmed'),
      (false, const DisplayPrefs(brightness: 1), 'dim', equals(0), 'desktop, the top'),
      (false, const DisplayPrefs(brightness: 0.5), 'dim', closeTo(0.375, 1e-9), 'desktop, mid-way: dims'),
      (false, const DisplayPrefs(brightness: 0.5), 'backlight', equals(-1), 'desktop: never touches the backlight'),
    ]) {
      DisplayPrefs.backlightControl = control;
      expect(part == 'dim' ? prefs.dimOverlay : prefs.backlight, matcher,
          reason: '$why (backlight control $control, brightness ${prefs.brightness})');
    }
  });

  // the screen brightness setting is the reader's: left at extra dim from reading in bed, the app opened unreadably
  // dark in daylight - Settings too, where it could have been undone (user, 2026-10-05)
  testWidgets('brightness applies only while a book is open: elsewhere the system brightness and no dim layer; '
      'opening a book applies it, closing it gives the system its screen back', (tester) async {
    final was = DisplayPrefs.backlightControl;
    addTearDown(() => DisplayPrefs.backlightControl = was);
    DisplayPrefs.backlightControl = true; // a tablet
    final asked = <double>[]; // what the app asks the screen for (-1 = the system's own)
    const channel = MethodChannel('komga_reader/screen');
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, (c) async {
      if (c.method == 'brightness') asked.add((c.arguments as num).toDouble());
      return null;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    final s = AppSettings.instance;
    final before = s.display;
    addTearDown(() => s.setDisplay(before));
    s.setDisplay(s.display.copyWith(brightness: () => 0.0)); // extra dim, as set in bed
    expect(asked.last, -1, reason: 'no book open: the system brightness');

    Finder dimLayer() => find.byWidgetPredicate((w) => w is ColoredBox && w.color.a > 0.5 && w.color.r == 0);
    api = noNetwork(ReaderServer.new);
    await tester.pumpWidget(MaterialApp(
      builder: (context, child) => NightOverlay(child: child!),
      home: Builder(builder: (context) => TextButton(
        onPressed: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => ReaderScreen(api: api, book: api.theBook))),
        child: const Text('open'),
      )),
    ));
    await tester.pump();
    expect(dimLayer(), findsNothing, reason: 'Home and the rest: not dimmed');
    expect(find.text('open'), findsOneWidget);

    await tester.tap(find.text('open'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(asked.last, 0.01, reason: 'a book open: the lowest backlight');
    expect(dimLayer(), findsOneWidget, reason: 'and the extra-dim layer');

    await tester.binding.handlePopRoute(); // closed
    await tester.pump();
    await tester.pump(const Duration(seconds: 1)); // the way out; the reader goes at its end
    await tester.pump(); // the overlay hears of it just after (not during the reader's dispose): the next frame
    expect(find.byType(ReaderScreen), findsNothing);
    expect(asked.last, -1, reason: 'closed: the system brightness again');
    expect(dimLayer(), findsNothing, reason: 'no dim layer');
    expect(s.display.brightness, 0.0, reason: 'the setting itself is kept for the next book');
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

  testWidgets('Next book mid-book: set to Ask it asks, and Keep in progress does not mark read; set to Mark read or '
      'Keep in progress, no question asked', (tester) async {
    // one test over the three settings (they were two - test audit, 2026-09-30)
    final s = AppSettings.instance;
    addTearDown(() => s.setDisplay(s.display.copyWith(midBook: MidBook.ask)));
    for (final m in MidBook.values) {
      s.setDisplay(s.display.copyWith(midBook: m));
      await openReader(tester);
      await key(tester, LogicalKeyboardKey.enter);
      await tester.tap(find.byTooltip('Next book'));
      await tester.pump(const Duration(milliseconds: 400));
      if (m == MidBook.ask) {
        expect(find.text('Mark #1 as read?'), findsOneWidget);
        await tester.tap(find.text('Keep in progress'));
        await tester.pump(const Duration(milliseconds: 400));
      }
      await tester.pump(const Duration(milliseconds: 400));
      if (m != MidBook.ask) expect(find.text('Mark #1 as read?'), findsNothing, reason: m.name);
      expect(api.marked, m == MidBook.markRead ? ['B1'] : isEmpty, reason: m.name);
      expect(api.nextCalls, 1, reason: m.name);
      expect(find.text('End of the series'), findsOneWidget, reason: m.name); // no next book: closes with a message
      await tester.pump(const Duration(seconds: 1)); // route exit animation
      expect(find.byType(ReaderScreen), findsNothing, reason: m.name);
      await tester.pump(const Duration(seconds: 5)); // snackbar timer
      await tester.pumpWidget(const SizedBox());
    }
  });

  Future<void> toEndCard(WidgetTester tester) async {
    for (var i = 0; i < 3; i++) { // 3 pages, then the end card
      await key(tester, LogicalKeyboardKey.arrowRight);
      await tester.pump(const Duration(milliseconds: 400));
    }
    await tester.pump();
  }

  final second = {'id': 'B2', 'seriesTitle': 'Test', 'metadata': {'number': '2', 'title': 'The Second One'}};

  testWidgets('remote, past the end card: the forward key (Right; Left in right to left) opens the book the card shows '
      'at its first page, not the one after (tablet, build 56)', (tester) async {
    // one test for both directions (the right-to-left one was in that group - test audit, 2026-09-30)
    addTearDown(() => ReaderServer.direction = 'LEFT_TO_RIGHT');
    for (final rtl in [false, true]) {
      ReaderServer.direction = rtl ? 'RIGHT_TO_LEFT' : 'LEFT_TO_RIGHT';
      final forward = rtl ? LogicalKeyboardKey.arrowLeft : LogicalKeyboardKey.arrowRight;
      final how = rtl ? 'right to left' : 'left to right';
      final chain = noNetwork(VisitKomga.new); // B1 -> B2 -> B3
      api = chain;
      await tester.pumpWidget(MaterialApp(home: ReaderScreen(api: chain, book: chain.theBook)));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      for (var i = 0; i < 3; i++) { // 3 pages, then the end card
        await key(tester, forward);
        await tester.pump(const Duration(milliseconds: 400));
      }
      await tester.pump();
      expect(find.text('Test #2'), findsOneWidget, reason: '$how: the end card shows B2');
      await key(tester, forward); // on past the card
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      expect(chain.opened.last, 'B2', reason: how);
      expect(tester.widget<PageView>(find.byType(PageView)).controller!.page, 0.0, reason: '$how: its first page');
      await tester.pump(const Duration(seconds: 2));
      await tester.pumpWidget(const SizedBox());
    }
  });

  // the end card shows the next book's poster as Komga has it, at its own size, no bigger than the plate - not its
  // first page (a spread showed its middle, spine and all) (user, 2026-10-03)
  for (final (poster, shown, why) in [
    (const Size(195, 300), const Size(195, 300), "Komga's usual thumbnail: at its own size, not enlarged"),
    (const Size(649, 1000), const Size(218.4, 336), 'a big poster: shrunk to the plate (336 tall on an 800-tall screen)'),
  ]) {
    testWidgets("end card: the next book's poster, ${poster.width.round()} x ${poster.height.round()} - $why; its "
        'first page is never asked for', (tester) async {
      setView(tester, const Size(1280, 800));
      PosterKomga.poster =
          (await tester.runAsync(() => solidPng(poster.width.round(), poster.height.round(), const Color(0xFF3060A0))))!;
      api = noNetwork(PosterKomga.new)..next = second;
      await tester.pumpWidget(MaterialApp(home: ReaderScreen(api: api, book: api.theBook)));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      await toEndCard(tester);
      await until(tester, () => find.descendant(of: find.byKey(const ValueKey('next-poster')),
          matching: find.byType(RawImage)).evaluate().isNotEmpty); // decodes for real
      final size = tester.getSize(find.byKey(const ValueKey('next-poster')));
      expect(size.width, closeTo(shown.width, 0.5), reason: why);
      expect(size.height, closeTo(shown.height, 0.5), reason: why);
      expect((api as PosterKomga).pagesAsked.where((p) => p.startsWith('B2')), isEmpty,
          reason: "the next book's pages: not fetched for the card");
      await tester.pump(const Duration(seconds: 2));
    });
  }

  testWidgets("end card offline: the next book isn't downloaded - it says so, no poster, and → closes the book",
      (tester) async {
    api = noNetwork(NotDownloadedKomga.new);
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

  testWidgets("a page that won't load says why, with Retry and Details (user's mock-up); Retry loads it",
      (tester) async {
    await makePagePng(tester);
    final down = noNetwork(DownKomga.new);
    api = down;
    await tester.pumpWidget(MaterialApp(home: ReaderScreen(api: api, book: api.theBook)));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    const failed = "This page didn't load: can't reach Komga.";
    expect(find.text(failed), findsOneWidget);
    expect(find.text('Retry'), findsOneWidget);
    expect(find.text('Details'), findsOneWidget);
    // test audit, 2026-09-30: Retry was found but never pressed - Komga back, it loads the page
    down.pagesDown = false;
    await tester.tap(find.text('Retry'));
    await tester.pump();
    await until(tester, () => shows(find.byType(PageCanvas)));
    expect(find.byType(PageCanvas), findsOneWidget);
    expect(find.text(failed), findsNothing);
    await tester.pump(const Duration(seconds: 3));
  });

  testWidgets("a book that won't open says so on the screen, with Retry and Close; Retry opens it", (tester) async {
    await makePagePng(tester);
    final down = noNetwork(DownKomga.new)..bookDown = true;
    api = down;
    await tester.pumpWidget(MaterialApp(home: ReaderScreen(api: api, book: api.theBook)));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    const failed = 'Couldn\'t open "Test #1": can\'t reach Komga.';
    expect(find.text(failed), findsOneWidget);
    expect(find.text('Retry'), findsOneWidget);
    expect(find.text('Close'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsNothing); // not a spinner forever
    // test audit, 2026-09-30: Retry was found but never pressed - Komga back, it opens the book
    down
      ..bookDown = false
      ..pagesDown = false;
    await tester.tap(find.text('Retry'));
    await tester.pump();
    await until(tester, () => shows(find.byType(PageCanvas)));
    expect(find.text(failed), findsNothing);
    expect(find.byType(PageView), findsOneWidget);
    expect(find.byType(PageCanvas), findsOneWidget); // its first page, showing
    await tester.pump(const Duration(seconds: 3));
  });

  testWidgets('end card: shows the next book in the series - title and poster', (tester) async {
    await openReader(tester, next: second);
    await toEndCard(tester);
    expect(find.text('Up next in the series'), findsOneWidget);
    expect(find.text('Test #2'), findsOneWidget);
    expect(find.text('The Second One'), findsOneWidget);
    expect(find.byKey(const ValueKey('next-poster')), findsOneWidget); // its poster (its size: the tests below)
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

  testWidgets('reaching the last page marks the book read at once; closing from the end card keeps it read',
      (tester) async {
    // user, 2026-09-30: the last page = read (it used to wait for the 1.5 s save, or the close)
    await openReader(tester);
    await toEndCard(tester); // 400 ms per turn: no 1.5 s save ran
    expect(api.finished, [3], reason: 'page 3 of 3, saved as read on reaching it');
    await key(tester, LogicalKeyboardKey.escape); // close
    await tester.pump(const Duration(seconds: 1));
    expect(find.byType(ReaderScreen), findsNothing);
    expect(api.saves.last, 3);
    expect(api.finished.last, 3); // still read
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
      api = noNetwork(ChainKomga.new);
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
      final api = noNetwork(BackChainKomga.new);
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

  testWidgets('previous goes back through the books read this visit (read now or not); next then retraces forward',
      (tester) async {
    final api = noNetwork(VisitKomga.new);
    await tester.pumpWidget(MaterialApp(home: ReaderScreen(api: api, book: api.theBook, skipRead: true)));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    Future<void> settle() async {
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      await tester.pump(const Duration(milliseconds: 500));
    }

    await toEndCard(tester); // finish B1
    await key(tester, LogicalKeyboardKey.arrowRight); // on to the next unread: B3 (B2 is read)
    await settle();
    expect(api.opened.last, 'B3');
    expect(api.marked, ['B1']); // B1 is read now

    await key(tester, LogicalKeyboardKey.enter);
    await tester.tap(find.byTooltip('Previous book'));
    await settle();
    expect(api.opened.last, 'B1', reason: 'the book read before, though it is read now (not skipped)');
    expect(api.prevCalls, 0, reason: 'from the visit, not looked up');

    final asked = api.nextAsked.length;
    await toEndCard(tester);
    await settle();
    expect(find.text('Test #3'), findsOneWidget); // the end card shows where Next goes: back to B3
    await key(tester, LogicalKeyboardKey.arrowRight);
    await settle();
    expect(api.opened.last, 'B3');
    // B1 -> B3 came from the visit: nothing after B1 was looked up (arriving at B3, what comes after it may be)
    expect(api.nextAsked.sublist(asked), isNot(contains('B1')), reason: 'asked: ${api.nextAsked}');

    await key(tester, LogicalKeyboardKey.enter);
    await tester.tap(find.byTooltip('Previous book'));
    await settle();
    await key(tester, LogicalKeyboardKey.enter);
    await tester.tap(find.byTooltip('Previous book')); // back at the start of the visit: now looked up
    await settle();
    expect(api.prevCalls, 1);
    expect(find.text('No unread books before this one in the series'), findsOneWidget);
    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets('end card: the last book says so', (tester) async {
    await openReader(tester);
    await toEndCard(tester);
    expect(find.text('End of the series'), findsOneWidget);
    expect(find.text('→ : close the book'), findsOneWidget);
    await tester.pump(const Duration(seconds: 2));
  });

  for (final size in const [Size(800, 1280), Size(1280, 800), Size(400, 860), Size(860, 400)]) {
    testWidgets('reader controls fit on ${size.width.toInt()}x${size.height.toInt()} without overflow', (tester) async {
      setView(tester, size);
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
    // test audit, 2026-09-30: restored in finally - restored only at the end, a failing expect left them set for the
    // tests after it
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    final calls = <bool>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(const MethodChannel('komga_reader/screen'), (call) async {
      if (call.method == 'fullscreen') {
        calls.add(call.arguments as bool);
        return call.arguments;
      }
      return null;
    });
    try {
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
    } finally {
      // in finally, not addTearDown: the platform override must be gone before the test's own end-of-test check
      fullscreen.value = false;
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(const MethodChannel('komga_reader/screen'), null);
      debugDefaultTargetPlatformOverride = null;
    }
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
      // a few frames per phase - the tap's double-tap wait, the turn starting, playing, landing - not 40 (2 s in 50 ms
      // steps, ~480 frames over the three modes - test audit, 2026-09-30)
      Future<void> settle() async {
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 400));
        await tester.pump(const Duration(milliseconds: 400));
        await tester.pump(const Duration(seconds: 1));
      }

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
    Finder curling() => find.byWidgetPredicate((w) => w is CustomPaint && w.painter is CurlLayer);

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

    testWidgets('a curl let go before halfway leaves no trace; a tap while it springs back does nothing',
        (tester) async {
      // code review, 2026-09-30: the cancelled curl saved progress (un-reading a finished book); a tap during the
      // spring-back skipped a page
      await openCurling(tester);
      final size = tester.getSize(find.byType(PageView));
      final y = size.height / 2;
      final g = await tester.startGesture(Offset(size.width * 0.8, y));
      for (var i = 1; i <= 10; i++) {
        await g.moveTo(Offset(size.width * 0.8 - i * 8.0, y));
        await tester.pump(const Duration(milliseconds: 50));
      }
      await g.up();
      await tester.pump(); // the spring-back starts
      await tester.pump(const Duration(milliseconds: 100));
      await tester.tapAt(Offset(size.width * 0.9, y)); // forward, mid spring-back
      await tester.pump(const Duration(milliseconds: 500));
      await tester.pump();
      expect(page(tester), 0.0, reason: 'the tap waited for the spring-back: nothing turned');
      await tester.pump(const Duration(seconds: 2)); // past the save delay
      expect(api.saves, isEmpty, reason: 'nothing was turned, nothing saved');
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

  testWidgets('page turn: Swipe slides (half-way through after a few frames)', (tester) async {
    await openReader(tester);
    await key(tester, LogicalKeyboardKey.arrowRight);
    await tester.pump(const Duration(milliseconds: 60));
    final page = tester.widget<PageView>(find.byType(PageView)).controller!.page!;
    expect(page > 0 && page < 1, isTrue);
    await tester.pump(const Duration(seconds: 3));
  });

  group('right to left', () {
    setUp(() => ReaderServer.direction = 'RIGHT_TO_LEFT');
    tearDown(() {
      ReaderServer.direction = 'LEFT_TO_RIGHT';
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

    testWidgets('a per-series direction overrides Komga either way: pages and the arrow keys follow the series',
        (tester) async {
      // test audit, 2026-09-30: one test for both ways (the "Right to left" one only read PageView.reverse - now the
      // key that goes forward is checked too)
      for (final (own, komga) in [
        (ReadingDirection.ltr, 'RIGHT_TO_LEFT'), // "Left to right" over Komga's right to left
        (ReadingDirection.rtl, 'LEFT_TO_RIGHT'), // "Right to left" over Komga's left to right
      ]) {
        ReaderServer.direction = komga; // the group's tearDown puts it back
        AppSettings.instance.series['S1'] = ReaderPrefs(direction: own); // ... and removes this
        final rtl = own == ReadingDirection.rtl;
        await openReader(tester);
        expect(tester.widget<PageView>(find.byType(PageView)).reverse, rtl, reason: own.name);
        await key(tester, rtl ? LogicalKeyboardKey.arrowLeft : LogicalKeyboardKey.arrowRight); // forward
        await tester.pump(const Duration(milliseconds: 400));
        expect(page(tester), 1.0, reason: '${own.name}: the forward key turned');
        await tester.pump(const Duration(seconds: 2));
        await tester.pumpWidget(const SizedBox());
      }
    });
  });

  group('with pages that load', () {
    Future<void> openLoaded(WidgetTester tester, {int pages = 3}) async {
      await makePagePng(tester);
      api = noNetwork(() => ImageKomga(pageCount: pages));
      await tester.pumpWidget(MaterialApp(home: ReaderScreen(api: api, book: api.theBook)));
      await tester.pump();
      await until(tester, () => shows(find.byType(PageCanvas))); // pages decode for real
      expect(find.byType(PageCanvas), findsWidgets);
    }

    double page(WidgetTester tester) => tester.widget<PageView>(find.byType(PageView)).controller!.page!;
    double scale(WidgetTester tester) =>
        tester.widget<InteractiveViewer>(find.byType(InteractiveViewer).first).transformationController!.value
            .getMaxScaleOnAxis();

    testWidgets('every page turn mode keeps the neighbouring pages built (processed before they are turned to)',
        (tester) async {
      // test audit, 2026-09-30: it only read the page view's allowImplicitScrolling (a constant); now the next page
      // must really be there, built and laid out off screen, in each mode
      addTearDown(() => AppSettings.instance.setDisplay(AppSettings.instance.display.copyWith(pageTurn: PageTurn.swipe)));
      // the page after the one showing (on page 1 of 3, the only page that isn't current)
      final next = find.byWidgetPredicate((w) => w is PageCanvas && !w.current, skipOffstage: false);
      for (final turn in PageTurn.values) {
        AppSettings.instance.setDisplay(AppSettings.instance.display.copyWith(pageTurn: turn));
        await openLoaded(tester);
        await until(tester, () => shows(next));
        expect(next, findsOneWidget, reason: turn.name);
        expect(page(tester), 0.0, reason: turn.name); // still on the first page: nothing turned to build it
        await tester.pump(const Duration(seconds: 3));
        await tester.pumpWidget(const SizedBox());
      }
    });

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
      await openLoaded(tester, pages: 20);
      await key(tester, LogicalKeyboardKey.enter); // controls
      const preview = ValueKey('page-preview');
      expect(find.byKey(preview), findsNothing);
      final r = tester.getRect(find.byType(Slider));
      final g = await tester.startGesture(Offset(r.left + 20, r.center.dy)); // the thumb, on page 1
      await g.moveTo(Offset(r.left + 60, r.center.dy));
      await g.moveTo(Offset(r.right - 20, r.center.dy)); // the last page
      await tester.pump();
      await until(tester, () => shows(find.descendant(of: find.byKey(preview), matching: find.byType(Image))) &&
          !shows(find.byKey(const ValueKey('preview-loading')))); // the picture decodes
      expect(find.byKey(preview), findsOneWidget);
      expect(find.text('Page 20'), findsOneWidget);
      expect((api as ImageKomga).thumbsAsked, contains(20));
      final p = tester.getRect(find.byKey(preview));
      expect(p.center.dx, closeTo(r.right - 20, 1)); // over the thumb
      expect(p.bottom, lessThan(r.top)); // above the bar, over the page
      expect(find.descendant(of: find.byKey(preview), matching: find.byType(Image)), findsOneWidget);
      expect(find.byKey(const ValueKey('preview-loading')), findsNothing); // its own picture: no spinner
      await g.up();
      await tester.pump();
      expect(find.byKey(preview), findsNothing);
      expect(page(tester), 19.0);
      await tester.pump(const Duration(seconds: 2));
    });

    testWidgets('Page previews off: just the page number over the thumb, and no pictures asked for', (tester) async {
      final s = AppSettings.instance;
      s.setDisplay(s.display.copyWith(pagePreviews: false));
      addTearDown(() => s.setDisplay(s.display.copyWith(pagePreviews: true)));
      await openLoaded(tester, pages: 20);
      await key(tester, LogicalKeyboardKey.enter); // controls
      final r = tester.getRect(find.byType(Slider));
      final g = await tester.startGesture(Offset(r.left + 20, r.center.dy));
      await g.moveTo(Offset(r.right - 20, r.center.dy)); // the last page
      await tester.pump();
      expect(find.byKey(const ValueKey('page-label')), findsOneWidget);
      expect(find.text('Page 20'), findsOneWidget);
      expect(find.byKey(const ValueKey('page-preview')), findsNothing);
      await tester.pump();
      expect((api as ImageKomga).thumbsAsked, isEmpty);
      await g.up();
      await tester.pump();
      expect(page(tester), 19.0);
      await tester.pump(const Duration(seconds: 2));
    });

    testWidgets('slider: scrubbing back and forth never turns the page before letting go, asks only for the page '
        'the thumb is on, and uses pages already loaded (user, 2026-09-30)', (tester) async {
      await openLoaded(tester, pages: 20);
      final komga = api as ImageKomga..thumbsHeld = Completer<void>(); // a slow server
      await key(tester, LogicalKeyboardKey.enter); // controls
      final r = tester.getRect(find.byType(Slider));
      Offset at(int i) => Offset(r.left + 20 + i * (r.width - 40) / 19, r.center.dy); // 20 pages
      final g = await tester.startGesture(at(0));
      await tester.pump();
      for (final i in [1, 10, 15, 5, 12, 19, 8, 19]) { // to and fro
        await g.moveTo(at(i));
        await tester.pump();
        expect(page(tester), 0.0, reason: 'the finger is still down');
      }
      await tester.pump();
      // page 2 is already loaded (the next page): shown from there, not asked for
      expect(komga.thumbsAsked, [11, 16], reason: 'two at a time; the pages passed meanwhile are not queued up');
      // waiting: the picture there is another page's, so it's faded under a spinner
      expect(find.byKey(const ValueKey('preview-loading')), findsOneWidget);
      await tester.runAsync(() async => komga.thumbsHeld!.complete());
      await tester.pump();
      await until(tester, () => komga.thumbsAsked.length > 2);
      expect(komga.thumbsAsked, [11, 16, 20], reason: 'then the page the thumb is on now');
      await until(tester, () => !shows(find.byKey(const ValueKey('preview-loading'))));
      expect(find.text('Page 20'), findsOneWidget);
      expect(find.byKey(const ValueKey('preview-loading')), findsNothing);
      await g.up();
      await tester.pump();
      expect(page(tester), 19.0);
      await tester.pump(const Duration(seconds: 2));
    });

    // the slider takes a finger and a mouse the same way (raw pointer events): both are tried
    for (final kind in [PointerDeviceKind.touch, PointerDeviceKind.mouse]) {
    testWidgets('slider (${kind.name}): after a jump away the way back stays marked, scrubbing or not; an ordinary '
        'page turn forgets it - reading on from there (user, 2026-10-02)', (tester) async {
      await openLoaded(tester, pages: 200);
      await key(tester, LogicalKeyboardKey.enter); // controls
      final r = tester.getRect(find.byType(Slider));
      Offset at(int i) => Offset(r.left + 20 + i * (r.width - 40) / 199, r.center.dy);
      const mark = ValueKey('scrub-start');
      double markX() => tester.getRect(find.byKey(mark)).center.dx;
      var g = await tester.startGesture(at(0), kind: kind);
      await g.moveTo(at(100));
      await g.up();
      await tester.pump();
      expect(page(tester), 100.0);
      expect(markX(), closeTo(at(0).dx, 1), reason: 'not scrubbing: the way back still shows');
      await key(tester, LogicalKeyboardKey.escape); // controls away and back: still there
      await key(tester, LogicalKeyboardKey.enter);
      expect(markX(), closeTo(at(0).dx, 1), reason: 'with the controls shown again');
      g = await tester.startGesture(at(100), kind: kind);
      await tester.pump();
      expect(markX(), closeTo(at(0).dx, 1), reason: 'the way back is kept over the jump');
      await g.up();
      await tester.pump();
      await key(tester, LogicalKeyboardKey.escape); // controls away
      await tester.pump();
      await key(tester, LogicalKeyboardKey.arrowRight); // a page turn: reading on from here
      await tester.pump(const Duration(milliseconds: 400));
      expect(page(tester), 101.0);
      await key(tester, LogicalKeyboardKey.enter);
      expect(find.byKey(mark), findsNothing, reason: 'forgotten: no mark while not scrubbing');
      g = await tester.startGesture(at(101), kind: kind);
      await g.moveTo(at(150));
      await tester.pump();
      expect(markX(), closeTo(at(101).dx, 1), reason: 'forgotten: scrubbing, the mark is where the reader is now');
      await g.up();
      await tester.pump(const Duration(seconds: 2));
    });

    testWidgets('slider (${kind.name}): a mark where scrubbing started, kept after a jump away; a drag near it snaps '
        'back to it, and once back the mark follows the reader again (user, 2026-10-02)', (tester) async {
      await openLoaded(tester, pages: 200); // ~4 px a page on the slider: hard to hit one page by hand
      for (var i = 0; i < 3; i++) {
        await key(tester, LogicalKeyboardKey.arrowRight);
        await tester.pump(const Duration(milliseconds: 400));
      }
      expect(page(tester), 3.0);
      await key(tester, LogicalKeyboardKey.enter); // controls
      final r = tester.getRect(find.byType(Slider));
      Offset at(int i) => Offset(r.left + 20 + i * (r.width - 40) / 199, r.center.dy);
      const mark = ValueKey('scrub-start');
      double markX() => tester.getRect(find.byKey(mark)).center.dx;
      expect(find.byKey(mark), findsNothing, reason: 'nowhere to go back to, not scrubbing: no mark');

      // off to page 151 to look at it: the mark stays on page 4, where it started
      var g = await tester.startGesture(at(3), kind: kind);
      await g.moveTo(at(150));
      await tester.pump();
      expect(markX(), closeTo(at(3).dx, 1));
      await g.up();
      await tester.pump();
      expect(page(tester), 150.0);
      expect(markX(), closeTo(at(3).dx, 1), reason: 'after the jump: the way back, shown');

      // scrubbing again: the mark is still where the reader came from, not here
      g = await tester.startGesture(at(150), kind: kind);
      await tester.pump();
      expect(markX(), closeTo(at(3).dx, 1), reason: 'the way back, after the jump');
      // a few pages off the mark (12 px: page 6 by position) - close enough to snap onto it
      await g.moveTo(at(3) + const Offset(12, 0));
      await tester.pump();
      expect(find.text('Page 4'), findsOneWidget, reason: 'snapped to the start');
      await g.moveTo(at(3) + const Offset(40, 0)); // well away: no snap
      await tester.pump();
      expect(find.text('Page 4'), findsNothing);
      await g.moveTo(at(3) + const Offset(-12, 0)); // the other side, close again
      await tester.pump();
      expect(find.text('Page 4'), findsOneWidget);
      await g.up();
      await tester.pump();
      expect(page(tester), 3.0, reason: 'back where it was');
      expect(find.byKey(mark), findsNothing, reason: 'back: nothing to go back to');

      // back there: the way back is done - the next scrub's mark is wherever the reader is then
      await key(tester, LogicalKeyboardKey.escape); // controls away
      await tester.pump();
      for (var i = 0; i < 20; i++) {
        await key(tester, LogicalKeyboardKey.arrowRight);
        await tester.pump(const Duration(milliseconds: 400));
      }
      expect(page(tester), 23.0);
      await key(tester, LogicalKeyboardKey.enter);
      g = await tester.startGesture(at(23), kind: kind);
      await g.moveTo(at(100));
      await tester.pump();
      expect(markX(), closeTo(at(23).dx, 1));
      await g.up();
      await tester.pump(const Duration(seconds: 2));
    });
    }

    // Save page / Copy page (user, 2026-10-02): one line at the top of the Reader panel; the page's own picture file.
    // The platform side (MainActivity.kt / desktop_channel.cpp) is stood in for by a fake channel.
    group('save / copy page', () {
      const channel = MethodChannel('komga_reader/screen');
      late List<MethodCall> calls;
      Object? Function(MethodCall c) answer = (c) => null;
      setUp(() {
        calls = [];
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, (c) async {
          calls.add(c);
          return answer(c);
        });
      });
      tearDown(() {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, null);
        debugDefaultTargetPlatformOverride = null;
      });
      Future<void> openPanel(WidgetTester tester) async {
        await openLoaded(tester, pages: 3);
        await key(tester, LogicalKeyboardKey.enter); // controls
        await tester.tap(find.byTooltip('Reader settings'));
        await tester.pumpAndSettle();
      }

      List<MethodCall> named(String m) => [for (final c in calls) if (c.method == m) c];
      // a message read: gone at once, so nothing covers the next tap
      Future<void> clearMessages(WidgetTester tester) async {
        tester.state<ScaffoldMessengerState>(find.byType(ScaffoldMessenger).first).removeCurrentSnackBar();
        await tester.pump();
      }

      testWidgets('Android: Save and Copy on one line; Save puts the page file in the Pictures album, Copy on the '
          'clipboard - the page as Komga sends it, named for the book and page', (tester) async {
        answer = (c) => c.method == 'savePicture' ? 'Pictures/BeDeReader/${(c.arguments as Map)['name']}'
            : c.method == 'copyPicture' ? true : null;
        await openPanel(tester);
        final save = find.widgetWithText(OutlinedButton, 'Save page'), copy = find.widgetWithText(OutlinedButton, 'Copy page');
        expect(save, findsOneWidget);
        expect(copy, findsOneWidget);
        expect(tester.getCenter(save).dy, tester.getCenter(copy).dy, reason: 'one horizontal line');
        expect(tester.getRect(find.text('This page')).top, lessThan(tester.getRect(save).top), reason: 'its own group');

        await tester.tap(save);
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
        await tester.pump();
        final s = named('savePicture').single.arguments as Map;
        expect(s['bytes'], ImageKomga.png, reason: "the page's own file");
        expect(s['name'], 'Test #1 - page 1.png');
        expect(s['mime'], 'image/png');
        expect(find.text('Page saved: Pictures/BeDeReader/Test #1 - page 1.png'), findsOneWidget);

        await clearMessages(tester);
        await tester.tap(copy);
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
        await tester.pump();
        final c = named('copyPicture').single.arguments as Map;
        expect(c['bytes'], ImageKomga.png);
        expect(c['name'], 'Test #1 - page 1.png');
        expect(find.text('Page copied'), findsOneWidget);
        await clearMessages(tester);
      });

      testWidgets("Windows: Save writes into the Pictures folder, ' (2)' when the name's taken; Copy hands over the "
          'decoded pixels and a PNG', (tester) async {
        final dir = (await tester.runAsync(() => Directory.systemTemp.createTemp('komga_pictures')))!;
        addTearDown(() { if (dir.existsSync()) dir.deleteSync(recursive: true); }); // (sync: runAsync is over by then)
        answer = (c) => c.method == 'picturesDir' ? dir.path : c.method == 'copyPicture' ? true : null;
        debugDefaultTargetPlatformOverride = TargetPlatform.windows;
        await openPanel(tester);
        for (var i = 1; i <= 2; i++) {
          await tester.tap(find.widgetWithText(OutlinedButton, 'Save page'));
          // real file work, a step at a time: until the message says it's saved
          await waitUntil(() => shows(find.textContaining('Page saved:')), tester: tester,
              step: const Duration(milliseconds: 20), reason: 'save $i');
          await clearMessages(tester);
        }
        final files = (await tester.runAsync(() async => [for (final f in dir.listSync()) f.path.split(Platform.pathSeparator).last]))!
          ..sort();
        expect(files, ['Test #1 - page 1 (2).png', 'Test #1 - page 1.png']);
        final saved = (await tester.runAsync(() => File('${dir.path}${Platform.pathSeparator}Test #1 - page 1.png').readAsBytes()))!;
        expect(saved, ImageKomga.png);

        await tester.tap(find.widgetWithText(OutlinedButton, 'Copy page'));
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 300)));
        await tester.pump();
        final c = named('copyPicture').single.arguments as Map;
        final w = c['width'] as int, h = c['height'] as int;
        expect((w, h), (200, 300), reason: "the page's own size");
        expect((c['rgba'] as Uint8List).length, w * h * 4, reason: 'every pixel, RGBA');
        expect((c['png'] as Uint8List).sublist(0, 4), [0x89, 0x50, 0x4E, 0x47], reason: 'and as PNG');
        expect(find.text('Page copied'), findsOneWidget);
        await clearMessages(tester);
        debugDefaultTargetPlatformOverride = null;
      });

      testWidgets("saving that fails says so; on the end card there's no page, so no Save / Copy", (tester) async {
        answer = (c) => c.method == 'savePicture' ? throw PlatformException(code: 'save', message: 'disk full') : null;
        await openPanel(tester);
        await tester.tap(find.widgetWithText(OutlinedButton, 'Save page'));
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
        await tester.pump();
        expect(find.textContaining("Couldn't save the page"), findsOneWidget);
        await clearMessages(tester);

        Navigator.of(tester.element(find.text('This page'))).pop(); // the panel away
        await tester.pumpAndSettle();
        await key(tester, LogicalKeyboardKey.escape); // controls away
        for (var i = 0; i < 3; i++) { // past the last page: the end card
          await key(tester, LogicalKeyboardKey.arrowRight);
          await tester.pump(const Duration(milliseconds: 400));
        }
        expect(page(tester), 3.0);
        await key(tester, LogicalKeyboardKey.enter);
        await tester.tap(find.byTooltip('Reader settings'));
        await tester.pumpAndSettle();
        expect(find.text('This page'), findsNothing);
        expect(find.widgetWithText(OutlinedButton, 'Save page'), findsNothing);
        await tester.pump(const Duration(seconds: 2));
      });
    });

    // the page strip (user, 2026-10-02): a film strip of the pages above the bottom bar, behind the Pages button
    group('page strip', () {
      const strip = ValueKey('page-strip');
      Finder tile(int i) => find.byKey(ValueKey('strip-$i'));
      // open or closed is a device setting (AppSettings is shared by the tests): closed after each
      tearDown(() {
        final s = AppSettings.instance;
        s.setDisplay(s.display.copyWith(pageStrip: false));
      });

      testWidgets('once opened it stays: the controls hidden and shown again after reading on, it is there, on the '
          'page being read; closing the book and opening another, still there - until the button closes it '
          '(user, 2026-10-02)', (tester) async {
        await openLoaded(tester, pages: 40);
        await key(tester, LogicalKeyboardKey.enter); // controls
        await tester.tap(find.byTooltip('Show pages'));
        await tester.pump();
        await tester.tap(tile(5)); // browsed there, and stays
        await tester.pump(const Duration(milliseconds: 400));
        expect(page(tester), 5.0);
        await key(tester, LogicalKeyboardKey.escape); // controls away
        await tester.pump();
        expect(find.byKey(strip), findsNothing, reason: 'not over the page while reading');
        for (var i = 0; i < 12; i++) { // reading on, to page 18
          await key(tester, LogicalKeyboardKey.arrowRight);
          await tester.pump(const Duration(milliseconds: 400));
        }
        expect(page(tester), 17.0);
        await key(tester, LogicalKeyboardKey.enter); // controls again
        await tester.pump();
        await tester.pump();
        expect(find.byKey(strip), findsOneWidget, reason: 'still open');
        final now = tester.getRect(tile(17));
        final screen = tester.getRect(find.byKey(strip));
        expect(now.left >= screen.left && now.right <= screen.right, isTrue, reason: 'page 18 in view: $now in $screen');
        expect(now.center.dx, closeTo(screen.center.dx, now.width), reason: 'in the middle of the strip');

        // the book closed, another opened: still open there
        await tester.pump(const Duration(seconds: 2));
        await tester.pumpWidget(const SizedBox());
        await openLoaded(tester, pages: 40);
        await key(tester, LogicalKeyboardKey.enter);
        await tester.pump();
        expect(find.byKey(strip), findsOneWidget, reason: 'kept on the device, book after book');
        await tester.tap(find.byTooltip('Hide pages'));
        await tester.pump();
        expect(find.byKey(strip), findsNothing);
        expect(AppSettings.instance.display.pageStrip, isFalse, reason: 'closed with the button: closed for good');
        await tester.pump(const Duration(seconds: 2));
      });

      testWidgets('on a phone-width screen the page picked is in the middle of the strip, far into a book too (its '
          'tiles were taken as 2 px wider than they are: ~200 px off by page 100 - code review 2026-10-05, #10)',
          (tester) async {
        tester.view.physicalSize = const Size(400, 800);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        await openLoaded(tester, pages: 120);
        await key(tester, LogicalKeyboardKey.enter); // controls
        await tester.tap(find.byTooltip('Show pages'));
        await tester.pump();
        await tester.pump();
        await key(tester, LogicalKeyboardKey.arrowDown); // the bottom bar
        await key(tester, LogicalKeyboardKey.arrowUp); // into the strip
        expect(focused('ctl-strip'), isTrue);
        for (var i = 0; i < 99; i++) {
          await key(tester, LogicalKeyboardKey.arrowRight);
        }
        await tester.pump(const Duration(milliseconds: 300));
        await tester.pump(const Duration(milliseconds: 300)); // (the last centring's animation runs)
        final picked = tester.getRect(tile(99));
        final screen = tester.getRect(find.byKey(strip));
        expect(picked.center.dx, closeTo(screen.center.dx, 2), reason: 'page 100 in the middle: $picked in $screen');
        await tester.pump(const Duration(seconds: 2));
      });

      testWidgets('the Pages button opens it at the page shown; a page tapped is gone to and the strip stays, the way '
          'back marked; the button closes it', (tester) async {
        await openLoaded(tester, pages: 40);
        await key(tester, LogicalKeyboardKey.enter); // controls
        expect(find.byKey(strip), findsNothing, reason: 'closed until asked for');
        await tester.tap(find.byTooltip('Show pages'));
        await tester.pump();
        await tester.pump();
        expect(find.byKey(strip), findsOneWidget);
        expect(tile(0), findsOneWidget, reason: 'opened at page 1, the page shown');
        await until(tester, () => (api as ImageKomga).thumbsAsked.isNotEmpty);
        final asked = (api as ImageKomga).thumbsAsked;
        // ~11 tiles on an 800-wide screen, plus the few the list builds just past its edge; pages 1-3 are loaded
        // already (no thumbnail needed) - not the whole book
        expect(asked.every((n) => n <= 16), isTrue, reason: 'only pages on or near the strip are asked for: $asked');
        expect(asked.toSet().length, asked.length, reason: 'none twice');

        await tester.tap(tile(5));
        await tester.pump(const Duration(milliseconds: 400));
        expect(page(tester), 5.0, reason: 'page 6');
        expect(find.byKey(strip), findsOneWidget, reason: 'the strip stays');
        expect(find.byTooltip('Hide pages'), findsOneWidget, reason: 'and the controls');
        final mark = tester.getRect(find.byKey(const ValueKey('strip-way-back')));
        expect(mark.center.dx, closeTo(tester.getRect(tile(0)).center.dx, 1), reason: 'the way back: under page 1');

        await tester.tap(find.byTooltip('Hide pages'));
        await tester.pump();
        expect(find.byKey(strip), findsNothing);
        await tester.pump(const Duration(seconds: 2));
      });

      testWidgets('scrubbing the slider moves the strip with it, to the page being picked; letting go, it stays on '
          'the page gone to (user, 2026-10-03)', (tester) async {
        await openLoaded(tester, pages: 60);
        await key(tester, LogicalKeyboardKey.enter); // controls
        await tester.tap(find.byTooltip('Show pages'));
        await tester.pump();
        await tester.pump();
        void centred(int i, String why) {
          final t = tester.getRect(tile(i)), s = tester.getRect(find.byKey(strip));
          expect(t.center.dx, closeTo(s.center.dx, t.width), reason: '$why: page ${i + 1} in the middle');
        }

        final r = tester.getRect(find.byType(Slider));
        Offset at(int i) => Offset(r.left + 20 + i * (r.width - 40) / 59, r.center.dy);
        final g = await tester.startGesture(at(0));
        await g.moveTo(at(40));
        await tester.pump();
        await tester.pump();
        centred(40, 'picking page 41');
        expect(page(tester), 0.0, reason: 'nothing turned yet');
        await g.moveTo(at(20));
        await tester.pump();
        await tester.pump();
        centred(20, 'back to page 21');
        await g.up();
        await tester.pump(const Duration(milliseconds: 400));
        await tester.pump();
        expect(page(tester), 20.0);
        centred(20, 'gone there');

        // the remote on the slider: the same
        await key(tester, LogicalKeyboardKey.arrowDown); // bottom bar
        await key(tester, LogicalKeyboardKey.arrowRight); // the slider
        await key(tester, LogicalKeyboardKey.enter); // scrub
        for (var i = 0; i < 15; i++) {
          await key(tester, LogicalKeyboardKey.arrowRight);
        }
        await tester.pump();
        centred(35, 'the remote picking page 36');
        await tester.pump(const Duration(seconds: 2));
      });

      testWidgets('thumbnails are up to 100 px tall, smaller on a narrow screen so at least 8 always fit across',
          (tester) async {
        for (final (width, height) in [(1200.0, 100.0), (400.0, null)]) {
          setView(tester, Size(width, 800));
          await openLoaded(tester, pages: 40);
          await key(tester, LogicalKeyboardKey.enter);
          if (!AppSettings.instance.display.pageStrip) await tester.tap(find.byTooltip('Show pages')); // (stays open)
          await tester.pump();
          await tester.pump();
          final first = tester.getRect(tile(0));
          if (height != null) expect(first.height, closeTo(height, 0.5), reason: '$width wide: full size');
          expect(first.height, lessThanOrEqualTo(100.5));
          expect(tester.getRect(tile(7)).right, lessThanOrEqualTo(width), reason: '$width wide: 8 pages fit');
          await tester.pump(const Duration(seconds: 2));
          await tester.pumpWidget(const SizedBox());
        }
      });

      testWidgets('remote: Up from the bottom bar into the strip on the page shown, Right along it, OK goes there '
          '(strip stays), Down back to the bottom bar', (tester) async {
        await openLoaded(tester, pages: 40);
        await key(tester, LogicalKeyboardKey.enter); // controls
        await tester.tap(find.byTooltip('Show pages'));
        await tester.pump();
        await key(tester, LogicalKeyboardKey.arrowDown); // the bottom bar
        expect(focused('ctl-prevBook'), isTrue);
        await key(tester, LogicalKeyboardKey.arrowUp); // into the strip
        expect(focused('ctl-strip'), isTrue);
        for (var i = 0; i < 3; i++) {
          await key(tester, LogicalKeyboardKey.arrowRight);
        }
        expect(page(tester), 0.0, reason: 'moving along the strip turns nothing');
        await key(tester, LogicalKeyboardKey.enter);
        await tester.pump(const Duration(milliseconds: 400));
        expect(page(tester), 3.0, reason: 'OK: page 4');
        expect(find.byKey(strip), findsOneWidget);
        expect(focused('ctl-strip'), isTrue, reason: 'still in the strip');
        await key(tester, LogicalKeyboardKey.arrowDown);
        expect(focused('ctl-pages'), isTrue, reason: 'down: the Pages button below');
        await key(tester, LogicalKeyboardKey.arrowUp);
        await key(tester, LogicalKeyboardKey.arrowUp);
        expect(focused('ctl-close'), isTrue, reason: 'up from the strip: the top bar');
        await tester.pump(const Duration(seconds: 2));
      });

      testWidgets('right to left: page 1 at the right end, and Left goes on through the book', (tester) async {
        ReaderServer.direction = 'RIGHT_TO_LEFT';
        addTearDown(() => ReaderServer.direction = 'LEFT_TO_RIGHT');
        await openLoaded(tester, pages: 40);
        await key(tester, LogicalKeyboardKey.enter);
        await tester.tap(find.byTooltip('Show pages'));
        await tester.pump();
        expect(tester.getRect(tile(0)).left, greaterThan(tester.getRect(tile(1)).left), reason: 'page 1 right of 2');
        await key(tester, LogicalKeyboardKey.arrowDown);
        await key(tester, LogicalKeyboardKey.arrowUp);
        await key(tester, LogicalKeyboardKey.arrowLeft);
        await key(tester, LogicalKeyboardKey.arrowLeft);
        await key(tester, LogicalKeyboardKey.enter);
        await tester.pump(const Duration(milliseconds: 400));
        expect(page(tester), 2.0, reason: 'two to the left: page 3');
        await tester.pump(const Duration(seconds: 2));
      });
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

  group('moving between books (code review, 2026-09-30)', () {
    Future<SlowKomga> openSlow(WidgetTester tester) async {
      final slow = noNetwork(SlowKomga.new);
      api = slow;
      await tester.pumpWidget(MaterialApp(home: ReaderScreen(api: slow, book: slow.theBook)));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      return slow;
    }

    testWidgets('a second forward while the next book loads does nothing (it opened the book after, marking the one '
        'in between read)', (tester) async {
      final slow = await openSlow(tester);
      slow.hold = Completer<void>();
      await toEndCard(tester);
      await key(tester, LogicalKeyboardKey.arrowRight); // on past the end card: B2 starts loading
      await tester.pump();
      await tester.sendKeyDownEvent(LogicalKeyboardKey.arrowRight); // again while it loads, and held
      await tester.sendKeyRepeatEvent(LogicalKeyboardKey.arrowRight);
      await tester.sendKeyRepeatEvent(LogicalKeyboardKey.arrowRight);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.arrowRight);
      await tester.pump();
      slow.hold!.complete();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      expect(slow.opened, ['B1', 'B2'], reason: 'B3 not opened');
      expect(slow.marked, ['B1'], reason: 'B2 not marked read');
      expect(tester.widget<PageView>(find.byType(PageView)).controller!.page, 0.0); // B2's first page
      await tester.pump(const Duration(seconds: 2));
    });

    testWidgets("the next book failing to open leaves the book being read as it was - its progress isn't saved to "
        'the other one', (tester) async {
      final slow = await openSlow(tester)..failNext = true;
      await toEndCard(tester);
      await key(tester, LogicalKeyboardKey.arrowRight); // on: B2 fails to open
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      expect(find.text('Test #2'), findsOneWidget, reason: "still B1's end card");
      await key(tester, LogicalKeyboardKey.arrowLeft); // back to B1's last page
      await tester.pump(const Duration(milliseconds: 400));
      await key(tester, LogicalKeyboardKey.escape); // close
      await tester.pump(const Duration(seconds: 1));
      expect(slow.savedTo, isNotEmpty);
      expect(slow.savedTo, everyElement('B1'));
      await tester.pump(const Duration(seconds: 5)); // the snackbar
    });

    testWidgets('Next book mid-book with no book after it: marked read, and closing no longer un-reads it',
        (tester) async {
      final s = AppSettings.instance;
      s.setDisplay(s.display.copyWith(midBook: MidBook.markRead));
      addTearDown(() => s.setDisplay(s.display.copyWith(midBook: MidBook.ask)));
      await openReader(tester); // the series' last book
      await key(tester, LogicalKeyboardKey.arrowRight); // page 2 of 3
      await tester.pump(const Duration(milliseconds: 400));
      await key(tester, LogicalKeyboardKey.enter); // controls
      await tester.tap(find.byTooltip('Next book'));
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      expect(find.byType(ReaderScreen), findsNothing); // "End of the series", closed
      expect(api.marked, ['B1']);
      expect(api.saves, isEmpty, reason: 'no "in progress at page 2" saved over read on closing');
      await tester.pump(const Duration(seconds: 5)); // the snackbar
    });

    testWidgets('a book with no pages says so, offering Next book and Close - no crash', (tester) async {
      final empty = noNetwork(EmptyKomga.new);
      api = empty;
      await tester.pumpWidget(MaterialApp(home: ReaderScreen(api: empty, book: empty.theBook)));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      expect(find.textContaining('has no pages'), findsOneWidget);
      expect(find.text('Next book'), findsOneWidget);
      expect(find.text('Close'), findsOneWidget);
      expect(find.text('Retry'), findsNothing); // retrying won't help
      expect(tester.takeException(), isNull);
    });
  });

  testWidgets('background: the reading defaults\' White makes the reader white, with dark text on the end card; a '
      "series' own background overrides it (user, 2026-10-05)", (tester) async {
    final s = AppSettings.instance;
    final defaults = s.defaults;
    addTearDown(() {
      s.setDefault(defaults);
      s.series.remove('S1');
    });
    s.setDefault(s.defaults.copyWith(background: ReaderBackground.white));
    await openReader(tester); // series S1, following the defaults
    expect(tester.widget<Scaffold>(find.byType(Scaffold).last).backgroundColor, const Color(0xFFFFFFFF));
    await toEndCard(tester);
    expect(tester.widget<Text>(find.text('End of book')).style!.color!.computeLuminance(), lessThan(0.2));
    await tester.pump(const Duration(seconds: 2));
    await tester.pumpWidget(const SizedBox());

    s.setSeriesLayout('S1', s.prefsFor('S1').copyWith(background: ReaderBackground.grey)); // S1's own
    await openReader(tester);
    expect(tester.widget<Scaffold>(find.byType(Scaffold).last).backgroundColor, ReaderBackground.grey.colour,
        reason: "the series' own, over the defaults' white");
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
}

