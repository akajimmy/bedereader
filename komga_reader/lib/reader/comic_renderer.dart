import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';

import '../api.dart';
import '../errors.dart';
import '../page_curl.dart';
import '../page_image.dart';
import '../screen.dart';
import '../settings.dart';
import '../widgets/display_panel.dart';
import '../widgets/error_text.dart';
import 'position_row.dart';
import 'reader_bars.dart';
import 'renderer.dart';

/// Komga lists the book with no pages (a damaged file, or not analysed yet).
class NoPages implements Exception {}

/// A comic's pages loaded for showing (from [ComicRenderer.prepare]).
class ComicPages {
  const ComicPages(this.pages, this.direction);
  final List<dynamic> pages;
  final String? direction; // the series' reading direction in Komga
}

/// The comic renderer (the one Reader, user 2026-10-07): a book's page images - the page view and its turns (wipe,
/// flip, 3D curl), fit, zoom, pan and scrolling within a page, double-tap zoom, the reading direction, the page
/// strip and the slider's page pictures, Save / Copy page, and the comic buttons on the Reader's bars (fit, pages,
/// image and reader settings). The Reader around it does the rest; this asks it through [host].
///
/// Places are the pages, 0..[last]; [last] + 1 is the end card.
class ComicRenderer extends Renderer {
  ComicRenderer(super.host) {
    PageCurl.program().ignore(); // load the curl shader ahead of the first turn
    _curlAnim = AnimationController(vsync: host.vsync, duration: const Duration(milliseconds: 380))
      ..addListener(_onCurlTick)
      ..addStatusListener((s) {
        if (s == AnimationStatus.completed) _endCurl();
      });
  }

  AppSettings get _settings => AppSettings.instance;
  bool _disposed = false;

  @override
  BookKind get kind => BookKind.comics;

  void _changed() {
    if (!_disposed) notifyListeners();
  }

  Map _book = const {};
  List<dynamic> pages = [];
  PageLoader? _loader;
  PageController? pc;
  int index = 0;
  @override
  int get place => index;
  @override
  int get last => pages.length - 1;
  @override
  bool get opened => pc != null;
  bool get onEndCard => index > last;
  @override
  int openedAt = 0;

  String? get seriesId => _book['seriesId'] as String?;

  // ---- the look: the series' settings as they apply - with the fit for this book only (the top bar's fit button
  // while the series follows the default layout) on top
  ReaderPrefs get prefs {
    final p = _settings.prefsFor(seriesId);
    final f = _bookFit;
    return f == null || p.ownLayout ? p : p.copyWith(fit: f);
  }

  FitMode? _bookFit; // this book only, for now: not saved; a book opening goes back to the default (user, 2026-09-30)
  @override
  Color get background => prefs.background.colour; // the series' own, or the reading defaults'
  @override
  Color ink(double alpha) => prefs.background.ink.withValues(alpha: alpha); // text on it

  /// The series' reading direction in Komga (LEFT_TO_RIGHT, RIGHT_TO_LEFT, VERTICAL, WEBTOON), fetched on open.
  String? _komgaDirection;
  String? _directionSeries; // which series _komgaDirection belongs to

  /// Right to left: forced per series, or (on Auto) because Komga says so. Vertical/webtoon read as left to right.
  @override
  bool get rtl => switch (prefs.direction) {
        ReadingDirection.rtl => true,
        ReadingDirection.ltr => false,
        ReadingDirection.auto => _komgaDirection == 'RIGHT_TO_LEFT',
      };

  // ---- opening a book

  /// [book]'s pages and its series' reading direction, from Komga - nothing shown changes (the book being read stays
  /// until [show]). Throws [NoPages] for a book with none.
  @override
  Future<ComicPages> prepare(Map book) async {
    final pages = await api.pages(book['id'] as String);
    if (pages.isEmpty) throw NoPages();
    final seriesId = book['seriesId'] as String?;
    String? direction = _komgaDirection;
    if (seriesId != null && seriesId != _directionSeries) {
      try {
        direction = (await api.oneSeries(seriesId))?['metadata']?['readingDirection'] as String?;
      } catch (_) {
        direction = null; // unknown: left to right
      }
    }
    return ComicPages(pages, direction);
  }

  /// The page [book] opens at: where its progress is (a finished one: the start).
  static int startOf(Map book, int pageCount) {
    final rp = book['readProgress'];
    return rp == null || rp['completed'] == true ? 0 : ((rp['page'] as int) - 1).clamp(0, pageCount - 1);
  }

  /// Shows [book] (prepared): its pages from where its progress is. The last book's page view goes once the new one has
  /// replaced it.
  @override
  void show(Map book, Object prepared) {
    prepared as ComicPages;
    final start = startOf(book, prepared.pages.length);
    openedAt = start;
    _openedProgress = progressOf(book);
    final oldPc = pc, oldScrolls = List.of(_scrolls.values);
    _scrolls.clear();
    _clearThumbs();
    final pages = prepared.pages;
    final loader = PageLoader(api, book['id'] as String,
        [for (var i = 0; i < pages.length; i++) (pages[i]['number'] ?? i + 1) as int]);
    loader.around(start);
    _komgaDirection = prepared.direction;
    _directionSeries = book['seriesId'] as String?;
    // the last book's page shapes (the curl drew the new book's first turn in them - #17) and a page left to open at
    // its end (a later page with that number opened scrolled to its end - #22) go with it
    _pageRects.clear();
    _startAtEnd = null;
    _book = book;
    this.pages = pages;
    index = start;
    _loader = loader;
    zoomed = false;
    _bookFit = null;
    pc = PageController(initialPage: start, keepPage: false); // (a kept page would be the last book's)
    WidgetsBinding.instance.addPostFrameCallback((_) {
      oldPc?.dispose();
      for (final c in oldScrolls) {
        c.dispose();
      }
    });
    _changed();
  }

  @override
  void bookChanged(Map book) => _book = book;
  @override
  Map get book => _book;

  // ---- the strip as the Reader's row over the bottom bar; the slider's Up / Down
  @override
  Widget? above(BuildContext context) => stripShown ? strip(context) : null;
  @override
  FocusNode? get rowNode => stripShown ? stripNode : null;
  @override
  FocusNode? get rowBelow => pages.length > 1 ? pagesNode : null;
  @override
  void rowFocus() => stripFocus();
  @override
  bool get sliderUpDown => true;

  // ---- what's said
  @override
  ({SpotText? left, SpotText? centre, SpotText? right}) spots(int place) => (
        // the title on top, the page and how far through on the left (the right spot is free - mockup "A, comic")
        centre: SpotText(_bookTitle, 'title'),
        left: SpotText('Pg. ${place + 1}/${pages.length} · ${((place + 1) / pages.length * 100).round()}%', 'page'),
        right: null,
      );

