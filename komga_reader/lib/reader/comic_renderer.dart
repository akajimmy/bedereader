import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:clock/clock.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';

import 'package:shared_preferences/shared_preferences.dart';

import '../api.dart';
import '../book_title.dart';
import '../errors.dart';
import '../page_curl.dart';
import '../page_image.dart';
import '../screen.dart';
import '../settings.dart';
import '../widgets/display_panel.dart';
import '../widgets/error_text.dart';
import 'position_row.dart';
import '../synced_ids.dart';
import 'reader_bars.dart';
import 'renderer.dart';
import 'curl_turns.dart';
import 'spreads.dart';
import 'turn_drag.dart';
import 'webtoon_view.dart';

/// Komga lists the book with no pages (a damaged file, or not analysed yet).
class NoPages implements Exception {}

/// A comic's pages loaded for showing (from [ComicRenderer.prepare]).
class ComicPages {
  const ComicPages(this.pages, this.direction, {this.stripPlace});
  final List<dynamic> pages;
  final String? direction; // the series' reading direction in Komga

  /// A webtoon: where in the strip it was left on this device ([StripPlaces]) - null: nowhere kept.
  final (int, double)? stripPlace;
}

/// Where in a webtoon's strip each book was left, on this device: the slice across the middle of the screen and how
/// far into it the top of the screen was (a share of its height) - Komga keeps only the page, which opened up to a
/// screen and a half off (user, 2026-10-22: "1 ... for sure"). Used when Komga's page is still that slice (another
/// device that moved on wins).
class StripPlaces {
  static String _key(String bookId) => 'strip.place.$bookId';

  static Future<(int, double)?> load(String bookId) async {
    final v = (await SharedPreferences.getInstance()).getString(_key(bookId))?.split(':');
    final page = v == null || v.length != 2 ? null : int.tryParse(v[0]);
    final share = v == null || v.length != 2 ? null : double.tryParse(v[1]);
    return page == null || share == null ? null : (page, share);
  }

