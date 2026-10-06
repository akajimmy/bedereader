import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:komga_reader/api.dart';
import 'package:komga_reader/page_curl.dart';
import 'package:komga_reader/page_image.dart';
import 'package:komga_reader/screens/reader.dart';
import 'package:komga_reader/settings.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/helpers.dart';
import 'support/no_network.dart';
import 'support/reader_server.dart';

/// The reader's behaviour the test audit (2026-09-30, section 4) found untested: opening at the saved page, Mark
/// read / unread and Delete from the controls, remote scrubbing on the slider, the zoom keys and arrows while zoomed,
/// scroll-then-turn in fit width, a held key on the end card, a next book with no pages, and right to left (slider,
/// curl, edge swipe).

/// [ReaderServer] whose book B1 has [pageCount] pages and its own read progress, which saves, marks and unmarks change
/// as Komga would. Pages load ([png]) when [loads], else never; page thumbnails never come.
class BookServer extends ReaderServer {
  BookServer({this.pageCount = 3, this.progress, this.loads = false});
  static late Uint8List png;
  final int pageCount;
  final bool loads;
  Map<String, dynamic>? progress; // B1's readProgress
  final unmarked = <String>[];
  final deleted = <String>[];

  @override
  Future<Map<String, dynamic>?> book(String id) async => {...theBook, 'readProgress': progress};
  @override
  Future<List<dynamic>> pages(String bookId) async => [for (var n = 1; n <= pageCount; n++) {'number': n}];
  @override
  Future<Uint8List> pageBytes(String bookId, int number) => loads ? Future.value(png) : Completer<Uint8List>().future;
  @override
  Future<Uint8List> pageThumbBytes(String bookId, int number) => Completer<Uint8List>().future;
  bool failSaves = false; // Komga refuses saves (a network blip)
  Completer<void>? holdSave; // a save on its way, until completed

  @override
  Future<void> setProgress(String bookId, int page, {bool completed = false}) async {
    if (failSaves) throw KomgaUnreachable(baseUrl);
    await holdSave?.future;
    await super.setProgress(bookId, page, completed: completed);
    progress = {'page': page, 'completed': completed};
  }

  @override
  Future<void> markRead(String bookId) async {
    await super.markRead(bookId);
    progress = {'page': pageCount, 'completed': true};
  }

  @override
  Future<void> markUnread(String bookId) async {
    unmarked.add(bookId);
    progress = null;
  }

  @override
  Future<void> deleteBookFile(String bookId) async => deleted.add(bookId);
}

/// [ReaderServer] with a series B1 .. B[count] of 3-page books (pages never load), those in [empty] with no pages;
/// records each book opened.
class ChainServer extends ReaderServer {
  ChainServer({this.count = 3, this.empty = const {}});
  final int count;
  final Set<String> empty;
  final opened = <String>[];

  static Map<String, dynamic> b(String id) => {
        'id': id, 'seriesId': 'S1', 'seriesTitle': 'Test',
        'metadata': {'number': id.substring(1), 'title': 'Book ${id.substring(1)}'},
      };

  @override
  Future<Map<String, dynamic>?> book(String id) async => withProgress(b(id));

  @override
  Future<List<dynamic>> pages(String bookId) async {
    opened.add(bookId); // a book opened (its pages asked for once per opening; book() is asked before saves too)
    return empty.contains(bookId) ? [] : [{'number': 1}, {'number': 2}, {'number': 3}];
  }
  @override
  Future<Map<String, dynamic>?> nextBook(String bookId, {String? readListId}) async {
    nextCalls++;
    final n = int.parse(bookId.substring(1));
    return n < count ? b('B${n + 1}') : null;
  }
}