  /// "Saga #1 - Chapter One": the series and number, and the book's own title when it says more.
  String get _bookTitle {
    final heading = titleOf(_book);
    final title = '${_book['metadata']?['title'] ?? ''}';
    return title.isEmpty || title == heading || heading.endsWith(title) ? heading : '$heading - $title';
  }

  @override
  String corner(int place) => '${place + 1} / ${pages.length}';
  @override
  String placeLabel(int place) => 'Page ${place + 1}';
  @override
  String get whereText => 'You are on page ${index + 1} of ${pages.length}.';

  // ---- progress on Komga: the page (from 1, or null: not started) and finished

  static (int?, bool) progressOf(Map book) {
    final rp = book['readProgress'];
    return rp == null ? (null, false) : ((rp['page'] as num?)?.toInt(), rp['completed'] == true);
  }

  (int?, bool)? _openedProgress;
  @override
  Object? get openedProgress => _openedProgress;

  @override
  Future<Object?> Function() progressReader() {
    final id = _book['id'] as String;
    return () async => progressOf((await api.book(id)) ?? const {});
  }

  @override
  Future<Object?> Function() progressSaver(int place) {
    // the end card counts as the last page: finished
    final page = math.min(place, last), id = _book['id'] as String, completed = page >= last;
    return () async {
      await api.setProgress(id, page + 1, completed: completed);
      return (page + 1, completed);
    };
  }

  @override
  Future<Object?> progressAfterMark(Map fresh) async => progressOf(fresh);

  @override
  bool finishedAt(int place) => place >= last;

  @override
  ElsewhereText elsewhereText(Object? moved, int here) {
    final (page, finished) = moved as (int?, bool);
    final at = math.min(here, last) + 1;
    return (
      title: finished ? 'Finished on another device' : 'Read further on another device',
      text: finished
          ? 'This book was read to the end on another device.'
          : page == null
              ? 'This book was marked unread on another device.'
              : 'On another device this book is on page $page.',
      stay: finished ? 'Stay here' : 'Stay on page $at',
      go: finished ? 'Mark as read' : 'Go to page ${(page ?? 1).clamp(1, pages.length)}',
    );
  }

  @override
  int acceptElsewhere(Object? moved) {
    final (page, finished) = moved as (int?, bool);
    _book = {..._book, 'readProgress': finished
        ? {'page': pages.length, 'completed': true}
        : page == null ? null : {'page': page, 'completed': false}};
    // finished: the end card, with the next book
    return finished ? pages.length : (page ?? 1).clamp(1, pages.length) - 1;
  }

  @override
  void dispose() {
    _disposed = true;
    _tapTimer?.cancel();
    _curlAnim.dispose();
    _curl?.dispose();
    _curlShader?.dispose();
    _curlMoved.dispose();
    _idle?.complete(); // nothing left waiting
    pc?.dispose();
    for (final c in _scrolls.values) {
      c.dispose();
    }
    _scrolls.clear();
    _stripScroll.dispose();
    for (final n in [fitNode, pagesNode, imageNode, readerNode, stripNode]) {
      n.dispose();
    }
    super.dispose();
  }

  // ---- where the page view is