  static Future<void> save(String bookId, int page, double share) async =>
      (await SharedPreferences.getInstance()).setString(_key(bookId), '$page:${share.toStringAsFixed(4)}');
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
    latest = this;
  }

  /// The comic renderer made last (tests look inside it).
  @visibleForTesting
  static ComicRenderer? latest;

  /// Joined pairs held ([_joinedAt]).
  @visibleForTesting
  int get joinedKept => _joined.length;

  AppSettings get _settings => AppSettings.instance;
  bool _disposed = false;

  @override
  BookKind get kind => _komgaWebtoon ? BookKind.webtoons : BookKind.comics;

  /// Komga says the series is a webtoon: its settings are webtoons', not comics' (user, 2026-10-22: "a clean split").
  /// (A comic series set to Vertical scroll reads as a strip but keeps its comic settings.)
  bool get _komgaWebtoon => _komgaDirection == 'WEBTOON';

  void _changed() {
    if (!_disposed) notifyListeners();
  }

  Map _book = const {};
  List<dynamic> pages = [];
  PageLoader? _loader;
  PageController? pc;

  /// The page being read (the place: progress, the slider, the corner) - with two pages up, the later of the two.
  int index = 0;
  @override
  int get place => index;
  @override
  int get last => pages.length - 1;
  @override
  bool get opened => pc != null;
  bool get onEndCard => index > last;

  // ---- two pages side by side (user, 2026-10-16 - NOTES, "Dual-page mode"): the page view goes by spread
  // (lib/reader/spreads.dart), one page each otherwise; [_at] is where the page view is, [index] the page read

  /// Two pages side by side now (the setting, on this screen's shape).
  bool get dual => _dual;

  bool _twoPagesOn(Size area) =>
      twoPagesAllowed && !webtoon && prefs.twoPages.on(area); // (the series' own, or the default; never a webtoon)
  bool _dual = false;
  List<Spread> _spreads = const [];
  List<int> _spreadOf = const [];
  int _at = 0;
  int _viewGen = 0;

  /// The spreads, pairing this book's pages - shifted by one where the reader's button said so (per book, synced).
  void _pair() {
    _spreads = pairPages([for (final p in pages) isWidePage(p as Map)],
        shifted: PairShift.instance.shifted(_book['id'] as String));
    _spreadOf = spreadIndex(_spreads, pages.length);
  }

  /// The page view's item showing page [place] ([pages.length]: the end card).
  int _viewOf(int place) => !_dual ? place : place > last ? _spreads.length : _spreadOf[place];

  /// The page read at page view item [view]: the later page of a spread.
  int _placeOf(int view) => !_dual ? view : view >= _spreads.length ? pages.length : _spreads[view].last;

  /// The page view's items before the end card.
  int get _views => _dual ? _spreads.length : pages.length;

  /// The pages shown at item [view].
  List<int> _pagesAt(int view) => !_dual ? [view] : view >= _spreads.length ? const [] : _spreads[view].pages;

  /// The screen's shape or the setting changed between one page and two (or the shift between pairings): the page
  /// view again, on the page being read.
  void _rebuildView({required bool dual}) {
    if (_disposed || pages.isEmpty) return;
    finishCurlNow();
    final keep = index;
    _dual = dual;
    _pair();
    _at = _viewOf(keep.clamp(0, pages.length));
    final oldPc = pc, oldScrolls = List.of(_scrolls.values);
    _scrolls.clear();
    _sideways.clear();
    _pageRects.clear();
    _joined.clear();
    _spineAt.clear();
    _startAtEnd = null;
    zoomed = false;
    pc = PageController(initialPage: _at, keepPage: false);
    _viewGen++; // a fresh page view for the new controller
    WidgetsBinding.instance.addPostFrameCallback((_) {
      oldPc?.dispose();
      for (final c in oldScrolls) {
        c.dispose();
      }
    });
    _changed();
  }

  /// The reader's "Shift pairing by one" (the Comic settings panel, two pages up): this book's pairing flipped, kept
  /// and synced.
  void shiftPairing() {
    final id = _book['id'] as String;
    PairShift.instance.setShifted(id, !PairShift.instance.shifted(id));
    _rebuildView(dual: _dual);
  }
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
        ReadingDirection.ltr || ReadingDirection.vertical => false,
        ReadingDirection.auto => _komgaDirection == 'RIGHT_TO_LEFT',
      };

  /// A webtoon: the pages one continuous strip, scrolled down ([WebtoonView]) - the series set to Vertical scroll, or
  /// on Auto where Komga says Webtoon (user, 2026-10-22).
  bool get webtoon => switch (prefs.direction) {
        ReadingDirection.vertical => true,
        ReadingDirection.auto => _komgaDirection == 'WEBTOON',
        _ => false,
      };

  WebtoonController? _strip; // the strip's place and scrolling, while a webtoon is shown
  (int, double)? _stripPlace; // where in the strip the book was left here (opening it)
  bool _wasWebtoon = false; // (paged again: the page view on the place read in the strip)

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
    // a webtoon: where in the strip it was left here
    final place = direction == 'WEBTOON' ? await StripPlaces.load(book['id'] as String) : null;
    return ComicPages(pages, direction, stripPlace: place);
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
    // a webtoon's series follows webtoons' defaults (AppSettings.defaultsFor)
    final sid = book['seriesId'] as String?;
    if (sid != null) {
      _settings.noteDirection(sid, prepared.direction);
    }
    // the last book's page shapes (the curl drew the new book's first turn in them - #17) and a page left to open at
    // its end (a later page with that number opened scrolled to its end - #22) go with it
    _pageRects.clear();
    _startAtEnd = null;
    _book = book;
    this.pages = pages;
    index = start;
    _strip = null; // (a webtoon opens at its place)
    _playAt = null;
    _stripPlace = prepared.stripPlace;
    _loader = loader;
    zoomed = false;
    _bookFit = null;
    // two pages: as the page area is now - before the first layout, the screen's (the reader fills it; the layout
    // corrects it if it differs - buildPages)
    final area = _area.isEmpty && host.mounted ? MediaQuery.sizeOf(host.context) : _area;
    _dual = !area.isEmpty && _twoPagesOn(area);
    _pair();
    _joined.clear();
    _spineAt.clear();
    _at = _viewOf(start);
    pc = PageController(initialPage: _at, keepPage: false); // (a kept page would be the last book's)
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
  Widget? above(BuildContext context) {
    // a webtoon: auto-scroll's speed, over the bar its button is on
    if (webtoon && _strip != null) {
      return stripShown
          ? Column(mainAxisSize: MainAxisSize.min, children: [_autoSpeedRow(context), strip(context)])
          : _autoSpeedRow(context);
    }
    return stripShown ? strip(context) : null;
  }
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
        left: SpotText(
            'Pg. ${_pagesText(place)}/${pages.length} · ${((place + 1) / pages.length * 100).round()}%', 'page'),
        right: null,
      );

  /// "Saga #1 - Chapter One": the series and number, and the book's own title when it says more.
  String get _bookTitle {
    final heading = titleOf(_book);
    final title = '${_book['metadata']?['title'] ?? ''}';
    return title.isEmpty || title == heading || heading.endsWith(title) ? heading : '$heading - $title';
  }

  /// The page number at [place] - two pages up, both of the pair shown there: "4-5".
  String _pagesText(int place) {
    if (!_dual || place > last) return '${place + 1}';
    final s = _spreads[_spreadOf[place]];
    return s.pages.length == 1 ? '${place + 1}' : '${s.first + 1}-${s.last + 1}';
  }

  @override
  String corner(int place) => '${_pagesText(place)} / ${pages.length}';
  @override
  String placeLabel(int place) => 'Page ${place + 1}';
  @override
  String get whereText => _pagesText(index).contains('-')
      ? 'You are on pages ${_pagesText(index)} of ${pages.length}.'
      : 'You are on page ${index + 1} of ${pages.length}.';

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
    _settleTimer?.cancel();
    _tapTimer?.cancel();
    _autoAwake?.cancel();
    autoNode.dispose();
    _curl.dispose();
    _idle?.complete(); // nothing left waiting
    pc?.dispose();
    for (final c in _scrolls.values) {
      c.dispose();
    }
    _scrolls.clear();
    _stripScroll.dispose();
    for (final n in [fitNode, pagesNode, readerNode, stripNode]) {
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
  bool _rightDown = false; // the right mouse button is down on the page (a right-click on its way)
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

  /// The page view moved to item [v] (a turn, a swipe or a jump).
  void _onPage(int v) {
    if (_startAtEnd != null && _startAtEnd != v) _startAtEnd = null; // (#22) only the page turned back to
    _at = v;
    final i = _placeOf(v);
    index = i;
    zoomed = false;
    // (two pages: the window of pages kept and preloaded twice as wide - a turn moves two)
    if (i <= last) _loader?.around(_dual ? _pagesAt(v).first : i, span: _dual ? 2 : 1);
    // a curl moves the page view underneath as it starts: that counts once the curl completes (_endCurl) - one let go
    // before halfway leaves no trace (code review, 2026-09-30: it un-read a finished book)
    host.pageChanged(i, curling: _curl.active);
  }

  /// To [place] at once (the slider, the strip, another device's page) - not a turn (the Reader knows it's coming).
  @override
  void jumpTo(int place) {
    if (webtoon) {
      _strip?.jumpTo(place);
      return;
    }
    finishCurlNow();
    pc?.jumpToPage(_viewOf(place));
  }

  // ---- turning (the page after the last is the "end of book" card)
  static const _turn = Duration(milliseconds: 180);

  bool get _blocked => pc == null || host.busy || _curl.settling;

  /// Forward: in fit width/height scroll on through the page first, then turn; from the end card, the next book.
  @override
  void forward({bool snap = false, bool held = false}) {
    if (webtoon) {
      if (pc == null || host.busy) return;
      if (_strip?.atEnd ?? false) {
        host.nextBook(); // (the end card showing)
        return;
      }
      _webtoonStep(1, held: held);
      return;
    }
    if (_blocked) return;
    if (_at >= _views) {
      host.nextBook();
      return;
    }
    if (zoomed && (_steppers[_at]?.call(true) ?? false)) return; // zoomed in: pan along the page first
    final c = _scrolls[_at];
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
  void back({bool snap = false, bool held = false}) {
    if (webtoon) {
      if (pc == null || host.busy) return;
      _webtoonStep(-1, held: held);
      return;
    }
    if (_blocked) return;
    if (zoomed && (_steppers[_at]?.call(false) ?? false)) return; // zoomed in: pan back along the page first
    final c = _scrolls[_at];
    if (prefs.fit != FitMode.screen && c != null && c.hasClients && c.position.pixels > 1) {
      final p = c.position;
      c.animateTo((p.pixels - p.viewportDimension * 0.85).clamp(0, p.maxScrollExtent), duration: _turn,
          curve: Curves.easeOut);
      return;
    }
    if (_at == 0) return;
    if (prefs.fit != FitMode.screen) {
      _scrolls.remove(_at - 1)?.dispose(); // fresh controller so the page lays out again from its end
      _startAtEnd = _at - 1;
    }
    _turnPage(next: false);
  }

  /// One page on or back, in the chosen animation: Wipe (slide), Instant flip, or 3D page curl.
  void _turnPage({required bool next}) {
    if (host.busy || _curl.settling) return;
    final target = next ? _at + 1 : _at - 1;
    if (target < 0 || target > _views) return;
    if (_curlMode) {
      if (!_area.isEmpty && _curl.turn(next: next, target: target)) return;
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
    if (webtoon) {
      _strip?.zoomBy(zoomIn ? 1.25 : 1 / 1.25);
      return;
    }
    if (prefs.fit == FitMode.screen) _zoomSteps[_at]?.call(zoomIn);
  }

  // ---- a webtoon's scrolling (user, 2026-10-22): one press - a tap at the side, a key - glides a short way (Smooth)
  // or most of a screen (Page: a strip of it kept on screen); a held key's repeats glide on steadily, a little each,
  // so a held key scrolls continuously
  static const smoothStep = 0.25, pageStep = 0.85, heldStep = 0.06; // shares of the screen's height

  void _webtoonStep(int direction, {required bool held}) {
    final s = _strip;
    if (s == null) return;
    if (_settings.display.webtoonScroll == WebtoonScroll.page) {
      // Page: every press a screen (a strip of it kept) - held, a screen each time the last one has landed
      if (held && s.gliding) return;
      s.glide(direction * pageStep * s.viewport, duration: const Duration(milliseconds: 260));
      return;
    }
    s.glide(direction * (held ? heldStep : smoothStep) * s.viewport,
        duration: held ? const Duration(milliseconds: 120) : const Duration(milliseconds: 260));
  }

  /// The strip moved to slice [i] ([pages.length]: the end card).
  // ---- a webtoon's auto-scroll (user, 2026-10-22): the play button (the bottom bar), its speed slider over it, its
  // keys; any touch on the strip stops it, as does the end
  final autoNode = FocusNode(debugLabel: 'ctl-auto');
  Timer? _autoAwake; // the screen kept on while it scrolls by itself (no page turns to count)

  bool get autoScrolling => _strip?.autoOn ?? false;

  @override
  void autoScrollToggle() {
    final s = _strip;
    if (!webtoon || s == null) return;
    if (s.autoOn) {
      s.stopAuto();
      _autoStopped();
      return;
    }
    _autoResume();
  }

  /// The tap that stops auto-scroll brings the controls and a play button where it was (user, 2026-10-22: "tap
  /// pauses + control AND adds a floating "play" button where the tap happened"; "there isn't really a pause state" -
  /// stopped is stopped, and the next tap is a tap).
  Offset? _playAt; // the floating play button, where the tap that stopped it was
  static const _playSize = 72.0;

  void _autoResume() {
    final s = _strip;
    if (s == null) return;
    _playAt = null;
    s
      ..autoSpeed = _settings.display.autoScrollSpeed
      ..startAuto();
    host.awake();
    _autoAwake?.cancel();
    _autoAwake = Timer.periodic(const Duration(seconds: 20), (_) => host.awake());
    host.hideControls(); // (to read)
    _changed();
  }

  void _autoStopped() {
    _autoAwake?.cancel();
    _autoAwake = null;
    _changed();
  }

  /// A tap on the strip: the one that stopped auto-scroll - the controls, and play where it was; any other, the tap
  /// zones (the floating play goes).
  void _stripTap(TapUpDetails d, Size box) {
    if (!host.controlsUp) _playAt = null; // (put away with the controls)
    final strip = _strip;
    if (!(strip?.touchStoppedAuto ?? false) && _playAt == null && strip != null && !host.controlsUp) {
      // a double tap zooms the strip in on the spot, and out again (user, 2026-10-22: as comics' - their tap logic)
      _tapOrDoubleTap(d,
          zoom: _settings.display.webtoonDoubleTap ? (_) => strip.toggleZoomAt(d.localPosition) : null,
          tap: (at) => _stripTapAt(at, box));
      return;
    }
    _stripTapAt(d.localPosition, box);
  }

  void _stripTapAt(Offset at, Size box) {
    if (_strip?.touchStoppedAuto ?? false) {
      _playAt = at;
      if (!host.controlsUp) host.tap(0.5); // (the middle: the controls)
      _changed();
      return;
    }
    if (_playAt != null) {
      // the tap after it: the controls (and the play button) away - still stopped (user, 2026-10-22: "if I tap
      // somewhere other than the play button, the controls will close, but it will remain stopped")
      _playAt = null;
      host.hideControls();
      _changed();
      return;
    }
    host.tap(_settings.display.webtoonTaps == WebtoonTaps.topBottom
        ? _zoneOf(at.dy / box.height)
        : at.dx / box.width);
  }

  @override
  void autoScrollSpeed({required bool faster}) {
    if (!webtoon) return;
    _setAutoSpeed(_settings.display.autoScrollSpeed * (faster ? 1.25 : 1 / 1.25));
  }

  void _setAutoSpeed(double v) {
    final speed = v.clamp(DisplayPrefs.autoScrollSlowest, DisplayPrefs.autoScrollFastest).toDouble();
    _strip?.autoSpeed = speed;
    _settings.setDisplay(_settings.display.copyWith(autoScrollSpeed: speed));
  }

  /// The speed over the bottom bar, a webtoon's (its play button is on the bar).
  Widget _autoSpeedRow(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12),
        child: Row(children: [
          const Icon(Icons.speed, color: Colors.white70, size: 20),
          Expanded(
            child: Slider(
              key: const ValueKey('auto-scroll-speed'),
              min: DisplayPrefs.autoScrollSlowest,
              max: DisplayPrefs.autoScrollFastest,
              value: _settings.display.autoScrollSpeed,
              label: 'Auto-scroll speed',
              onChanged: _setAutoSpeed,
            ),
          ),
        ]),
      );

  void _onStripPlace(int i) {
    index = i;
    if (i <= last) _loader?.around(i, span: 2); // (a screen can show two or three slices)
    host.pageChanged(i, curling: false);
  }

  // ---- the mouse wheel over the page (desktop): in fit width/height it scrolls through the page first; otherwise
  // (or at the page's end) one notch turns one page - trackpad flicks are gathered up so they don't skip several pages
  double _wheelAcc = 0; // mouse wheel travel towards the next page turn
  DateTime _lastWheelTurn = DateTime(0);

  void wheel(double dy) {
    if (host.controlsUp || pc == null) return;
    if (webtoon) {
      if (_settings.display.webtoonScroll == WebtoonScroll.page) {
        // Page: the wheel's notches add up to a screen at a time, as a comic's turn a page (user, 2026-10-22: it
        // "feels very similar to smooth scroll" - the wheel glided by its spin in both)
        _wheelAcc += dy;
        if (_wheelAcc.abs() < 40) return;
        final down = _wheelAcc > 0;
        _wheelAcc = 0;
        final now = clock.now();
        if (now.difference(_lastWheelTurn) < const Duration(milliseconds: 250)) return;
        _lastWheelTurn = now;
        _webtoonStep(down ? 1 : -1, held: false);
        return;
      }
      // Smooth: as far as the wheel spins, gliding (user, 2026-10-22: "smooth scroll, based on wheel spin distance")
      _strip?.glide(dy, duration: const Duration(milliseconds: 140));
      return;
    }
    final c = _scrolls[_at];
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
    final now = clock.now();
    if (now.difference(_lastWheelTurn) < const Duration(milliseconds: 250)) return;
    _lastWheelTurn = now;
    fwd ? forward() : back();
  }

  // ---- taps: with Double-tap to zoom on (fit screen, a page showing), a tap waits [doubleTapWait] to see whether a
  // second one follows near it: a double tap zooms in on that spot (again: back out), and no single tap happens. A
  // single tap goes to the Reader's tap zones.
  /// (zero: no wait - tests that aren't about the double tap; a tap goes at once)
  @visibleForTesting
  static Duration doubleTapWait = const Duration(milliseconds: 250);
  static const _doubleTapSlop = 60.0; // how far apart the two taps may be
  Timer? _tapTimer;
  Offset? _firstTap; // waiting for a possible second tap

  void _onTapUp(TapUpDetails d, double width) => _tapOrDoubleTap(d,
      zoom: _settings.display.doubleTapZoom && prefs.fit == FitMode.screen ? _zoomers[_at] : null,
      tap: (at) => host.tap(at.dx / width));

  /// A tap, or two close together: with a [zoom] (Double-tap to zoom), a tap waits [doubleTapWait] for a second
  /// near it - the pair zooms ([zoom] with the second's place on the screen), a tap alone goes to [tap] (its place in
  /// the view) a moment later; without, at once. Comics' pages and webtoons' strip alike.
  void _tapOrDoubleTap(TapUpDetails d, {void Function(Offset global)? zoom, required void Function(Offset at) tap}) {
    final waiting = _firstTap;
    final pending = waiting != null && (_tapTimer?.isActive ?? false);
    _tapTimer?.cancel();
    _firstTap = null;
    if (pending && (d.localPosition - waiting).distance > _doubleTapSlop) tap(waiting); // not a pair
    if (zoom == null || doubleTapWait == Duration.zero) {
      tap(d.localPosition);
    } else if (pending && (d.localPosition - waiting).distance <= _doubleTapSlop) {
      zoom(d.globalPosition);
    } else {
      _firstTap = d.localPosition;
      _tapTimer = Timer(doubleTapWait, () {
        _firstTap = null;
        if (host.mounted && !host.controlsUp) tap(d.localPosition);
      });
    }
  }

  // ---- 3D page curl (Page turn animation): the readers' shared turn (curl_turns.dart - user, 2026-10-22: "move
  // comic reader to the shared code"), told what turns here: two pages up a pair's later page at its gutter, a page
  // alone before a pair made up into a double page, a spread picture at its middle; right to left, mirrored
  late final CurlTurns _curl = CurlTurns(
    vsync: host.vsync,
    current: () => _at,
    jump: (v) => pc?.jumpToPage(v), // (during a turn: not counted as one - _onPage, curling)
    pageRect: _curlRect,
    spine: (v) => _spineX(v) != null || _padded(v) != null,
    gap: _gapOn,
    held: (forward, target) {
      // two pages up, as a book: forward, the earlier page stays (its picture in the old view) until the later turns
      // over onto it - from a page alone made up into a double page, its earlier half; back, the later page stays
      // until the previous spread's later page lands on it - the earlier side shows that spread at once
      final padded = _padded(forward ? _at : target);
      if (forward && padded != null) {
        final (r, x) = padded;
        return rtl ? Rect.fromLTRB(x, r.top, r.right, r.bottom) : Rect.fromLTRB(r.left, r.top, x, r.bottom);
      }
      return forward
          ? _heldPage(_at, _spineX(_at), earlier: true)
          : _heldPage(_at, _spineX(target) ?? padded?.$2, earlier: false);
    },
    mirror: () => rtl,
    pixelRatio: () => MediaQuery.devicePixelRatioOf(host.context),
    done: ({required turned}) {
      if (turned) host.turned(index);
      _maybeIdle();
      _changed();
    },
  );
  Size _area = Size.zero;
  final Map<int, Rect> _pageRects = {}; // where each page's image sits on screen (from PageCanvas), for the curl

  // ---- page processing waits out page turns (PageCanvas.idle) ----------------------------------------------------
  bool _swiping = false; // the page view is sliding (a wipe, or a drag in Swipe mode)
  Completer<void>? _idle;
  bool get _turning => _swiping || _curl.active;

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

  /// The gutter between the pages turning at item [v], on screen (Gutter; user, 2026-10-20): a pair's - its pages
  /// that far apart, the later turning from its own edge and landing past it; a page alone before a pair, that pair's
  /// (it turns as one); none for a spread in one picture (its gutter is in the art) or one page.
  double _gapOn(int v) {
    if (!_dual || v >= _views) return 0;
    final s = _spreads[v];
    if (s.pages.length == 2 && !s.wide) return (_gapAt[v] ?? 0) * _pageRect(v).width;
    return _padded(v) != null ? _gapOn(v + 1) : 0;
  }

  /// The page that curls at item [v]: two pages up, a pair's later page - the right one (left, right to left), its
  /// spine at the gutter, as a book's page turns (user, 2026-10-16); a page alone before a pair or a spread, the later
  /// half of the double page it makes up ([_padded]) - turning on from it, or back onto it; else the whole page.
  Rect _curlRect(int v) {
    final padded = _padded(v);
    final half = _gapOn(v) / 2; // (the later page starts past the gutter)
    if (padded != null) {
      final (r, x) = padded;
      return rtl
          ? Rect.fromLTRB(r.left, r.top, x - half, r.bottom)
          : Rect.fromLTRB(x + half, r.top, r.right, r.bottom);
    }
    final page = _pageRect(v), x = _spineX(v);
    if (x == null) return page;
    return rtl
        ? Rect.fromLTRB(page.left, page.top, x - half, page.bottom)
        : Rect.fromLTRB(x + half, page.top, page.right, page.bottom);
  }

  /// Where the gutter is on screen at item [v] - a pair's (two pages up, joined), or a spread picture's middle; null
  /// otherwise.
  double? _spineX(int v) {
    // a spread in one picture (wider than tall): its middle, as two pages' gutter - it turns as a pair does (user,
    // 2026-10-16: "curl the same way it does when it's two separate images")
    final s = !_dual || v >= _views ? null : _spreads[v];
    final share = s == null ? null : s.wide ? 0.5 : s.pages.length == 2 ? _spineAt[v] : null;
    if (share == null) return null;
    final page = _pageRect(v);
    return page.left + share * page.width;
  }

  /// Two pages up, turning between a page alone (the cover) and the pair or spread after it, on from it or back onto
  /// it (user, 2026-10-17: "turn the single into a double by including background empty space to each side of the
  /// front cover (such that its width matches the double page underneath)", treat it "as you would any other double
  /// page when we're curling it", and "cover the reverse turn the same way"): the double page it makes up - as wide
  /// as the next view's, the page alone with background either side, as tall as either - and where it folds, the
  /// next view's gutter. Null otherwise (a page alone to a page alone still turns away whole).
  (Rect, double)? _padded(int v) {
    if (!_dual || v + 1 >= _views || _spineX(v) != null) return null;
    final s = _spreads[v];
    final x = _spineX(v + 1);
    if (s.pages.length != 1 || s.wide || x == null) return null;
    final page = _pageRect(v), next = _pageRect(v + 1);
    return (Rect.fromLTRB(next.left, math.min(page.top, next.top), next.right, math.max(page.bottom, next.bottom)), x);
  }

  /// Two pages up, a page turning over at the gutter [x]: what of view [v]'s picture stays put meanwhile - its part on
  /// the [earlier] side of [x] (forward: the earlier page, until the later lands on it), or on the later side (back:
  /// until the previous spread's later page lands on it). Only the picture: round it the new view shows at once - a
  /// spread or a page alone that's wider than the old page shows past it, as a book's next page does (user,
  /// 2026-10-16: "make sure it works properly for single images and double-page spreads") - rather than appearing as
  /// the page lands. Null: no gutter [x] (one page turning whole).
  Rect? _heldPage(int v, double? x, {required bool earlier}) {
    if (x == null) return null;
    final p = _pageRect(v);
    final r = earlier != rtl
        ? Rect.fromLTRB(p.left, p.top, math.min(x, p.right), p.bottom)
        : Rect.fromLTRB(math.max(x, p.left), p.top, p.right, p.bottom);
    return r.width > 0 ? r : Rect.zero;
  }

  /// The gutter of each joined pair, as a share of the joined picture's width from its left - the middle of the space
  /// between the pages - and that space's own share of the width (from [_joinedAt]).
  final Map<int, double> _spineAt = {}, _gapAt = {};

  /// Gutter (logical px on screen at the page's fit) in the joined picture's own pixels, for two pages [w0] wide
  /// together at height [h] (picture pixels): how the fit will scale the picture on this screen.
  double _gapPixels(double h, double w0) {
    final gap = prefs.gutter;
    if (gap <= 0 || _settled.isEmpty || h <= 0 || w0 <= 0) return 0;
    final a = _settled; // (the layout's area: the pair joined once a rotation has settled)
    double byHeight() => gap * h / a.height; // the picture as tall as the screen
    double byWidth() => gap * w0 / math.max(1.0, a.width - gap); // as wide (the gap included)
    return switch (prefs.fit) {
      FitMode.height => byHeight(),
      FitMode.width => byWidth(),
      FitMode.original => gap,
      FitMode.screen => (w0 + byHeight()) * a.height / h <= a.width ? byHeight() : byWidth(),
    };
  }

  bool get _curlMode => _settings.display.pageTurn == PageTurn.curl && PageCurl.loaded != null;

  /// A drag may turn the page (Slide or Curl, [TurnDragRecognizer]) - unless it's moving the page itself (zoomed, a
  /// sideways page); a curl not with the controls up. (A second finger, a pinch: the recognizer stands aside.)
  bool get _canDragTurn =>
      !zoomed && !_sideways.contains(_at) && pc != null && !(_curlMode && host.controlsUp);

  /// The page being read scrolls up and down (fit width, original size): only flatter drags turn, the steeper ones
  /// scroll it.
  bool get _scrollsDown {
    final c = _scrolls[_at];
    return c != null && c.hasClients && c.position.axis == Axis.vertical && c.position.maxScrollExtent > 0;
  }

  Drag? _slide; // Slide: the page view following a drag

  void _configureTurn(TurnDragRecognizer r) => r
    ..canTurn = (() => _canDragTurn)
    ..hold = null // nothing on a comic page takes a hold: a finger held first still turns
    ..onTap = ((d) => _onTapUp(d, _area.width)) // a wobbly click the turn took (a mouse)
    ..maxAngle = (() => _scrollsDown ? 30.0 : 60.0)
    ..onStart = (d) {
      if (_curlMode) {
        _curl.dragStart(d, pages: _views + 1);
      } else {
        _slide = pc?.position.drag(d, () => _slide = null);
      }
    }
    ..onUpdate = ((d) { if (_curlMode) { _curl.dragUpdate(d, _area); } else { _slide?.update(d); } })
    ..onEnd = ((d) { if (_curlMode) { _curl.dragEnd(d); } else { _slide?.end(d); } })
    ..onCancel = (() { if (_curlMode) { _curl.dragEnd(DragEndDetails()); } else { _slide?.cancel(); } });

  /// Another turn while one is playing (or a jump): finish that one at once.
  void finishCurlNow() => _curl.finishNow();

  // ---- the pages on screen

  /// The page view, with its gestures and the curl over it - for the Reader's Stack.
  @override
  List<Widget> buildPages(BuildContext context) {
    if (webtoon) {
      _wasWebtoon = true;
      return [_webtoonView(context)];
    }
    if (_wasWebtoon) {
      // paged again (the setting changed): the page view on the place the strip was at
      _wasWebtoon = false;
      _strip = null;
      WidgetsBinding.instance.addPostFrameCallback((_) => _rebuildView(dual: _dual));
    }
    return _pagedView(context);
  }

  /// A webtoon's strip ([WebtoonView]) with the reader's taps, wheel and right-click.
  Widget _webtoonView(BuildContext context) {
    // opened on the page it was left on here: just as far into it as then (Komga keeps only the page)
    final kept = _stripPlace;
    final strip = (_strip ??= WebtoonController(index.clamp(0, pages.length),
        startShare: kept != null && kept.$1 == index ? kept.$2 : 0)
      ..onAutoStopped = _autoStopped)
      ..autoSpeed = _settings.display.autoScrollSpeed; // (set anywhere - the panel, Settings - it goes at once)
    return LayoutBuilder(builder: (context, box) {
      _area = Size(box.maxWidth, box.maxHeight);
      return Listener(
        onPointerSignal: (e) {
          if (e is PointerScrollEvent && !HardwareKeyboard.instance.isControlPressed) {
            GestureBinding.instance.pointerSignalResolver
                .register(e, (ev) => wheel((ev as PointerScrollEvent).scrollDelta.dy));
          }
        },
        onPointerDown: (e) {
          host.awake();
          _rightDown = e.buttons == kSecondaryButton;
        },
        onPointerUp: (e) {
          if (_rightDown) {
            _rightDown = false;
            // the right-click that stopped auto-scroll: as the tap that does - the controls, and play where it was
            // (user, 2026-10-23)
            if (_strip?.touchStoppedAuto ?? false) {
              _stripTapAt(e.localPosition, Size(box.maxWidth, box.maxHeight));
            } else {
              host.toggleControls();
            }
          }
        },
        onPointerCancel: (_) => _rightDown = false,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          // the tap zones: the sides (as a comic's), or top and bottom - the bottom third scrolls down, the top up
          // (user, 2026-10-22)
          onTapUp: (d) => _stripTap(d, Size(box.maxWidth, box.maxHeight)),
          // the strip follows a finger, a mouse drag and a pen alike
          child: ScrollConfiguration(
            // (no scroll bar over the strip - user, 2026-10-22: Windows put one there; the slider says where it is)
            behavior: ScrollConfiguration.of(context)
                .copyWith(dragDevices: PointerDeviceKind.values.toSet(), scrollbars: false),
            child: WebtoonView(
              key: ValueKey(('webtoon', _book['id'])),
              sizes: [
                for (final p in pages)
                  // (as cropped: Crop edges narrows each slice, its place in the strip with it)
                  croppedSize(((p as Map)['width'] as num?)?.toInt() ?? 0, (p['height'] as num?)?.toInt() ?? 0,
                      prefs.crop, sidesOnly: true),
              ],
              page: _slice,
              endCard: host.endCard,
              controller: strip,
              onPlace: _onStripPlace,
              background: background,
              fit: WebtoonView.fitOf(prefs.fit),
              gutter: prefs.gutter,
              onWheel: wheel,
              onSettled: (slice, share) {
                final id = _book['id'] as String?;
                if (id != null) unawaited(StripPlaces.save(id, slice, share));
                _stripPlace = (slice, share);
              },
            ),
          ),
        ),
      );
    });
  }

  /// Auto-scroll stopped by a tap: play, big, where the tap was - a shortcut for the bar's small one, where the finger
  /// already is (user, 2026-10-22). Over the controls (the tap brought them up), so it takes its own tap.
  @override
  List<Widget> overControls(BuildContext context) {
    final at = _playAt;
    // (with the controls: a tap elsewhere puts them away, and it goes with them - still stopped)
    if (!webtoon || at == null || autoScrolling || !host.controlsUp) return const [];
    return [
      Positioned(
        left: (at.dx - _playSize / 2).clamp(0.0, math.max(0.0, _area.width - _playSize)),
        top: (at.dy - _playSize / 2).clamp(0.0, math.max(0.0, _area.height - _playSize)),
        width: _playSize,
        height: _playSize,
        child: Material(
          key: const ValueKey('auto-scroll-play'),
          color: Colors.black.withValues(alpha: 0.6),
          shape: const CircleBorder(),
          child: IconButton(
            iconSize: 48,
            tooltip: 'Resume auto-scroll',
            icon: const Icon(Icons.play_arrow, color: Colors.white),
            onPressed: _autoResume,
          ),
        ),
      ),
    ];
  }

  /// A tap [along] the screen's height (0 at the top) as the Reader's tap zones, which go across: the bottom third
  /// as the right (on), the top as the left (back), the middle the middle.
  static double _zoneOf(double along) => along > 2 / 3 ? 1.0 : along < 1 / 3 ? 0.0 : 0.5;

  /// Slice [i] of a webtoon, filling its place in the strip (its height is Komga's, ahead of it loading).
  Widget _slice(BuildContext context, int i) => FutureBuilder<PageData>(
        future: _loader!.get(i),
        builder: (context, snap) {
          if (snap.hasError) {
            return Center(child: IconButton(
              tooltip: 'Retry',
              icon: Icon(Icons.broken_image, color: ink(0.4), size: 40),
              onPressed: _changed,
            ));
          }
          if (!snap.hasData) return Center(child: CircularProgressIndicator(strokeWidth: 2, color: ink(0.3)));
          // the series' image settings, as a comic's page has them (ProcessedPicture) - a crop at the sides only, the
          // strip running on from slice to slice
          return LayoutBuilder(builder: (context, box) => ProcessedPicture(data: snap.data!, prefs: prefs,
              size: Size(box.maxWidth, box.maxHeight), sidesOnly: true, levels: _loader!.bookLevels,
              levelsNow: () => _loader?.levelsNow));
        },
      );

  /// The page area the layout follows (one page or two, the pairs' pictures): [_area] once it has stayed put for
  /// [settle]. Meanwhile the pages showing stay as they are, fitted to the new shape - a rotation passes through
  /// several sizes, and a tilt can turn the screen and back within a second; each rebuilt every page near the one
  /// being read, and Android closed the app for memory (user, 2026-10-24: "can we just be smarter about how and when
  /// images are generated").
  Size _settled = Size.zero;
  Timer? _settleTimer;
  @visibleForTesting
  static const settle = Duration(milliseconds: 500);

  void _areaNow(Size area) {
    _area = area;
    if (_settled.isEmpty) {
      _settled = area;
    } else if (area == _settled) {
      _settleTimer?.cancel(); // back as it was (turned and back): nothing to redo
    } else {
      _settleTimer?.cancel();
      _settleTimer = Timer(settle, () {
        _settled = _area;
        _changed();
      });
    }
  }

  List<Widget> _pagedView(BuildContext context) => [
        LayoutBuilder(builder: (context, box) {
          _areaNow(Size(box.maxWidth, box.maxHeight));
          // one page or two, by the screen's shape (turned, a window resized - once it's settled) and the setting:
          // the page view again after this frame, on the same page
          final dual = pages.isNotEmpty && _twoPagesOn(_settled);
          final scrolls = ScrollConfiguration.of(context); // the pages' own scrolling (the page view's is off)
          if (dual != _dual) WidgetsBinding.instance.addPostFrameCallback((_) => _rebuildView(dual: dual));
          return Listener(
            // wheel over the end card or a loading page (over a page, the page itself takes it)
            onPointerSignal: (e) {
              if (e is PointerScrollEvent && !HardwareKeyboard.instance.isControlPressed) {
                GestureBinding.instance.pointerSignalResolver
                    .register(e, (ev) => wheel((ev as PointerScrollEvent).scrollDelta.dy));
              }
            },
            onPointerDown: (e) {
              host.awake();
              _setFingers(_fingers + 1);
              _rightDown = e.buttons == kSecondaryButton; // (a mouse, or a pen's side button)
            },
            // a right-click: the controls, however far the mouse moved meanwhile - a right drag means nothing here,
            // and past Flutter's 18 px the click was lost (user, build 108: "right clicks get missed if the mouse
            // moves")
            onPointerUp: (_) {
              _setFingers(_fingers - 1);
              if (_rightDown) {
                _rightDown = false;
                host.toggleControls();
              }
            },
            onPointerCancel: (_) {
              _setFingers(_fingers - 1);
              _rightDown = false;
            },
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              // (drags that turn: the turn area over the pages, below)
              onTapUp: (d) => _onTapUp(d, box.maxWidth),
              child: RepaintBoundary(
                key: _curl.boundary,
                // the background inside the snapshots: transparent there, the bars round a page let the new view
                // show through what a turn holds of the old one (user, 2026-10-17: the spread beside the cover "just
                // pops into existence as soon as the curl starts")
                child: ColoredBox(
                  color: background,
                  child: NotificationListener<ScrollNotification>(
                    onNotification: _onPagesScroll,
                    // the page view's own drag off: a drag turns through the turn area (below), which decides
                    // it - the page's own (zoom, scrolling) restored inside
                    child: ScrollConfiguration(
                    behavior: ScrollConfiguration.of(context).copyWith(dragDevices: const {}),
                    child: PageView.builder(
                      // a fresh page view for each book: kept, it hands the new controller the last book's place
                      // (moving on from an end card opened the next book on its own end card - tablet, 2026-09-30)
                      key: ValueKey((_book['id'], _viewGen)),
                      controller: pc,
                      // keep the neighbours built, so they're processed before they're turned to (in every mode: a
                      // wipe used to build - and process - the next page while it slid in)
                      allowImplicitScrolling: true,
                      reverse: rtl, // right to left: page 1 on the right, swipe left-to-right goes forward
                      // zoomed, pinching, or a sideways page: a drag moves the page, not to the next one
                      physics: zoomed || _fingers > 1 || _sideways.contains(_at) || _curlMode
                          ? const NeverScrollableScrollPhysics()
                          : null,
                      itemCount: _views + 1,
                      onPageChanged: _onPage,
                      itemBuilder: (_, v) => ScrollConfiguration(behavior: scrolls,
                          child: Builder(builder: (context) => v == _views ? host.endCard() : _view(context, v))),
                    ),
                    ),
                  ),
                ),
              ),
            ),
          );
        }),
        // a drag that turns the page, told from the page's own gestures (the zoom, scrolling) before they hear it
        Positioned.fill(child: TurnDragArea(configure: _configureTurn)),
        Positioned.fill(child: _curl.overlay()),
      ];

  /// The page view's item [v]: a page - or, two pages up, a spread: a pair joined side by side as one picture (fit,
  /// zoom, pan and Enhance work on it as on a page), or a page alone, centred (user, 2026-10-16).
  Widget _view(BuildContext context, int v) {
    if (!_dual) return _page(context, v, _loader!.get(v));
    final s = _spreads[v];
    if (s.pages.length == 1) return _page(context, v, _loader!.get(s.first));
    // (cropped page by page before they're joined: the pages meet at the spine, not their cut-off margins)
    return _page(context, v, _joinedAt(v, s), prefs: prefs.copyWith(crop: 0));
  }

  /// Two pages joined, by item, the crop and the direction they were joined in - the ones near the page being read.
  final Map<(int, double, bool, double, FitMode, Size, Color), Future<PageData>> _joined = {};

  Future<PageData> _joinedAt(int v, Spread s) {
    // the pair showing and one turn either way (the page view builds no further) - each is two pages wide
    _joined.removeWhere((k, _) => (k.$1 - _at).abs() > 1);
    final crop = prefs.crop;
    final key = (v, crop, rtl, prefs.gutter, prefs.fit, _settled, background);
    // one picture per pair: the one for an older size or setting goes (a rotation passes through several sizes as
    // the bars move, and each pair was joined again for each, every copy kept - two full pages wide each; user,
    // 2026-10-24: the app died turning the tablet with two pages up)
    _joined.removeWhere((k, _) => k.$1 == v && k != key);
    return _joined.putIfAbsent(key, () async {
      try {
        final pair = await Future.wait([_loader!.get(s.earlier!), _loader!.get(s.later!)]);
        final images = [for (final p in pair) crop > 0 ? await cropEdges(p.image, crop) : p.image];
        final onScreen = rtl ? images.reversed.toList() : images;
        // the gutter: the left page's share of the width, the two at one height (as joinPages joins them)
        final h = math.max(onScreen[0].height, onScreen[1].height);
        double w(ui.Image i) => i.width * h / i.height;
        final w0 = w(onScreen[0]) + w(onScreen[1]), gap = _gapPixels(h.toDouble(), w0);
        _spineAt[v] = (w(onScreen[0]) + gap / 2) / (w0 + gap);
        _gapAt[v] = gap / (w0 + gap);
        return PageData(await joinPages(onScreen, gap: gap, fill: background), Uint8List(0));
      } catch (_) {
        _joined.remove(key)?.ignore(); // Retry joins them again
        rethrow;
      }
    });
  }

  Widget _page(BuildContext context, int i, Future<PageData> data, {ReaderPrefs? prefs}) {
    return FutureBuilder<PageData>(
      future: data,
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
          data: snap.data!, prefs: prefs ?? this.prefs, scroll: _scrollFor(i),
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
          idle: i == _at ? null : _whenIdle, // neighbours: processed between turns, not during one
          current: i == _at, // moved off, a zoomed page goes back to fit
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
  final readerNode = FocusNode(debugLabel: 'ctl-reader');
  final stripNode = FocusNode(debugLabel: 'ctl-strip');

  /// The top bar's own: the fit (one press = the next fit mode: screen -> width -> height -> original size).
  @override
  List<BarButton> topButtons() {
    // a webtoon: Original size or Fit width, one press the other (user, 2026-10-22)
    final fit = webtoon ? WebtoonView.fitOf(prefs.fit) : prefs.fit;
    // (a strip: its own size -> Fit width -> Fit page height - user, 2026-10-22)
    final next = webtoon
        ? switch (fit) { FitMode.original => FitMode.width, FitMode.width => FitMode.height, _ => FitMode.original }
        : FitMode.values[(fit.index + 1) % FitMode.values.length];
    return [
      BarButton(
        fitNode,
        IconButton(
          focusNode: fitNode,
          // (a strip's height fit: one page to the screen's height - 'Fit page height', as its panel says)
          tooltip: fit == FitMode.original
              ? 'Original size'
              : webtoon && fit == FitMode.height
                  ? 'Fit page height'
                  : 'Fit ${fit.label.toLowerCase()}',
          onPressed: () => _setFit(next),
          icon: fitIcon(fit, size: 26, color: Colors.white), // ↔ / ↕ (display_panel.dart)
        ),
      ),
    ];
  }

  /// The bottom bar's own: the page strip, auto-scroll (a webtoon), the reader's settings (the image settings in them).
  @override
  List<BarButton> bottomButtons(BuildContext context) => [
        if (pages.length > 1)
          BarButton(pagesNode, barIcon(node: pagesNode, icon: _stripOpen ? Icons.view_carousel : Icons.view_carousel_outlined,
              label: _stripOpen ? 'Hide pages' : 'Show pages', onPressed: _toggleStrip)),
        // a webtoon: auto-scroll, play / pause
        if (webtoon && _strip != null)
          BarButton(autoNode, barIcon(node: autoNode, icon: autoScrolling ? Icons.stop : Icons.play_arrow,
              label: autoScrolling ? 'Stop auto-scroll' : 'Auto-scroll', onPressed: autoScrollToggle)),
        BarButton(readerNode, barIcon(node: readerNode, icon: Icons.tune,
            label: _komgaWebtoon ? 'Webtoon settings' : 'Comic settings',
            onPressed: () => showReaderPanel(context, webtoon: _komgaWebtoon,
                seriesId: seriesId, seriesTitle: _book['seriesTitle'] as String?,
                komgaDirection: _komgaDirection, bookFit: _bookFit,
                page: canSaveCopyPictures && index <= last ? PageActions(save: _savePage, copy: _copyPage) : null,
                // two pages up: pairs a page off (a scan missing a page, a spread split across two pairs) - this book,
                // synced (user, 2026-10-22: in the panel, not on the bottom bar)
                shiftBook: _dual && pages.length > 2 ? _book['id'] as String : null,
                shift: shiftPairing,
                api: api))),
      ];

  /// The top bar's fit button: the series' own fit when it overrides the default layout (saved, synced); otherwise
  /// this book only, for now (the Comic settings panel's toggle turns the override on). A book with no series: the default.
  void _setFit(FitMode f) {
    final id = seriesId;
    if (id == null) {
      _settings.setDefault(_settings.defaults.copyWith(fit: f)); // (no series: not Komga's webtoon - it's a series')
    } else if (_settings.ownsLayout(id)) {
      _settings.setSeriesLayout(id, prefs.copyWith(fit: f));
    } else {
      _bookFit = f;
      _changed();
    }
  }

  // ---- Save page / Copy page (the Comic settings panel; user, 2026-10-02): the page's own image as Komga sends it - not the
  // picture on screen (no crop, levels or Enhance) - from what's loaded already, else asked for

  static String titleOf(dynamic b) => bookTitle(b);

  /// The page being read: (its picture file, a name for it). Null on the end card, or a choice not made. Two pages
  /// up, a pair: which one is asked - the left, the right, or both as one picture (user, 2026-10-16).
  Future<(Uint8List, String)?> _pageFile() async {
    if (index > last || _loader == null) return null;
    final shown = _pagesAt(_at);
    if (shown.length < 2) return _fileOf(shown.isEmpty ? index : shown.first);
    final left = rtl ? shown.last : shown.first, right = rtl ? shown.first : shown.last;
    final pick = await showDialog<String>(
      context: host.context,
      builder: (ctx) => SimpleDialog(title: const Text('Which page?'), children: [
        SimpleDialogOption(onPressed: () => Navigator.pop(ctx, 'left'), child: Text('Left (page ${left + 1})')),
        SimpleDialogOption(onPressed: () => Navigator.pop(ctx, 'right'), child: Text('Right (page ${right + 1})')),
        SimpleDialogOption(onPressed: () => Navigator.pop(ctx, 'both'), child: const Text('Both, as one picture')),
      ]),
    );
    if (pick == null) return null;
    if (pick != 'both') return _fileOf(pick == 'left' ? left : right);
    // the two files as Komga sends them, side by side as they show (not cropped or enhanced, as a page alone)
    final images = [for (final i in [left, right]) (await _loader!.get(i)).image];
    final joined = await joinPages(images);
    try {
      final png = await joined.toByteData(format: ui.ImageByteFormat.png);
      if (png == null) throw StateError('the picture could not be made');
      return (png.buffer.asUint8List(), '${titleOf(_book)} - pages ${shown.first + 1}-${shown.last + 1}');
    } finally {
      joined.dispose();
    }
  }

  Future<(Uint8List, String)> _fileOf(int i) async {
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
          // the whole book fits across: the strip in the middle, not against the start (user, 2026-10-22)
          final side = math.max(8.0, (box.maxWidth - ((last + 1) * (w + _stripGap) - _stripGap)) / 2);
          return SizedBox(
            height: h + 16 + 10, // room for the way-back mark under a tile
            child: ListView.builder(
              controller: _stripScroll,
              scrollDirection: Axis.horizontal,
              reverse: rtl,
              padding: EdgeInsets.fromLTRB(side, 8, side, 0),
              itemExtent: w + _stripGap,
              itemCount: last + 1,
              itemBuilder: (context, i) {
                final current = _dual ? _pagesAt(_at).contains(i) : i == index; // (both pages of a pair)
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
  /// of it and its number, over the thumb at [x] - always (user, 2026-10-21: the switch for just the number went).
  @override
  Widget preview(BuildContext context, int shown, double x) {
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
    if (failed != null && clock.now().difference(failed) < _thumbRetry) return null;
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
          _thumbsFailed[i] = clock.now(); // too slow, or no answer: try again a little later, not never
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