void main() {
  setUpAll(preloadShaders);
  setUp(() => SharedPreferences.setMockInitialValues({}));

  /// The reader on a route of its own (so closing it can be seen), over a page with an "open" button.
  Future<void> open(WidgetTester tester, ReaderServer api, {Map<String, dynamic>? book}) async {
    // a Scaffold underneath: a snackbar shown as the reader closes stays up to be read
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: Builder(builder: (context) => TextButton(
      onPressed: () => Navigator.of(context)
          .push(MaterialPageRoute(builder: (_) => ReaderScreen(api: api, book: book ?? api.theBook))),
      child: const Text('open'),
    )))));
    await tester.tap(find.text('open'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
  }

  /// The reader with pages that load (a [w] x [h] picture each) - decoded for real.
  Future<BookServer> openLoaded(WidgetTester tester, {int w = 200, int h = 300, int pages = 3}) async {
    BookServer.png = (await tester.runAsync(() => solidPng(w, h, const Color(0xFFE0D0B0))))!;
    final api = noNetwork(() => BookServer(pageCount: pages, loads: true));
    await tester.pumpWidget(MaterialApp(home: ReaderScreen(api: api, book: api.theBook)));
    await tester.pump();
    await waitUntil(() => shows(find.byType(PageCanvas)), tester: tester, step: const Duration(milliseconds: 50),
        reason: 'the pages decode');
    await tester.pump();
    return api;
  }

  Future<void> key(WidgetTester tester, LogicalKeyboardKey k) async {
    await tester.sendKeyEvent(k);
    await tester.pump();
  }

  /// A key, then long enough for a page turn or a pan step to play out.
  Future<void> keyAndSettle(WidgetTester tester, LogicalKeyboardKey k) async {
    await key(tester, k);
    await tester.pump(const Duration(milliseconds: 400));
  }

  double page(WidgetTester tester) => tester.widget<PageView>(find.byType(PageView)).controller!.page!;
  bool focused(String label) => FocusManager.instance.primaryFocus?.debugLabel == label;
  final current = find.byWidgetPredicate((w) => w is PageCanvas && w.current);
  Matrix4 zoomOf(WidgetTester tester) => tester
      .widget<InteractiveViewer>(find.descendant(of: current, matching: find.byType(InteractiveViewer)))
      .transformationController!
      .value;
  double sliderValue(WidgetTester tester) => tester.widget<Slider>(find.byType(Slider)).value;

  // ---- 1
  testWidgets('a book in progress opens at its saved page (nothing saved for just opening it); a finished one, or one '
      'not started, at page 1', (tester) async {
    for (final (progress, want, why) in [
      ({'page': 3, 'completed': false}, 2.0, 'in progress at page 3'),
      ({'page': 5, 'completed': true}, 0.0, 'finished: read again from the start'),
      (null, 0.0, 'not started'),
    ]) {
      final api = noNetwork(() => BookServer(pageCount: 5, progress: progress));
      await tester.pumpWidget(MaterialApp(home: ReaderScreen(api: api, book: api.theBook)));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      expect(page(tester), want, reason: why);
      await key(tester, LogicalKeyboardKey.enter); // the controls' slider shows the same page
      expect(sliderValue(tester), want, reason: why);
      await tester.pump(const Duration(seconds: 2));
      await tester.pumpWidget(const SizedBox()); // closed without a turn
      expect(api.saves, isEmpty, reason: '$why: opening at the saved page is not a turn');
    }
  });

  // ---- 2
  testWidgets('Mark read / Mark unread in the controls: Komga is told, the tick follows, and the page save after a turn '
      "doesn't undo it - nor does being on the last page after Mark unread (code review)", (tester) async {
    final api = noNetwork(() => BookServer());
    await open(tester, api);
    await keyAndSettle(tester, LogicalKeyboardKey.arrowRight); // page 2: a save is due 1.5 s after the turn
    await key(tester, LogicalKeyboardKey.enter);
    expect(find.byTooltip('Mark read'), findsOneWidget);
    expect(find.byIcon(Icons.check_circle_outline), findsOneWidget);

    await tester.tap(find.byTooltip('Mark read'));
    await tester.pump();
    await tester.pump();
    expect(api.marked, ['B1']);
    expect(find.byTooltip('Mark unread'), findsOneWidget, reason: 'the tick shows read');
    expect(find.byIcon(Icons.check_circle), findsOneWidget);
    await tester.pump(const Duration(seconds: 2)); // past the save delay
    expect(api.saves, isEmpty, reason: 'the page-2 save would have put the book back in progress');

    await tester.tap(find.byTooltip('Mark unread'));
    await tester.pump();
    await tester.pump();
    expect(api.unmarked, ['B1']);
    expect(find.byTooltip('Mark read'), findsOneWidget);

    // to the last page: read at once, and the tick says so
    await key(tester, LogicalKeyboardKey.escape); // controls away
    await keyAndSettle(tester, LogicalKeyboardKey.arrowRight);
    expect(page(tester), 2.0);
    expect(api.finished, [3]);
    await key(tester, LogicalKeyboardKey.enter);
    expect(find.byTooltip('Mark unread'), findsOneWidget);
    // Mark unread there: the tick shows unread though this is still the last page, and closing doesn't re-read it
    await tester.tap(find.byTooltip('Mark unread'));
    await tester.pump();
    await tester.pump();
    expect(api.unmarked, ['B1', 'B1']);
    expect(find.byTooltip('Mark read'), findsOneWidget, reason: 'unread, though on the last page');
    final saved = api.saves.length;
    await key(tester, LogicalKeyboardKey.escape);
    await key(tester, LogicalKeyboardKey.escape); // close the book
    await tester.pump(const Duration(seconds: 1));
    expect(find.byType(ReaderScreen), findsNothing);
    expect(api.saves.length, saved, reason: 'closing saved nothing over the Mark unread');
    expect(api.progress, isNull);
  });

  // ---- 3
  testWidgets('remote on the slider: OK starts scrubbing, Right/Left move the page shown (stopping at both ends) '
      'without turning, OK jumps there', (tester) async {
    final api = noNetwork(() => BookServer(pageCount: 5));
    await open(tester, api);
    await key(tester, LogicalKeyboardKey.enter); // controls
    await key(tester, LogicalKeyboardKey.arrowDown); // the bottom bar: Previous book
    await key(tester, LogicalKeyboardKey.arrowRight);
    expect(focused('ctl-slider'), isTrue);
    await key(tester, LogicalKeyboardKey.enter); // scrub
    expect(focused('ctl-slider'), isTrue);
    await key(tester, LogicalKeyboardKey.arrowRight);
    await key(tester, LogicalKeyboardKey.arrowRight);
    expect(sliderValue(tester), 2.0);
    expect(find.text('Page 3'), findsOneWidget); // the preview over the thumb
    expect(page(tester), 0.0, reason: 'not turned while scrubbing');
    for (var i = 0; i < 4; i++) {
      await key(tester, LogicalKeyboardKey.arrowLeft);
    }
    expect(sliderValue(tester), 0.0, reason: 'stops at the first page');
    expect(focused('ctl-slider'), isTrue, reason: 'scrubbing: Left is the page, not the control to the left');
    for (var i = 0; i < 9; i++) {
      await key(tester, LogicalKeyboardKey.arrowRight);
    }
    expect(sliderValue(tester), 4.0, reason: 'stops at the last page');
    expect(page(tester), 0.0);
    await key(tester, LogicalKeyboardKey.enter); // jump
    await tester.pump();
    expect(page(tester), 4.0);
    expect(find.text('Page 5'), findsNothing, reason: 'scrubbing over: no preview');
    expect(find.byTooltip('Next book'), findsOneWidget, reason: 'the controls stay up');
    await tester.pump(const Duration(seconds: 2));
    expect(api.finished, [5], reason: 'jumped to the last page: read');
  });

  // Esc / Back in the middle of a scrub cancel it: the page picked isn't gone to, the controls go away, and the next
  // scrub works as usual (user, 2026-10-02)
  group('cancelling a scrub', () {
    // the ways out: Esc (keyboard), the remote's Back key, Android's system Back
    final cancels = <String, Future<void> Function(WidgetTester)>{
      'Esc': (t) => t.sendKeyEvent(LogicalKeyboardKey.escape),
      "the remote's Back": (t) => t.sendKeyEvent(LogicalKeyboardKey.goBack, physicalKey: PhysicalKeyboardKey.escape),
      "Android's Back": (t) => t.binding.handlePopRoute(),
    };

    for (final MapEntry(key: how, value: cancel) in cancels.entries) {
      // a finger and a mouse drag reach the slider the same way (raw pointer events): both are tried
      for (final kind in [PointerDeviceKind.touch, PointerDeviceKind.mouse]) {
      testWidgets('dragging (${kind.name}), then $how: no page change, even when it lets go', (tester) async {
        await openLoaded(tester, pages: 20);
        await key(tester, LogicalKeyboardKey.enter); // controls
        final r = tester.getRect(find.byType(Slider));
        Offset at(int i) => Offset(r.left + 20 + i * (r.width - 40) / 19, r.center.dy);
        final g = await tester.startGesture(at(0), kind: kind);
        await g.moveTo(at(12));
        await tester.pump();
        expect(find.text('Page 13'), findsOneWidget);
        await cancel(tester);
        await tester.pump();
        expect(find.byType(Slider), findsNothing, reason: 'the controls are gone');
        await g.up();
        await tester.pump(const Duration(milliseconds: 400));
        expect(page(tester), 0.0, reason: 'cancelled: still on page 1');
        // and the slider works again afterwards (the cancelled finger isn't still holding it)
        await key(tester, LogicalKeyboardKey.enter);
        final g2 = await tester.startGesture(at(0), kind: kind);
        await g2.moveTo(at(5));
        await g2.up();
        await tester.pump(const Duration(milliseconds: 400));
        expect(page(tester), 5.0, reason: 'a scrub after the cancelled one goes where it was taken');
        await tester.pump(const Duration(seconds: 2));
      });
      }

      testWidgets('the remote scrubbing, then $how: no page change', (tester) async {
        await openLoaded(tester, pages: 20);
        await key(tester, LogicalKeyboardKey.enter); // controls
        await key(tester, LogicalKeyboardKey.arrowDown); // the bottom bar
        await key(tester, LogicalKeyboardKey.arrowRight);
        expect(focused('ctl-slider'), isTrue);
        await key(tester, LogicalKeyboardKey.enter); // scrub
        for (var i = 0; i < 6; i++) {
          await key(tester, LogicalKeyboardKey.arrowRight);
        }
        expect(find.text('Page 7'), findsOneWidget);
        await cancel(tester);
        await tester.pump(const Duration(milliseconds: 400));
        expect(find.byType(Slider), findsNothing, reason: 'the controls are gone');
        expect(page(tester), 0.0, reason: 'cancelled: still on page 1');
        expect(find.byType(ReaderScreen), findsOneWidget, reason: 'the book stays open');
        await tester.pump(const Duration(seconds: 2));
      });
    }
  });

  // Progress moved on another device while the book was open here (user, 2026-10-05): before a save, and on coming
  // back to the app, the reader asks Komga again and asks you. "Another device" is Komga's progress (BookServer's)
  // changed under the reader.
  group('read elsewhere meanwhile', () {
    Future<BookServer> reading(WidgetTester tester) async {
      final api = noNetwork(() => BookServer(pageCount: 8));
      await open(tester, api);
      await keyAndSettle(tester, LogicalKeyboardKey.arrowRight); // page 2 here
      await tester.pump(const Duration(seconds: 2)); // saved
      expect(api.progress, {'page': 2, 'completed': false});
      return api;
    }

    // a dialog opening or closing, a page jump (no settle: this book's pages never load, a spinner keeps turning)
    Future<void> frames(WidgetTester tester) async {
      for (var i = 0; i < 6; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
    }

    Future<void> turnAndWait(WidgetTester tester) async {
      await keyAndSettle(tester, LogicalKeyboardKey.arrowRight);
      await tester.pump(const Duration(seconds: 2)); // the save is due: the check first
      await tester.pump();
    }

    testWidgets('read further elsewhere: the next save asks; Go to page takes you there and saves nothing over it',
        (tester) async {
      final api = await reading(tester);
      api.progress = {'page': 6, 'completed': false}; // on the PC
      await turnAndWait(tester); // page 3 here
      expect(find.text('Read further on another device'), findsOneWidget);
      expect(find.text('On another device this book is on page 6.'), findsOneWidget);
      expect(find.text('Stay on page 3'), findsOneWidget);
      await tester.tap(find.text('Go to page 6'));
      await frames(tester);
      expect(page(tester), 5.0, reason: 'page 6');
      await tester.pump(const Duration(seconds: 2));
      expect(api.progress, {'page': 6, 'completed': false}, reason: "the other device's, not page 3 over it");
      await turnAndWait(tester); // on from there: saved, no question (it's this reader's now)
      expect(find.text('Read further on another device'), findsNothing);
      expect(api.progress, {'page': 7, 'completed': false});
    });

    testWidgets('read further elsewhere: Stay saves this page', (tester) async {
      final api = await reading(tester);
      api.progress = {'page': 6, 'completed': false};
      await turnAndWait(tester);
      await tester.tap(find.text('Stay on page 3'));
      await frames(tester);
      await tester.pump(const Duration(seconds: 2));
      expect(page(tester), 2.0);
      expect(api.progress, {'page': 3, 'completed': false}, reason: 'this page, saved');
    });

    testWidgets('finished elsewhere: Mark as read goes to the end card and the book stays read; Stay here carries '
        'on, in progress again', (tester) async {
      var api = await reading(tester);
      api.progress = {'page': 8, 'completed': true}; // finished on the PC
      await turnAndWait(tester);
      expect(find.text('Finished on another device'), findsOneWidget);
      await tester.tap(find.text('Mark as read'));
      await frames(tester);
      await tester.pump(const Duration(seconds: 2));
      expect(find.text('End of book'), findsOneWidget, reason: 'the end card, with the next book');
      expect(api.progress!['completed'], isTrue, reason: 'still read');
      await tester.pumpWidget(const SizedBox());

      api = await reading(tester);
      api.progress = {'page': 8, 'completed': true};
      await turnAndWait(tester);
      await tester.tap(find.text('Stay here'));
      await frames(tester);
      await tester.pump(const Duration(seconds: 2));
      expect(api.progress, {'page': 3, 'completed': false}, reason: 'in progress again, here');
    });

    testWidgets('coming back to the app with the book open asks at once (no page turn needed); OK on the remote is '
        'Stay', (tester) async {
      final api = await reading(tester);
      api.progress = {'page': 6, 'completed': false};
      for (final s in [AppLifecycleState.inactive, AppLifecycleState.hidden, AppLifecycleState.paused, // locked
        AppLifecycleState.hidden, AppLifecycleState.inactive, AppLifecycleState.resumed]) { // unlocked
        tester.binding.handleAppLifecycleStateChanged(s);
      }
      await tester.pump();
      await tester.pump();
      expect(find.text('Read further on another device'), findsOneWidget);
      expect(find.text('Stay on page 2'), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter); // OK: Stay (focused)
      await frames(tester);
      expect(find.text('Read further on another device'), findsNothing);
      expect(page(tester), 1.0, reason: 'stayed on page 2');
      await tester.pump(const Duration(seconds: 2));
    });

    testWidgets("a save that failed (a network blip), then a turn: no question - Komga still had this reader's "
        'earlier page, which used to be taken for another device (code review 2026-10-05, #4)', (tester) async {
      final api = await reading(tester);
      api.failSaves = true;
      await turnAndWait(tester); // page 3: refused
      expect(api.progress, {'page': 2, 'completed': false});
      api.failSaves = false;
      await turnAndWait(tester); // page 4
      expect(find.text('Read further on another device'), findsNothing);
      expect(api.progress, {'page': 4, 'completed': false});
    });

    testWidgets('coming back to the app while a save is on its way: no question (#4)', (tester) async {
      final api = await reading(tester);
      api.holdSave = Completer<void>();
      await turnAndWait(tester); // page 3's save: on its way
      for (final s in [AppLifecycleState.inactive, AppLifecycleState.hidden, AppLifecycleState.paused,
        AppLifecycleState.hidden, AppLifecycleState.inactive, AppLifecycleState.resumed]) {
        tester.binding.handleAppLifecycleStateChanged(s);
      }
      await tester.pump();
      api.holdSave!.complete();
      api.holdSave = null;
      await frames(tester);
      expect(find.text('Read further on another device'), findsNothing);
      expect(api.progress, {'page': 3, 'completed': false});
    });

    testWidgets('a save coming due while the question is on screen waits for the answer: Go to page drops it (it '
        "used to save over the other device's page with the question still up - #5)", (tester) async {
      final api = await reading(tester);
      await keyAndSettle(tester, LogicalKeyboardKey.arrowRight); // page 3 here, its save due in a moment
      api.progress = {'page': 6, 'completed': false}; // the PC
      for (final s in [AppLifecycleState.inactive, AppLifecycleState.hidden, AppLifecycleState.paused,
        AppLifecycleState.hidden, AppLifecycleState.inactive, AppLifecycleState.resumed]) {
        tester.binding.handleAppLifecycleStateChanged(s);
      }
      await tester.pump();
      await tester.pump();
      expect(find.text('Read further on another device'), findsOneWidget);
      await tester.pump(const Duration(seconds: 3)); // page 3's save comes due, the question still up
      await tester.pump();
      expect(api.progress, {'page': 6, 'completed': false}, reason: 'nothing saved under the question');
      await tester.tap(find.text('Go to page 6'));
      await frames(tester);
      await tester.pump(const Duration(seconds: 2));
      expect(api.progress, {'page': 6, 'completed': false}, reason: "the other device's stands");
    });

    testWidgets('closing the book after it moved elsewhere: nothing saved over it, and no question', (tester) async {
      final api = await reading(tester);
      await keyAndSettle(tester, LogicalKeyboardKey.arrowRight); // page 3 here, its save still to come
      api.progress = {'page': 6, 'completed': false}; // the PC, meanwhile
      await tester.binding.handlePopRoute(); // close
      await frames(tester);
      expect(find.byType(ReaderScreen), findsNothing);
      expect(find.text('Read further on another device'), findsNothing);
      expect(api.progress, {'page': 6, 'completed': false}, reason: "the other device's stands");
    });
  });

  // ---- 4
  testWidgets('zoom keys: + zooms in a step at a time, - back out to fit; in fit width they do nothing', (tester) async {
    await openLoaded(tester);
    double scale() => zoomOf(tester).getMaxScaleOnAxis();
    expect(scale(), 1.0);
    await keyAndSettle(tester, LogicalKeyboardKey.equal);
    expect(scale(), closeTo(1.5, 1e-6));
    await keyAndSettle(tester, LogicalKeyboardKey.numpadAdd);
    expect(scale(), closeTo(2.25, 1e-6));
    await keyAndSettle(tester, LogicalKeyboardKey.minus);
    expect(scale(), closeTo(1.5, 1e-6));
    await keyAndSettle(tester, LogicalKeyboardKey.minus);
    expect(scale(), closeTo(1, 1e-6));
    expect(page(tester), 0.0, reason: 'zooming turns nothing');

    // fit width (the top bar's fit button), then back round to fit screen: the zoom key in between did nothing
    await key(tester, LogicalKeyboardKey.enter);
    await tester.tap(find.byTooltip('Fit screen'));
    await tester.pump();
    expect(find.byTooltip('Fit width'), findsOneWidget);
    await key(tester, LogicalKeyboardKey.escape);
    await keyAndSettle(tester, LogicalKeyboardKey.equal);
    await key(tester, LogicalKeyboardKey.enter);
    await tester.tap(find.byTooltip('Fit width'));
    await tester.pump();
    await tester.tap(find.byTooltip('Fit height'));
    await tester.pump();
    await tester.tap(find.byTooltip('Original size')); // the fourth fit (user, 2026-10-02), then round again
    await tester.pump();
    expect(find.byTooltip('Fit screen'), findsOneWidget);
    await tester.pump(const Duration(milliseconds: 400));
    expect(scale(), closeTo(1, 1e-6), reason: 'the key pressed in fit width left the page at fit');
    await tester.pump(const Duration(seconds: 2));
  });

  // ---- 5
  testWidgets('zoomed in, the arrows pan along the page instead of turning; at its end the next press turns',
      (tester) async {
    // 800 x 600 screen, a 200 x 300 page fitted as 400 x 600; x1.5 = 600 x 900: fits across, 300 to go down
    await openLoaded(tester);
    double y() => zoomOf(tester).getTranslation().y;
    await keyAndSettle(tester, LogicalKeyboardKey.equal);
    expect(y(), closeTo(-150, 0.5)); // zoomed on the middle
    await keyAndSettle(tester, LogicalKeyboardKey.arrowRight);
    expect(page(tester), 0.0, reason: 'zoomed: panned, not turned');
    expect(y(), closeTo(-300, 0.5), reason: 'down to the bottom of the page');
    await keyAndSettle(tester, LogicalKeyboardKey.arrowLeft);
    expect(page(tester), 0.0, reason: 'back pans back too');
    expect(y(), closeTo(0, 0.5), reason: 'up to the top');
    await keyAndSettle(tester, LogicalKeyboardKey.arrowRight);
    expect(y(), closeTo(-300, 0.5));
    expect(page(tester), 0.0);
    await keyAndSettle(tester, LogicalKeyboardKey.arrowRight); // at the end of the page: the turn
    expect(page(tester), 1.0);
    await keyAndSettle(tester, LogicalKeyboardKey.arrowRight); // the next page isn't zoomed: an ordinary turn
    expect(page(tester), 2.0);
    await tester.pump(const Duration(seconds: 2));
  });

  // ---- 6
  testWidgets('fit width, a page taller than the screen: forward scrolls down it first, then turns; back scrolls up, '
      'then opens the previous page at its end', (tester) async {
    // 800 x 600 screen, a 200 x 300 page in fit width = 800 x 1200: 600 to scroll, opening centred (300)
    await openLoaded(tester);
    await key(tester, LogicalKeyboardKey.enter);
    await tester.tap(find.byTooltip('Fit screen')); // -> fit width, this book
    await tester.pump();
    await key(tester, LogicalKeyboardKey.escape);
    await tester.pump();
    await tester.pump();
    ScrollController scroll() => tester.widget<PageCanvas>(current).scroll;
    expect(scroll().offset, 300);

    await keyAndSettle(tester, LogicalKeyboardKey.arrowRight);
    expect(page(tester), 0.0, reason: 'scrolled, not turned');
    expect(scroll().offset, 600, reason: 'down to the bottom');
    await keyAndSettle(tester, LogicalKeyboardKey.arrowRight);
    expect(page(tester), 1.0, reason: 'at the bottom: turned');

    await keyAndSettle(tester, LogicalKeyboardKey.arrowLeft);
    expect(page(tester), 1.0, reason: 'scrolled back up first');
    expect(scroll().offset, 0);
    await keyAndSettle(tester, LogicalKeyboardKey.arrowLeft);
    await tester.pump();
    expect(page(tester), 0.0);
    expect(scroll().offset, 600, reason: 'the previous page opens at its end');
    await tester.pump(const Duration(seconds: 2));
  });

  // ---- 7
  testWidgets('Delete book in the controls: Cancel deletes nothing; Delete deletes the file, says so and closes the '
      'book, saving no progress to it', (tester) async {
    final api = noNetwork(() => BookServer());
    await open(tester, api);
    await key(tester, LogicalKeyboardKey.enter);
    await tester.tap(find.byTooltip('Delete book'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('Delete "Test #1"?'), findsOneWidget);
    await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('Delete "Test #1"?'), findsNothing);
    expect(api.deleted, isEmpty, reason: 'Cancel');
    expect(find.byType(ReaderScreen), findsOneWidget);

    await key(tester, LogicalKeyboardKey.escape); // controls away
    await keyAndSettle(tester, LogicalKeyboardKey.arrowRight); // a turn: its save is due in 1.5 s
    await key(tester, LogicalKeyboardKey.enter);
    await tester.tap(find.byTooltip('Delete book'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.widgetWithText(TextButton, 'Delete'));
    await tester.pump();
    await tester.pump();
    expect(api.deleted, ['B1']);
    expect(find.text('Deleted Test #1'), findsOneWidget);
    await tester.pump(const Duration(seconds: 1));
    expect(find.byType(ReaderScreen), findsNothing, reason: 'closed');
    await tester.pump(const Duration(seconds: 5)); // the snackbar
    expect(api.saves, isEmpty, reason: 'no progress saved to a deleted book');
  });

  // ---- 8
  testWidgets("a key held from the last page onto the end card: its repeats don't open the next book; a fresh press "
      'does, at its first page', (tester) async {
    final api = noNetwork(() => ChainServer());
    await tester.pumpWidget(MaterialApp(home: ReaderScreen(api: api, book: api.theBook)));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    await keyAndSettle(tester, LogicalKeyboardKey.arrowRight);
    await keyAndSettle(tester, LogicalKeyboardKey.arrowRight); // the last page
    await tester.sendKeyDownEvent(LogicalKeyboardKey.arrowRight); // held on
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('End of book'), findsOneWidget);
    for (var i = 0; i < 4; i++) {
      await tester.sendKeyRepeatEvent(LogicalKeyboardKey.arrowRight);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
    }
    await tester.sendKeyUpEvent(LogicalKeyboardKey.arrowRight);
    await tester.pump(const Duration(milliseconds: 500));
    expect(api.opened, ['B1'], reason: 'the repeats opened nothing');
    expect(api.marked, isEmpty);
    expect(find.text('End of book'), findsOneWidget);

    await key(tester, LogicalKeyboardKey.arrowRight); // a fresh press
    await tester.pump(const Duration(milliseconds: 500));
    expect(api.opened, ['B1', 'B2']);
    expect(api.marked, ['B1']);
    expect(page(tester), 0.0, reason: "B2's first page");
    await tester.pump(const Duration(seconds: 2));
  });

  // ---- 9
  group('a next book with no pages', () {
    testWidgets("from the end card: it says so and the book being read stays; its Next book goes on past it",
        (tester) async {
      final api = noNetwork(() => ChainServer(empty: {'B2'})); // B1 -> B2 (no pages) -> B3
      await tester.pumpWidget(MaterialApp(home: ReaderScreen(api: api, book: api.theBook)));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      for (var i = 0; i < 3; i++) {
        await keyAndSettle(tester, LogicalKeyboardKey.arrowRight);
      }
      await key(tester, LogicalKeyboardKey.arrowRight); // on past the end card: B2
      await tester.pump(const Duration(milliseconds: 500));
      expect(api.opened, ['B1', 'B2']);
      expect(find.textContaining('"Test #2" has no pages'), findsOneWidget);
      expect(find.text('End of book'), findsOneWidget, reason: "B1's end card stays");
      await tester.tap(find.widgetWithText(SnackBarAction, 'Next book'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      expect(api.opened.last, 'B3');
      expect(page(tester), 0.0, reason: "B3's first page");
      await key(tester, LogicalKeyboardKey.enter);
      expect(find.text('Test #3'), findsOneWidget, reason: 'B3 is the book open');
      await tester.pump(const Duration(seconds: 5));
    });

    testWidgets("opened directly: the screen's Next book goes on to the one after; with none after it, it says so "
        'and closes', (tester) async {
      for (final count in [3, 2]) {
        final api = noNetwork(() => ChainServer(count: count, empty: {'B2'}));
        await open(tester, api, book: ChainServer.b('B2'));
        expect(find.textContaining('has no pages'), findsOneWidget);
        await tester.tap(find.widgetWithText(TextButton, 'Next book'));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 500));
        if (count == 3) {
          expect(api.opened.last, 'B3');
          expect(find.byType(PageView), findsOneWidget, reason: 'B3 open');
          expect(find.textContaining('has no pages'), findsNothing);
        } else {
          expect(find.text('End of the series'), findsOneWidget);
          await tester.pump(const Duration(seconds: 1));
          expect(find.byType(ReaderScreen), findsNothing, reason: 'nothing after it: closed');
        }
        await tester.pump(const Duration(seconds: 5));
        await tester.pumpWidget(const SizedBox());
      }
    });
  });

  // ---- 10
  group('right to left', () {
    setUp(() => ReaderServer.direction = 'RIGHT_TO_LEFT');
    tearDown(() => ReaderServer.direction = 'LEFT_TO_RIGHT');

    testWidgets('the slider runs from the right: Left scrubs forward, Right back; a touch at its left end is the last '
        'page', (tester) async {
      final api = noNetwork(() => BookServer(pageCount: 5));
      await open(tester, api);
      await key(tester, LogicalKeyboardKey.enter);
      expect(Directionality.of(tester.element(find.byType(Slider))), TextDirection.rtl);
      await key(tester, LogicalKeyboardKey.arrowDown);
      await key(tester, LogicalKeyboardKey.arrowRight); // moving along the bar isn't mirrored
      expect(focused('ctl-slider'), isTrue);
      await key(tester, LogicalKeyboardKey.enter);
      await key(tester, LogicalKeyboardKey.arrowLeft);
      await key(tester, LogicalKeyboardKey.arrowLeft);
      expect(sliderValue(tester), 2.0, reason: 'Left = forward');
      await key(tester, LogicalKeyboardKey.arrowRight);
      expect(sliderValue(tester), 1.0, reason: 'Right = back');
      await key(tester, LogicalKeyboardKey.enter);
      await tester.pump();
      expect(page(tester), 1.0);

      final r = tester.getRect(find.byType(Slider));
      await tester.tapAt(Offset(r.left + 20, r.center.dy));
      await tester.pump();
      expect(page(tester), 4.0, reason: 'the left end is the last page');
      await tester.pump(const Duration(seconds: 2));
    });

    testWidgets('page curl: a drag from left to right turns forward, the curl drawn mirrored', (tester) async {
      final s = AppSettings.instance;
      s.setDisplay(s.display.copyWith(pageTurn: PageTurn.curl));
      addTearDown(() => s.setDisplay(s.display.copyWith(pageTurn: PageTurn.swipe)));
      expect(PageCurl.loaded, isNotNull);
      final api = noNetwork(() => BookServer());
      await open(tester, api);
      await tester.pump();
      final size = tester.getSize(find.byType(PageView));
      final y = size.height / 2;
      final g = await tester.startGesture(Offset(size.width * 0.1, y));
      for (var i = 1; i <= 20; i++) {
        await g.moveTo(Offset(size.width * 0.1 + i * size.width * 0.04, y));
        await tester.pump(const Duration(milliseconds: 50));
      }
      final painter = find.byWidgetPredicate((w) => w is CustomPaint && w.painter is PageCurlPainter);
      expect(painter, findsOneWidget, reason: 'the page follows the finger');
      expect((tester.widget<CustomPaint>(painter).painter! as PageCurlPainter).mirror, isTrue);
      await g.up();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      await tester.pump();
      expect(page(tester), 1.0, reason: 'turned forward');
      await tester.pump(const Duration(seconds: 2));
      expect(api.saves, [2]);
    });

    testWidgets('fit height, a spread wider than the screen: dragging on past its edge towards the start of the book '
        'does nothing; towards the end turns forward, on to the end card', (tester) async {
      // 800 x 600 screen, a 400 x 200 spread in fit height = 1200 x 600: drags sideways, 400 to go, opens centred.
      // One page: with more, the turn that drops a spread out of the page view hits the bug in the skipped test below.
      final api = await openLoaded(tester, w: 400, h: 200, pages: 1);
      await key(tester, LogicalKeyboardKey.enter);
      await tester.tap(find.byTooltip('Fit screen'));
      await tester.pump();
      await tester.tap(find.byTooltip('Fit width'));
      await tester.pump();
      expect(find.byTooltip('Fit height'), findsOneWidget);
      await key(tester, LogicalKeyboardKey.escape);
      await tester.pump();
      await tester.pump();
      final centre = tester.getCenter(find.byType(PageView));
      Future<void> pull(double dx) async {
        await tester.dragFrom(centre, Offset(dx, 0));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 400));
        await tester.pump();
      }

      await pull(-1000); // right to left: leftwards is back - at the first page, nowhere to go
      expect(page(tester), 0.0);
      expect(tester.takeException(), isNull);
      await pull(1000); // rightwards: forward - past the last page, the end card
      expect(page(tester), 1.0);
      expect(find.text('End of book'), findsOneWidget);
      await tester.pump(const Duration(seconds: 2)); // (onto the end card the save waits for the page to settle)
      expect(api.finished, [1]);
    });
  });

  // Bug found 2026-09-30 (missing-tests audit): a fit-height page wider than the screen tells the reader "no longer
  // panning" from PageCanvas.dispose, and the reader called setState at once - while the framework was unmounting
  // that page at the end of a frame. Debug builds asserted "setState() or markNeedsBuild() called when widget tree
  // was locked" whenever such a page dropped out of the page view (two turns on). Fixed: reader.dart _setSideways.
  testWidgets('fit height, wide pages: turning on until the first spread leaves the page view raises no error',
      (tester) async {
    await openLoaded(tester, w: 400, h: 200); // 3 spreads, 1200 x 600 in fit height
    await key(tester, LogicalKeyboardKey.enter);
    await tester.tap(find.byTooltip('Fit screen'));
    await tester.pump();
    await tester.tap(find.byTooltip('Fit width'));
    await tester.pump();
    await key(tester, LogicalKeyboardKey.escape);
    await tester.pump();
    // each spread: Right scrolls across it to its end, then turns
    for (var i = 0; i < 8 && page(tester) < 2; i++) {
      await keyAndSettle(tester, LogicalKeyboardKey.arrowRight);
    }
    expect(page(tester), 2.0); // page 3: page 1 is two away, unmounted
    expect(tester.takeException(), isNull);
    await tester.pump(const Duration(seconds: 2));
  });
}