  int? _startAtEnd; // page to show from its bottom/right end (came back from the next page)
  bool zoomed = false; // pinch-zoomed in: page swiping is paused so a drag pans the page
  final Set<int> _sideways = {}; // pages (fit height, wider than the screen) that a drag moves sideways
  /// A page says whether a drag moves it sideways. It also says "no longer" from its dispose - while the framework is
  /// unmounting it at the end of a frame, when setState isn't allowed - so the rebuild then waits for the frame to end
  /// (missing-tests audit, 2026-09-30: debug builds asserted "widget tree was locked" two turns past a wide page).
  void _setSideways(int i, bool pans) {
    if (!(pans ? _sideways.add(i) : _sideways.remove(i))) return;
    if (SchedulerBinding.instance.schedulerPhase == SchedulerPhase.persistentCallbacks) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _changed());
    } else {
      _changed();
    }
  }

  int _fingers = 0; // two or more on the page = a pinch: page swiping pauses at once so it can't steal the gesture
  final Map<int, ScrollController> _scrolls = {};
  final Map<int, bool Function(bool forward)> _steppers = {}; // zoomed-in pan steps, per page (page_image.dart)
  final Map<int, void Function(Offset global)> _zoomers = {}; // double-tap zoom, per page (page_image.dart)
  final Map<int, void Function(bool zoomIn)> _zoomSteps = {}; // zoom keys, per page (page_image.dart)

  ScrollController _scrollFor(int i) => _scrolls.putIfAbsent(i, ScrollController.new);

  void _setFingers(int n) {
    final pinch = n > 1;
    final wasPinch = _fingers > 1;
    _fingers = n < 0 ? 0 : n;
    if (pinch != wasPinch) _changed();
  }

  /// The page view moved to [i] (a turn, a swipe or a jump).
  void _onPage(int i) {
    if (_startAtEnd != null && _startAtEnd != i) _startAtEnd = null; // (#22) only the page turned back to
    index = i;
    zoomed = false;
    if (i <= last) _loader?.around(i);
    // a curl moves the page view underneath as it starts: that counts once the curl completes (_endCurl) - one let go
    // before halfway leaves no trace (code review, 2026-09-30: it un-read a finished book)
    host.pageChanged(i, curling: _curl != null);
  }

  /// To [place] at once (the slider, the strip, another device's page) - not a turn (the Reader knows it's coming).
  @override
  void jumpTo(int place) {
    finishCurlNow();
    pc?.jumpToPage(place);
  }

  // ---- turning (the page after the last is the "end of book" card)
  static const _turn = Duration(milliseconds: 180);

  bool get _blocked => pc == null || host.busy || _curlSettling;

  /// Forward: in fit width/height scroll on through the page first, then turn; from the end card, the next book.
  @override
  void forward({bool snap = false}) {
    if (_blocked) return;
    if (index >= pages.length) {
      host.nextBook();
      return;
    }
    if (zoomed && (_steppers[index]?.call(true) ?? false)) return; // zoomed in: pan along the page first
    final c = _scrolls[index];
    if (prefs.fit != FitMode.screen && c != null && c.hasClients) {
      final p = c.position;
      if (p.pixels < p.maxScrollExtent - 1) {
        c.animateTo((p.pixels + p.viewportDimension * 0.85).clamp(0, p.maxScrollExtent), duration: _turn,
            curve: Curves.easeOut);
        return;
      }
    }
    _turnPage(next: true);
  }

  /// Back: scroll back through the page first; the previous page then opens at its end.
  @override
  void back({bool snap = false}) {
    if (_blocked) return;
    if (zoomed && (_steppers[index]?.call(false) ?? false)) return; // zoomed in: pan back along the page first
    final c = _scrolls[index];
    if (prefs.fit != FitMode.screen && c != null && c.hasClients && c.position.pixels > 1) {
      final p = c.position;
      c.animateTo((p.pixels - p.viewportDimension * 0.85).clamp(0, p.maxScrollExtent), duration: _turn,
          curve: Curves.easeOut);
      return;
    }
    if (index == 0) return;
    if (prefs.fit != FitMode.screen) {
      _scrolls.remove(index - 1)?.dispose(); // fresh controller so the page lays out again from its end
      _startAtEnd = index - 1;
    }
    _turnPage(next: false);
  }

  /// One page on or back, in the chosen animation: Wipe (slide), Instant flip, or 3D page curl.
  void _turnPage({required bool next}) {
    if (host.busy || _curlSettling) return;
    final target = next ? index + 1 : index - 1;
    if (target < 0 || target > pages.length) return;
    if (_curlMode) {
      final page = _pageRect(next ? index : target);
      final grab = Offset(page.width, page.height * 0.72);
      final start = next ? grab : Offset(PageCurl.gone(page.width), grab.dy);
      if (_startCurl(next: next, page: page, grab: grab, finger: start)) {
        _animateCurl(complete: true);
        return;
      }
      pc!.jumpToPage(target); // couldn't snapshot the page: turn instantly
    } else if (_settings.display.pageTurn == PageTurn.flip) {
      pc!.jumpToPage(target);
    } else {
      pc!.animateToPage(target, duration: _turn, curve: Curves.easeOut);
    }
  }

  /// A Zoom in / Zoom out step (the keys) - fit screen, the only fit that zooms.
  @override
  void zoomStep(bool zoomIn) {
    if (prefs.fit == FitMode.screen) _zoomSteps[index]?.call(zoomIn);
  }

  // ---- the mouse wheel over the page (desktop): in fit width/height it scrolls through the page first; otherwise
  // (or at the page's end) one notch turns one page - trackpad flicks are gathered up so they don't skip several pages
  double _wheelAcc = 0; // mouse wheel travel towards the next page turn
  DateTime _lastWheelTurn = DateTime(0);

  void wheel(double dy) {
    if (host.controlsUp || pc == null) return;
    final c = _scrolls[index];
    if (prefs.fit != FitMode.screen && c != null && c.hasClients) {
      final p = c.position;
      final target = (p.pixels + dy).clamp(0.0, p.maxScrollExtent);
      if ((target - p.pixels).abs() > 0.5) {
        c.jumpTo(target);
        _wheelAcc = 0;
        return;
      }
    }
    _wheelAcc += dy;
    if (_wheelAcc.abs() < 40) return;
    final fwd = _wheelAcc > 0;
    _wheelAcc = 0;
    final now = DateTime.now();
    if (now.difference(_lastWheelTurn) < const Duration(milliseconds: 250)) return;
    _lastWheelTurn = now;
    fwd ? forward() : back();
  }

  // ---- taps: with Double-tap to zoom on (fit screen, a page showing), a tap waits [_doubleTapWait] to see whether a
  // second one follows near it: a double tap zooms in on that spot (again: back out), and no single tap happens. A
  // single tap goes to the Reader's tap zones.
  static const _doubleTapWait = Duration(milliseconds: 250);
  static const _doubleTapSlop = 60.0; // how far apart the two taps may be
  Timer? _tapTimer;
  Offset? _firstTap; // waiting for a possible second tap

  void _onTapUp(TapUpDetails d, double width) {
    final zoomer = _settings.display.doubleTapZoom && prefs.fit == FitMode.screen ? _zoomers[index] : null;
    final waiting = _firstTap;
    final pending = waiting != null && (_tapTimer?.isActive ?? false);
    _tapTimer?.cancel();
    _firstTap = null;
    if (pending && (d.localPosition - waiting).distance > _doubleTapSlop) host.tap(waiting.dx / width); // not a pair
    if (zoomer == null) {
      host.tap(d.localPosition.dx / width);
    } else if (pending && (d.localPosition - waiting).distance <= _doubleTapSlop) {
      zoomer(d.globalPosition);
    } else {
      _firstTap = d.localPosition;
      _tapTimer = Timer(_doubleTapWait, () {
        _firstTap = null;
        if (host.mounted && !host.controlsUp) host.tap(d.localPosition.dx / width);
      });
    }
  }

  // ---- 3D page curl (Page turn animation; lib/page_curl.dart) ----------------------------------------------------
  // A turn jumps the page view to the target page at once and draws the turning page over it from a snapshot:
  // forward, this page curls away over the next; back, the previous page uncurls over this one (a snapshot of this
  // page covers the view until then). Letting go before halfway springs back and jumps back.
  final _pagesKey = GlobalKey(); // repaint boundary around the page view: the snapshots
  late final AnimationController _curlAnim;
  _Curl? _curl;
  // the curl moving (each animation tick, each drag move) repaints its own layer only - it rebuilt the whole reader
  // ~23 times a turn, with a new shader each paint (code review 2026-10-05, #38)
  final _curlMoved = ValueNotifier<int>(0);
  ui.FragmentShader? _curlShader;
  Size _area = Size.zero;
  Offset? _dragStart;
  final Map<int, Rect> _pageRects = {}; // where each page's image sits on screen (from PageCanvas), for the curl

  // ---- page processing waits out page turns (PageCanvas.idle) ----------------------------------------------------
  bool _swiping = false; // the page view is sliding (a wipe, or a drag in Swipe mode)
  Completer<void>? _idle;
  bool get _turning => _swiping || _curl != null;

  /// Completes once no turn is playing - when pages off screen may do their GPU processing.
  Future<void> _whenIdle() => _turning ? (_idle ??= Completer<void>()).future : Future<void>.value();

  void _maybeIdle() {
    if (_turning) return;
    final c = _idle;
    _idle = null;
    c?.complete();
  }

  bool _onPagesScroll(ScrollNotification n) {
    if (n.depth != 0) return false; // a page's own scrolling (fit width/height), not the page view
    if (n is ScrollStartNotification) _swiping = true;
    if (n is ScrollEndNotification) {
      _swiping = false;
      _maybeIdle();
    }
    return false;
  }

  /// The page's image on screen - only it curls, not the bars around it. Unknown (the end card, still loading):
  /// the whole area.
  Rect _pageRect(int i) => _pageRects[i] ?? Offset.zero & _area;

  bool get _curlMode => _settings.display.pageTurn == PageTurn.curl && PageCurl.loaded != null;

  /// A horizontal drag curls the page - unless it's moving the page itself (zoomed, pinching, a sideways page).
  bool get _curlDrag =>
      _curlMode && !zoomed && _fingers <= 1 && !_sideways.contains(index) && pc != null && !host.controlsUp;

  /// Positions in reading-direction space (x from the right edge in a right-to-left book).
  Offset _reading(Offset p) => rtl ? Offset(_area.width - p.dx, p.dy) : p;

  /// A screen position in [page]'s own coordinates, in reading direction (origin top-left; top-right for a
  /// right-to-left book) - how the curl's geometry is worked out.
  Offset _pagePoint(Offset screen, Rect page) =>
      Offset(rtl ? page.right - screen.dx : screen.dx - page.left, screen.dy - page.top);

  ui.Image? _snapshot() {
    final b = _pagesKey.currentContext?.findRenderObject();
    if (b is! RenderRepaintBoundary || !b.hasSize) return null;
    try {
      return b.toImageSync(pixelRatio: MediaQuery.devicePixelRatioOf(host.context));
    } catch (_) {
      return null;
    }
  }

  bool _startCurl({required bool next, required Rect page, required Offset grab, required Offset finger}) {
    final target = next ? index + 1 : index - 1;
    if (target < 0 || target > pages.length || pc == null || _area.isEmpty) return false;
    finishCurlNow();
    final now = _snapshot();
    if (now == null) return false;
    final c = _Curl(sheet: now, forward: next, page: page, grab: grab, finger: finger, from: index,
        under: next ? null : now, pending: !next);
    _curl = c;
    pc!.jumpToPage(target);
    _changed();
    if (!next) {
      // the previous page is now in the view (under the cover): snapshot it to uncurl
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_curl != c || !c.pending) return;
        final prev = _snapshot();
        if (prev == null) {
          _endCurl(cancel: true);
          return;
        }
        c
          ..sheet = prev
          ..pending = false;
        _changed();
      });
    }
    return true;
  }

  void _animateCurl({required bool complete}) {
    final c = _curl;
    if (c == null) return;
    final w = c.page.width;
    c
      ..completing = complete
      ..animFrom = c.finger
      ..animTo = c.forward == complete
          ? Offset(PageCurl.gone(w), c.grab.dy - c.page.height * 0.08) // turned away, corner lifted a little
          : c.grab; // flat on the page
    _curlAnim.forward(from: 0);
  }

  void _onCurlTick() {
    final c = _curl;
    if (c == null) return;
    c.finger = Offset.lerp(c.animFrom, c.animTo, Curves.easeOut.transform(_curlAnim.value))!;
    _curlMoved.value++;
  }

  /// A curl is playing out after the finger let go (turning, or springing back): taps and keys wait for it (user,
  /// 2026-09-30) - one during a spring-back skipped a page, from the last page it even opened the next book.
  bool get _curlSettling => _curl != null && _curlAnim.isAnimating;

  /// The turn is over: let go before halfway -> back to where it started, and nothing counted; else the turn counts.
  void _endCurl({bool cancel = false}) {
    final c = _curl;
    if (c == null) return;
    final back = cancel || !c.completing;
    if (back) pc?.jumpToPage(c.from); // while _curl is still set: not counted as a turn (_onPage)
    _curl = null;
    if (!back) host.turned(index);
    _maybeIdle();
    _changed();
    WidgetsBinding.instance.addPostFrameCallback((_) => c.dispose());
  }

  /// Another turn while one is playing (or a jump): finish that one at once.
  void finishCurlNow() {
    if (_curl == null) return;
    _curlAnim.stop();
    _endCurl();
  }

  Offset? _dragStartScreen;

  void _curlDragStart(DragStartDetails d) {
    finishCurlNow(); // a quick second swipe: the turn still playing ends at once instead of eating this one
    _dragStart = _reading(d.localPosition);
    _dragStartScreen = d.localPosition;
  }

  /// A drag can start anywhere on the screen: the distance from where it starts to the edge it moves towards is
  /// the whole turn (so from the middle, half the screen turns the page fully) - the page doesn't have to be taken
  /// by its edge.
  void _curlDragUpdate(DragUpdateDetails d) {
    final s = _dragStart, s0 = _dragStartScreen;
    if (s == null || s0 == null) return;
    final p = _reading(d.localPosition);
    if (_curl == null) {
      final dx = p.dx - s.dx;
      if (dx.abs() < 4) return;
      final next = dx < 0;
      final page = _pageRect(next ? index : index - 1);
      final at = _pagePoint(s0, page);
      final grab = Offset(page.width, at.dy.clamp(0.0, page.height));
      if (!_startCurl(next: next, page: page, grab: grab,
          finger: next ? grab : Offset(PageCurl.gone(page.width), grab.dy))) {
        _dragStart = null;
        return;
      }
    }
    final c = _curl!;
    if (_curlAnim.isAnimating) return;
    final w = c.page.width, gone = PageCurl.gone(w);
    final room = c.forward ? s.dx : _area.width - s.dx; // from the start to the edge being dragged towards
    final moved = c.forward ? s.dx - p.dx : p.dx - s.dx;
    final t = (moved / math.max(room, 40.0)).clamp(0.0, 1.0);
    // a diagonal drag tilts the page by half its height change (PageCurl.pinned keeps the spine down)
    final y = c.grab.dy + (_pagePoint(d.localPosition, c.page).dy - _pagePoint(s0, c.page).dy) * 0.5;
    c.finger = c.forward ? Offset(w + (gone - w) * t, y) : Offset(gone + (w - gone) * t, y);
    _curlMoved.value++;
  }

  void _curlDragEnd(DragEndDetails d) {
    final c = _curl;
    _dragStart = null;
    if (c == null || _curlAnim.isAnimating) return;
    final w = c.page.width, gone = PageCurl.gone(w);
    var vx = d.velocity.pixelsPerSecond.dx;
    if (rtl) vx = -vx;
    final turned = (w - c.finger.dx) / (w - gone); // 0 = flat on this page, 1 = turned away
    // a flick (diagonal ones carry less sideways speed) or a slow drag about a third of the way
    final complete = c.forward
        ? vx < -250 || (vx < 250 && turned > 0.3)
        : vx > 250 || (vx > -250 && turned < 0.7);
    _animateCurl(complete: complete);
  }

  // ---- the pages on screen

  /// The page view, with its gestures and the curl over it - for the Reader's Stack.
  @override
  List<Widget> buildPages(BuildContext context) => [
        LayoutBuilder(builder: (context, box) {
          _area = Size(box.maxWidth, box.maxHeight);
          return Listener(
            // wheel over the end card or a loading page (over a page, the page itself takes it)
            onPointerSignal: (e) {
              if (e is PointerScrollEvent && !HardwareKeyboard.instance.isControlPressed) {
                GestureBinding.instance.pointerSignalResolver
                    .register(e, (ev) => wheel((ev as PointerScrollEvent).scrollDelta.dy));
              }
            },
            onPointerDown: (_) {
              host.awake();
              _setFingers(_fingers + 1);
            },
            onPointerUp: (_) => _setFingers(_fingers - 1),
            onPointerCancel: (_) => _setFingers(_fingers - 1),
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onSecondaryTap: host.toggleControls, // right-click
              // 3D page curl: a horizontal drag curls the page (the page view doesn't scroll in that mode)
              onHorizontalDragStart: _curlDrag ? _curlDragStart : null,
              onHorizontalDragUpdate: _curlDrag ? _curlDragUpdate : null,
              onHorizontalDragEnd: _curlDrag ? _curlDragEnd : null,
              onTapUp: (d) => _onTapUp(d, box.maxWidth),
              child: RepaintBoundary(
                key: _pagesKey,
                child: NotificationListener<ScrollNotification>(
                  onNotification: _onPagesScroll,
                  child: PageView.builder(
                    // a fresh page view for each book: kept, it hands the new controller the last book's place
                    // (moving on from an end card opened the next book on its own end card - tablet, 2026-09-30)
                    key: ValueKey(_book['id']),
                    controller: pc,
                    // keep the neighbours built, so they're processed before they're turned to (in every mode: a
                    // wipe used to build - and process - the next page while it slid in)
                    allowImplicitScrolling: true,
                    reverse: rtl, // right to left: page 1 on the right, swipe left-to-right goes forward
                    // zoomed, pinching, or a sideways page: a drag moves the page, not to the next one
                    physics: zoomed || _fingers > 1 || _sideways.contains(index) || _curlMode
                        ? const NeverScrollableScrollPhysics()
                        : null,
                    itemCount: pages.length + 1,
                    onPageChanged: _onPage,
                    itemBuilder: (context, i) => i == pages.length ? host.endCard() : _page(context, i),
                  ),
                ),
              ),
            ),
          );
        }),
        if (_curl != null)
          Positioned.fill(
            child: IgnorePointer(
              child: Stack(fit: StackFit.expand, children: [
                if (_curl!.under != null) RawImage(image: _curl!.under, fit: BoxFit.fill),
                if (!_curl!.pending)
                  CustomPaint(painter: _CurlLayer(_curl!, mirror: rtl, moved: _curlMoved,
                      shader: _curlShader ??= PageCurl.loaded!.fragmentShader())),
              ]),
            ),
          ),
      ];

  Widget _page(BuildContext context, int i) {
    return FutureBuilder<PageData>(
      future: _loader!.get(i),
      builder: (context, snap) {
        if (snap.hasError) {
          // the reason on the page itself (user's mock-ups, 2026-09-29): "This page didn't load: can't reach Komga."
          final e = snap.error!;
          final ex = explain(e, thing: 'page');
          final message = ex.kind == ErrorKind.unreadablePage ? ex.message : "This page didn't load: ${ex.reason}.";
          return Center(child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 32),
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              Icon(Icons.broken_image, color: ink(0.24), size: 48),
              const SizedBox(height: 10),
              ErrorText(message, e, stack: snap.stackTrace, centre: true, style: TextStyle(color: ink(0.7)),
                  action: TextButton(onPressed: _changed, child: const Text('Retry'))),
            ]),
          ));
        }
        if (!snap.hasData) return const Center(child: CircularProgressIndicator(strokeWidth: 2));
        return PageCanvas(
          data: snap.data!, prefs: prefs, scroll: _scrollFor(i),
          startAtEnd: _startAtEnd == i,
          levels: _loader!.bookLevels,
          levelsNow: () => _loader?.levelsNow,
          onZoomChanged: (z) {
            if (z != zoomed) {
              zoomed = z;
              _changed();
            }
          },
          onWheel: wheel,
          onPanChanged: (pans) => _setSideways(i, pans),
          onEdgeSwipe: (forward) => _turnPage(next: forward), // dragged on past the page's edge
          onPageRect: (r) => _pageRects[i] = r, // for the page curl (layout only - no rebuild)
          idle: i == index ? null : _whenIdle, // neighbours: processed between turns, not during one
          current: i == index, // moved off, a zoomed page goes back to fit
          onStepper: (step) => step == null ? _steppers.remove(i) : _steppers[i] = step,
          onZoomToggle: (zoom) => zoom == null ? _zoomers.remove(i) : _zoomers[i] = zoom,
          onZoomStep: (step) => step == null ? _zoomSteps.remove(i) : _zoomSteps[i] = step,
          rtl: rtl,
          onStartedAtEnd: () => _startAtEnd = null,
        );
      },
    );
  }

  // ---- the comic's controls on the Reader's bars

  final fitNode = FocusNode(debugLabel: 'ctl-fit');
  final pagesNode = FocusNode(debugLabel: 'ctl-pages');
  final imageNode = FocusNode(debugLabel: 'ctl-image');
  final readerNode = FocusNode(debugLabel: 'ctl-reader');
  final stripNode = FocusNode(debugLabel: 'ctl-strip');

  /// The top bar's own: the fit (one press = the next fit mode: screen -> width -> height -> original size).
  @override
  List<BarButton> topButtons() => [
        BarButton(
          fitNode,
          IconButton(
            focusNode: fitNode,
            tooltip: prefs.fit == FitMode.original ? 'Original size' : 'Fit ${prefs.fit.label.toLowerCase()}',
            onPressed: () => _setFit(FitMode.values[(prefs.fit.index + 1) % FitMode.values.length]),
            icon: fitIcon(prefs.fit, size: 26, color: Colors.white), // ↔ / ↕ (display_panel.dart)
          ),
        ),
      ];

  /// The bottom bar's own: the page strip, image settings (a series), reader settings.
  @override
  List<BarButton> bottomButtons(BuildContext context) => [
        if (pages.length > 1)
          BarButton(pagesNode, barIcon(node: pagesNode, icon: _stripOpen ? Icons.view_carousel : Icons.view_carousel_outlined,
              label: _stripOpen ? 'Hide pages' : 'Show pages', onPressed: _toggleStrip)),
        if (seriesId != null)
          BarButton(imageNode, barIcon(node: imageNode, icon: Icons.settings_brightness, label: 'Image settings',
              onPressed: () => showImagePanel(context, seriesId: seriesId!, seriesTitle: _book['seriesTitle'] as String?))),
        BarButton(readerNode, barIcon(node: readerNode, icon: Icons.tune, label: 'Comic settings',
            onPressed: () => showReaderPanel(context,
                seriesId: seriesId, seriesTitle: _book['seriesTitle'] as String?,
                komgaDirection: _komgaDirection, bookFit: _bookFit,
                page: canSaveCopyPictures && index <= last ? PageActions(save: _savePage, copy: _copyPage) : null))),
      ];

  /// The top bar's fit button: the series' own fit when it overrides the default layout (saved, synced); otherwise
  /// this book only, for now (the Reader panel's toggle turns the override on). A book with no series: the default.
  void _setFit(FitMode f) {
    final id = seriesId;
    if (id == null) {
      _settings.setDefault(_settings.defaults.copyWith(fit: f));
    } else if (_settings.ownsLayout(id)) {
      _settings.setSeriesLayout(id, prefs.copyWith(fit: f));
    } else {
      _bookFit = f;
      _changed();
    }
  }

  // ---- Save page / Copy page (the Reader panel; user, 2026-10-02): the page's own image as Komga sends it - not the
  // picture on screen (no crop, levels or Enhance) - from what's loaded already, else asked for

  static String titleOf(dynamic b) => '${b['seriesTitle'] ?? ''} #${b['metadata']?['number'] ?? ''}'.trim();

  /// The page being read: (its picture file, a name for it). Null on the end card.
  Future<(Uint8List, String)?> _pageFile() async {
    final i = index;
    if (i > last || _loader == null) return null;
    final bytes = _loader!.loadedBytes(i) ?? await api.pageBytes(_book['id'] as String, _loader!.pageNumbers[i]);
    return (bytes, '${titleOf(_book)} - page ${i + 1}');
  }

  Future<void> _savePage() async {
    final ctx = host.context;
    final messenger = ScaffoldMessenger.of(ctx);
    try {
      final f = await _pageFile();
      if (f == null) return;
      final where = await savePicture(f.$1, f.$2);
      messenger // a message for each save, the last one shown at once (not queued behind the one before)
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text('Page saved: $where')));
    } catch (e, st) {
      if (ctx.mounted) showErrorSnack(ctx, couldnt('save the page', e), e, st);
    }
  }

  Future<void> _copyPage() async {
    final ctx = host.context;
    final messenger = ScaffoldMessenger.of(ctx);
    try {
      final f = await _pageFile();
      if (f == null) return;
      await copyPicture(f.$1, f.$2);
      messenger
        ..hideCurrentSnackBar()
        ..showSnackBar(const SnackBar(content: Text('Page copied')));
    } catch (e, st) {
      if (ctx.mounted) showErrorSnack(ctx, couldnt('copy the page', e), e, st);
    }
  }

  // ---- the page strip (user, 2026-10-02): a film strip of the book's pages above the bottom bar, opened by the
  // Pages button. A page tapped (or OK on it) is gone to; the strip and the controls stay up. Right to left, page 1
  // is at the right.
  // open or closed is kept on the device: open, it's there every time the controls come up, book after book, until
  // closed with the button (user, 2026-10-02)
  bool get _stripOpen => _settings.display.pageStrip;
  bool get stripShown => _stripOpen && pages.length > 1;
  int? _stripAt; // the page the remote is on in the strip
  final _stripScroll = ScrollController();
  static const _stripGap = 6.0, _stripMaxHeight = 100.0, _stripAtLeast = 8, _stripAspect = 2 / 3;

  /// A thumbnail's width for a strip [width] wide: at most ~100 px tall, smaller so at least 8 always fit across.
  double _tileWidth(double width) =>
      math.min(_stripMaxHeight * _stripAspect, (width - 16 - (_stripAtLeast - 1) * _stripGap) / _stripAtLeast);

  void _toggleStrip() {
    final open = !_stripOpen;
    _settings.setDisplay(_settings.display.copyWith(pageStrip: open));
    if (open) _stripCentre(index.clamp(0, last), jump: true);
  }

  /// The controls came up: the strip on the page being read now.
  @override
  void controlsShown() {
    if (stripShown) _stripCentre(index.clamp(0, last), jump: true);
  }

  /// Scrolls the strip so page [i] is in the middle (or as near as its ends allow); null: the page being read, as it
  /// is once this frame is drawn.
  void _stripCentre(int? at, {bool jump = false}) =>
      WidgetsBinding.instance.addPostFrameCallback((_) => _stripCentreNow(at, jump: jump));

  void _stripCentreNow(int? at, {bool jump = false}) {
    if (_disposed || !_stripScroll.hasClients) return;
    final i = at ?? index.clamp(0, last);
    final p = _stripScroll.position;
    // the padding is inside the scroll view: the tiles are as wide as the strip's own width makes them (adding it
    // again made each 2 px too wide on a phone, ~200 px off by page 100 - code review 2026-10-05, #10), the first
    // starting 8 px in; the tile itself centred, not with the gap after it
    final tile = _tileWidth(p.viewportDimension) + _stripGap;
    final target = (8 + i * tile - (p.viewportDimension - tile + _stripGap) / 2).clamp(0.0, p.maxScrollExtent);
    jump
        ? _stripScroll.jumpTo(target)
        : _stripScroll.animateTo(target, duration: const Duration(milliseconds: 180), curve: Curves.easeOut);
  }

  /// The remote into the strip, on the page shown.
  void stripFocus() {
    _stripAt = index.clamp(0, last);
    stripNode.requestFocus();
    _stripCentre(_stripAt!);
    _changed();
  }

  void _stripGo(int i) {
    _stripAt = i;
    host.jumpTo(i); // as the slider: the way back is kept
    _changed();
  }

  /// The remote in the strip: Left / Right along it (on screen: right to left, Right is back a page), OK goes there.
  /// Up / Down are the controls' own (the Reader's walk).
  KeyEventResult _onStripKey(FocusNode _, KeyEvent e) {
    if (e is! KeyDownEvent && e is! KeyRepeatEvent) return KeyEventResult.ignored;
    final k = e.logicalKey;
    final at = _stripAt ?? index.clamp(0, last);
    if (k == LogicalKeyboardKey.arrowLeft || k == LogicalKeyboardKey.arrowRight) {
      final step = (k == LogicalKeyboardKey.arrowRight) != rtl ? 1 : -1;
      _stripAt = (at + step).clamp(0, last);
      _changed();
      _stripCentre(_stripAt!);
      return KeyEventResult.handled;
    }
    if (isOkKey(k)) {
      if (e is KeyDownEvent) _stripGo(at);
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  int? _stripFollowed; // the slider's page the strip last followed (null: not scrubbing)

  void _followScrub() {
    if (_disposed) return;
    final follow = host.scrub;
    if (follow == _stripFollowed) return;
    final wasScrubbing = _stripFollowed != null;
    _stripFollowed = follow;
    if (follow != null) {
      _stripCentreNow(follow, jump: true); // (already after the frame)
    } else if (wasScrubbing) {
      _stripCentreNow(null, jump: true);
    }
  }

  /// The strip, for the row just above the bottom bar.
  Widget strip(BuildContext context) {
    // scrubbing the slider (finger, mouse or remote): the strip follows the page picked; when the scrub ends (gone
    // there, or cancelled), back to the page being read (user, 2026-10-03)
    // (looked at after the frame: changing state and scrolling from inside build was the wrong place - #55)
    final scrub = host.scrub;
    if (scrub != _stripFollowed) WidgetsBinding.instance.addPostFrameCallback((_) => _followScrub());
    final accent = Theme.of(context).colorScheme.primary;
    final dpr = MediaQuery.devicePixelRatioOf(context);
    final node = stripNode;
    final wayBack = host.wayBack;
    return Focus(
      focusNode: node,
      onKeyEvent: _onStripKey,
      onFocusChange: (_) => _changed(),
      child: Material(
        key: const ValueKey('page-strip'),
        color: readerBarColour,
        child: LayoutBuilder(builder: (context, box) {
          final w = _tileWidth(box.maxWidth), h = w / _stripAspect;
          return SizedBox(
            height: h + 16 + 10, // room for the way-back mark under a tile
            child: ListView.builder(
              controller: _stripScroll,
              scrollDirection: Axis.horizontal,
              reverse: rtl,
              padding: const EdgeInsets.fromLTRB(8, 8, 8, 0),
              itemExtent: w + _stripGap,
              itemCount: last + 1,
              itemBuilder: (context, i) {
                final current = i == index;
                // white: where the remote is in the strip, or the page being picked on the slider
                final remote = (node.hasFocus && i == (_stripAt ?? index)) || i == scrub;
                return Padding(
                  padding: const EdgeInsetsDirectional.only(end: _stripGap),
                  child: Column(children: [
                    GestureDetector(
                      key: ValueKey('strip-$i'),
                      onTap: () => _stripGo(i),
                      child: Container(
                        width: w, height: h,
                        decoration: BoxDecoration(
                          color: const Color(0xFF1C1D22),
                          border: Border.all(
                              color: remote ? Colors.white : current ? accent : Colors.white12,
                              width: remote || current ? 3 : 1),
                        ),
                        child: Stack(fit: StackFit.expand, children: [
                          Builder(builder: (context) {
                            final bytes = _thumbFor(i, queued: true);
                            if (bytes == null) return const SizedBox.shrink();
                            return Image.memory(bytes, fit: BoxFit.contain, gaplessPlayback: true,
                                cacheHeight: (h * dpr).round(),
                                errorBuilder: (_, __, ___) => const Icon(Icons.image_not_supported, color: Colors.white24));
                          }),
                          Align(
                            alignment: Alignment.bottomCenter,
                            child: Container(
                              color: const Color(0xB0000000),
                              padding: const EdgeInsets.symmetric(horizontal: 4),
                              child: Text('${i + 1}', style: const TextStyle(color: Colors.white, fontSize: 11)),
                            ),
                          ),
                        ]),
                      ),
                    ),
                    // the page to go back to (as on the slider)
                    if (i == wayBack)
                      Container(key: const ValueKey('strip-way-back'), margin: const EdgeInsets.only(top: 4),
                          width: w * 0.6, height: 3, color: accent),
                  ]),
                );
              },
            ),
          );
        }),
      ),
    );
  }

  // ---- the slider's page pictures

  static const _previewSize = Size(120, 196);

  /// A scrub started: not the last scrub's picture.
  @override
  void scrubStarted() => _thumbShown = null;

  /// Page previews on the slider: while a page is being picked (dragging, or the remote scrubbing), a small picture
  /// of it and its number, over the thumb at [x].
  @override
  Widget preview(BuildContext context, int shown, double x) {
    if (!_settings.display.pagePreviews) {
      // Page previews off (Settings > Comics): just the number over the thumb - nothing asked of Komga
      const w = 96.0;
      return Positioned(
        left: x - w / 2,
        top: -48,
        width: w,
        child: IgnorePointer(
          child: Container(
            key: const ValueKey('page-label'),
            padding: const EdgeInsets.symmetric(vertical: 6),
            decoration: BoxDecoration(color: const Color(0xF0101012), borderRadius: BorderRadius.circular(8),
                border: Border.all(color: Colors.white24)),
            child: Text('Page ${shown + 1}', textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.white, fontSize: 13)),
          ),
        ),
      );
    }
    final dpr = MediaQuery.devicePixelRatioOf(context);
    return Positioned(
      left: x - _previewSize.width / 2,
      top: -_previewSize.height - 18,
      width: _previewSize.width,
      height: _previewSize.height,
      child: IgnorePointer(
        child: Container(
          key: const ValueKey('page-preview'),
          padding: const EdgeInsets.all(4),
          decoration: BoxDecoration(color: const Color(0xF0101012), borderRadius: BorderRadius.circular(8),
              border: Border.all(color: Colors.white24)),
          child: Column(children: [
            Expanded(
              // while this page's picture comes in, the last one stays - faded, under a spinner, so it isn't taken for
              // this page (it read as the wrong page, 2026-09-30); nothing yet: just the spinner
              child: Builder(builder: (context) {
                final own = _thumbFor(shown);
                if (own == null && _thumbs.containsKey(shown)) { // Komga has no picture of this page
                  return const Icon(Icons.image_not_supported, color: Colors.white24);
                }
                final bytes = own ?? _thumbShown;
                const spinner = Center(
                    child: SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2)));
                return Stack(fit: StackFit.expand, children: [
                  if (bytes != null)
                    Opacity(
                      opacity: own == null ? 0.25 : 1,
                      child: Image.memory(bytes, fit: BoxFit.contain, gaplessPlayback: true,
                          // offline, or a page already loaded, it's the whole page: decoded small
                          cacheWidth: (_previewSize.width * dpr).round(),
                          errorBuilder: (_, __, ___) => const Icon(Icons.image_not_supported, color: Colors.white24)),
                    ),
                  if (own == null) const KeyedSubtree(key: ValueKey('preview-loading'), child: spinner),
                ]);
              }),
            ),
            const SizedBox(height: 4),
            Text('Page ${shown + 1}', style: const TextStyle(color: Colors.white, fontSize: 13)),
          ]),
        ),
      ),
    );
  }

  // Page previews: Komga's small picture of a page (offline: the page itself). Scrubbing back and forth used to ask
  // for every page passed, all at once, so the one wanted waited behind dozens and the preview seemed to freeze
  // (user, 2026-09-30): now at most two at a time, and only ever the page the thumb is on now.
  final Map<int, Uint8List?> _thumbs = {}; // page index -> its picture (null: none to be had); most recent last
  final Set<int> _thumbsLoading = {};
  int? _thumbWanted; // the page to fetch next, when a slot is free
  Uint8List? _thumbShown; // the last picture shown, kept up while the next comes in
  static const _thumbsAtOnce = 2, _thumbsKept = 64; // (64: a wide screen's page strip shows ~35)
  // and no more than this much: offline the pictures are the pages themselves, 2-5 MB each - 64 of them held
  // 130-320 MB (code review 2026-10-05, #40; user's cap: ~128 MB). Ones let go of are read again from the downloaded
  // file when wanted
  static const _thumbsBytesKept = 128 * 1024 * 1024;

  /// This page's picture if it's in; else asks for it (fetched when a slot is free) and returns null.
  /// [queued]: for the page strip - many wanted at once, the ones asked for most recently (on screen now) first,
  /// after the slider's own page; it doesn't touch the slider preview's last picture.
  Uint8List? _thumbFor(int i, {bool queued = false}) {
    final page = _loader?.loadedBytes(i); // the page itself is already here (this one, its neighbours)
    if (page != null) return queued ? page : _thumbShown = page;
    if (_thumbs.containsKey(i)) {
      final b = _thumbs.remove(i);
      _thumbs[i] = b; // most recently used last
      if (b != null && !queued) _thumbShown = b;
      return b;
    }
    final failed = _thumbsFailed[i];
    if (failed != null && DateTime.now().difference(failed) < _thumbRetry) return null;
    if (!_thumbsLoading.contains(i)) {
      if (queued) {
        _thumbQueue
          ..remove(i)
          ..add(i);
        while (_thumbQueue.length > _stripQueued) {
          _thumbQueue.removeAt(0); // scrolled past long ago
        }
      } else {
        _thumbWanted = i;
      }
      Future.microtask(_nextThumb); // not during the build
    }
    return null;
  }

  final List<int> _thumbQueue = []; // the strip's pages wanted, most recent last
  static const _stripQueued = 40;

  void _nextThumb() {
    if (_disposed || _thumbsLoading.length >= _thumbsAtOnce) return;
    final int i;
    if (_thumbWanted != null) {
      i = _thumbWanted!;
      _thumbWanted = null;
    } else if (_thumbQueue.isNotEmpty) {
      i = _thumbQueue.removeLast();
    } else {
      return;
    }
    if (_thumbs.containsKey(i) || _thumbsLoading.contains(i) || i > last) {
      _nextThumb();
      return;
    }
    final bookId = _book['id'] as String;
    _thumbsLoading.add(i);
    void done(void Function() record) {
      if (_disposed || _book['id'] != bookId) return; // another book since
      _thumbsLoading.remove(i);
      record();
      trimPictures(_thumbs, count: _thumbsKept, bytes: _thumbsBytesKept);
      if (host.scrub != null || (host.controlsUp && stripShown)) _changed();
      _nextThumb();
    }
    api.pageThumbBytes(bookId, _loader!.pageNumbers[i]).then(
      (b) => done(() => _thumbs[i] = b),
      onError: (Object e) => done(() {
        if (e is KomgaUnreachable) {
          _thumbsFailed[i] = DateTime.now(); // too slow, or no answer: try again a little later, not never
        } else {
          _thumbs[i] = null; // Komga answered: there's no picture to be had
        }
      }),
    );
    _nextThumb(); // the other slot, if the strip wants more
  }

  final Map<int, DateTime> _thumbsFailed = {}; // page index -> when its picture last didn't come in time
  static const _thumbRetry = Duration(seconds: 10);

  void _clearThumbs() {
    _thumbs.clear();
    _thumbsFailed.clear();
    _thumbsLoading.clear();
    _thumbWanted = null;
    _thumbQueue.clear();
    _thumbShown = null;
  }
}

/// What a test can see of the curl being drawn.
@visibleForTesting
abstract interface class CurlLayer {
  bool get mirror;
}

/// The curl drawn where it is now; repainted as it moves ([moved]), without rebuilding the reader.
class _CurlLayer extends CustomPainter implements CurlLayer {
  _CurlLayer(this.curl, {required this.mirror, required Listenable moved, required this.shader}) : super(repaint: moved);
  final _Curl curl;
  @override
  final bool mirror;
  final ui.FragmentShader shader;

  @override
  void paint(Canvas canvas, Size size) => PageCurlPainter(program: PageCurl.loaded!, sheet: curl.sheet,
          page: curl.page, grab: curl.grab, finger: curl.finger, mirror: mirror, shader: shader)
      .paint(canvas, size);

  @override
  bool shouldRepaint(_CurlLayer o) => !identical(o.curl, curl) || o.mirror != mirror;
}

/// A page turn in progress (3D page curl).
class _Curl {
  _Curl({required this.sheet, required this.forward, required this.page, required this.grab, required this.finger,
      required this.from, this.under, this.pending = false});
  ui.Image sheet; // the page that curls: this one going forward; the previous one coming back
  final ui.Image? under; // going back: this page, covering the view until the previous one has uncurled
  final bool forward;
  final Rect page; // the curling page's image on screen - only it curls, not the bars around it
  final Offset grab; // where the page was taken hold of (its right edge, page coordinates in reading direction)
  Offset finger; // where that point is now
  final int from; // the page before the turn, to go back to if it's let go
  bool pending; // going back: the previous page's snapshot isn't taken yet
  bool completing = true;
  Offset animFrom = Offset.zero, animTo = Offset.zero;

  void dispose() {
    sheet.dispose();
    if (under != null && !identical(under, sheet)) under!.dispose();
  }
}

/// Lets go of the least recently used pictures in [pictures] (most recent last) until there are at most [count] of
/// them and they come to at most [bytes] - the most recent one always kept.
@visibleForTesting
void trimPictures(Map<int, Uint8List?> pictures, {required int count, required int bytes}) {
  var total = pictures.values.fold<int>(0, (n, b) => n + (b?.length ?? 0));
  while (pictures.length > 1 && (pictures.length > count || total > bytes)) {
    final first = pictures.keys.first;
    total -= pictures.remove(first)?.length ?? 0;
  }
}
