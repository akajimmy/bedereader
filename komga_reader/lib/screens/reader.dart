import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';

import '../api.dart';
import '../offline/connection.dart';
import '../page_curl.dart';
import '../page_image.dart';
import '../screen.dart';
import '../settings.dart';
import '../widgets/display_panel.dart';
import '../widgets/focus_style.dart';
import 'actions.dart';

/// Page reader: black background, full screen, follows the tablet's rotation (tilt for spreads).
///
/// Remote: Right/Down = forward, Left/Up = back (in fit width/height that first scrolls through the page).
/// OK = show/hide the controls, like a tap in the middle. With the controls up, the arrows step through them one at a
/// time (after the last comes "nothing selected", where OK hides them again); OK on a control = tapping it; OK on the
/// page slider starts scrubbing (arrows change the page, OK jumps there).
///
/// Touch: tap the left/right third to go back/forward, the middle for the controls; any tap off the controls hides
/// them. Pinch to zoom in fit-screen mode. Progress goes straight to Komga (no local copy).
class ReaderScreen extends StatefulWidget {
  const ReaderScreen({super.key, required this.api, required this.book, this.readListId});
  final Komga api;
  final dynamic book;
  final String? readListId; // continue within this read list at the end of the book
  @override
  State<ReaderScreen> createState() => _ReaderScreenState();
}

enum _Ctl { close, fit, night, fullscreen, read, delete, prevBook, slider, image, reader, nextBook }

class _ReaderScreenState extends State<ReaderScreen> with SingleTickerProviderStateMixin {
  late dynamic _book = widget.book;
  List<dynamic> _pages = [];
  PageLoader? _loader;
  PageController? _pc;
  int _index = 0;
  bool _menu = false; // controls shown
  int? _scrub; // page picked on the slider but not jumped to yet
  bool _scrubbing = false; // remote is driving the slider
  int? _startAtEnd; // page to show from its bottom/right end (came back from the next page)
  bool _loading = true;
  bool _turned = false; // progress is only saved once a page has been turned in this visit
  int _openedAt = 0;
  bool _zoomed = false; // pinch-zoomed in: page swiping is paused so a drag pans the page
  final Set<int> _sideways = {}; // pages (fit height, wider than the screen) that a drag moves sideways
  bool get _fullscreen => fullscreen.value; // desktop, whole app: F11 / the full-screen button (lib/screen.dart)
  double _wheelAcc = 0; // mouse wheel travel towards the next page turn
  DateTime _lastWheelTurn = DateTime(0);
  int _fingers = 0; // two or more on the page = a pinch: page swiping pauses at once so it can't steal the gesture
  Timer? _saveTimer;
  Timer? _flashTimer;
  bool _flash = false; // the page number shows for a moment after a turn (setting: Show the page number after a turn)
  final Map<int, ScrollController> _scrolls = {};
  final Map<int, bool Function(bool forward)> _steppers = {}; // zoomed-in pan steps, per page (page_image.dart)
  final FocusNode _keys = FocusNode(debugLabel: 'reader-keys', skipTraversal: true);
  final FocusNode _sliderInner = FocusNode(canRequestFocus: false, skipTraversal: true); // the wrapper takes focus
  final Map<_Ctl, FocusNode> _ctl = {for (final c in _Ctl.values) c: FocusNode(debugLabel: 'ctl-${c.name}')};

  Komga get api => widget.api;
  int get _last => _pages.length - 1;
  AppSettings get _settings => AppSettings.instance;
  String? get _seriesId => _book['seriesId'] as String?;
  ReaderPrefs get _prefs => _settings.prefsFor(_seriesId);

  /// The series' reading direction in Komga (LEFT_TO_RIGHT, RIGHT_TO_LEFT, VERTICAL, WEBTOON), fetched on open.
  String? _komgaDirection;
  String? _directionSeries; // which series _komgaDirection belongs to

  /// Right to left: forced per series, or (on Auto) because Komga says so. Vertical/webtoon read as left to right.
  bool get _rtl => switch (_prefs.direction) {
        ReadingDirection.rtl => true,
        ReadingDirection.ltr => false,
        ReadingDirection.auto => _komgaDirection == 'RIGHT_TO_LEFT',
      };

  @override
  void initState() {
    super.initState();
    Connection.instance.readerOpened(); // an automatic switch back online waits for the book to close
    // Follow the sensor (the whole app does, via the manifest), hide the system bars, keep the screen on.
    SystemChrome.setPreferredOrientations(DeviceOrientation.values);
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    keepScreenOn(true);
    _settings.addListener(_onSettings);
    fullscreen.addListener(_onFullscreen); // F11 is app-wide (main.dart): the button follows
    PageCurl.program().ignore(); // load the curl shader ahead of the first turn
    _curlAnim
      ..addListener(_onCurlTick)
      ..addStatusListener((s) { if (s == AnimationStatus.completed) _endCurl(); });
    _open(_book);
  }

  @override
  void dispose() {
    _saveTimer?.cancel();
    _flashTimer?.cancel();
    _curlAnim.dispose();
    _curl?.dispose();
    _idle?.complete(); // nothing left waiting
    Connection.instance.readerClosed();
    _saveNow();
    _settings.removeListener(_onSettings);
    fullscreen.removeListener(_onFullscreen);
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    keepScreenOn(false);
    _pc?.dispose();
    _disposeScrolls();
    _keys.dispose();
    _sliderInner.dispose();
    for (final n in _ctl.values) {
      n.dispose();
    }
    super.dispose();
  }

  void _onSettings() { if (mounted) setState(() {}); }

  void _disposeScrolls() {
    for (final c in _scrolls.values) {
      c.dispose();
    }
    _scrolls.clear();
  }

  ScrollController _scrollFor(int i) => _scrolls.putIfAbsent(i, ScrollController.new);

  Future<void> _open(dynamic book) async {
    setState(() { _loading = true; _book = book; _menu = false; });
    try {
      final fresh = await api.book(book['id']) ?? book; // current progress from the server
      final pages = await api.pages(book['id']);
      final seriesId = fresh['seriesId'] as String?;
      if (seriesId != null && seriesId != _directionSeries) {
        try {
          _komgaDirection = (await api.oneSeries(seriesId))?['metadata']?['readingDirection'] as String?;
        } catch (_) {
          _komgaDirection = null; // unknown: left to right
        }
        _directionSeries = seriesId;
      }
      final rp = fresh['readProgress'];
      final start = rp == null || rp['completed'] == true ? 0 : ((rp['page'] as int) - 1).clamp(0, pages.length - 1);
      _pc?.dispose();
      _disposeScrolls();
      final loader = PageLoader(api, fresh['id'] as String,
          [for (var i = 0; i < pages.length; i++) (pages[i]['number'] ?? i + 1) as int]);
      if (pages.isNotEmpty) loader.around(start);
      setState(() {
        _book = fresh; _pages = pages; _index = start; _loader = loader;
        _openedAt = start; _turned = false; _zoomed = false;
        _pc = PageController(initialPage: start);
        _loading = false;
      });
      _keys.requestFocus();
    } catch (e) {
      if (mounted) {
        setState(() => _loading = false);
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
      }
    }
  }

  // ---- progress: saved 1.5 s after the page settles, and on leaving
  void _onPage(int i) {
    setState(() { _index = i; _zoomed = false; if (i != _openedAt) _turned = true; });
    _saveTimer?.cancel();
    _saveTimer = Timer(const Duration(milliseconds: 1500), _saveNow);
    if (i <= _last) _loader?.around(i);
    if (i >= _last - 1) _upNext().ignore(); // look up what's next before the end card shows (errors: shown there)
    if (i <= _last && _settings.display.pageNumber) {
      _flashTimer?.cancel();
      setState(() => _flash = true);
      _flashTimer = Timer(const Duration(milliseconds: 1200), () { if (mounted) setState(() => _flash = false); });
    }
  }

  /// Opening a book and closing it without turning a page leaves no trace. Turning pages in a finished book starts
  /// it over (Komga's own behaviour).
  void _saveNow() {
    if (!_turned || _pages.isEmpty) return;
    // the end card counts as the last page: finished (closing from it used to save nothing if the last page's
    // save hadn't happened yet - the 1.5 s settle timer is cancelled by the turn onto the card)
    final page = math.min(_index, _last);
    api.setProgress(_book['id'], page + 1, completed: page >= _last).catchError((_) {});
  }

  // ---- navigation (the page after the last is the "end of book" card)
  static const _turn = Duration(milliseconds: 180);

  /// Forward: in fit width/height scroll on through the page first, then turn.
  void _forward() {
    if (_pc == null) return;
    if (_index >= _pages.length) { _nextBook(); return; }
    if (_zoomed && (_steppers[_index]?.call(true) ?? false)) return; // zoomed in: pan along the page first
    final c = _scrolls[_index];
    if (_prefs.fit != FitMode.screen && c != null && c.hasClients) {
      final p = c.position;
      if (p.pixels < p.maxScrollExtent - 1) {
        c.animateTo((p.pixels + p.viewportDimension * 0.85).clamp(0, p.maxScrollExtent), duration: _turn, curve: Curves.easeOut);
        return;
      }
    }
    _turnPage(next: true);
  }

  /// Back: scroll back through the page first; the previous page then opens at its end.
  void _back() {
    if (_pc == null) return;
    if (_zoomed && (_steppers[_index]?.call(false) ?? false)) return; // zoomed in: pan back along the page first
    final c = _scrolls[_index];
    if (_prefs.fit != FitMode.screen && c != null && c.hasClients && c.position.pixels > 1) {
      final p = c.position;
      c.animateTo((p.pixels - p.viewportDimension * 0.85).clamp(0, p.maxScrollExtent), duration: _turn, curve: Curves.easeOut);
      return;
    }
    if (_index == 0) return;
    if (_prefs.fit != FitMode.screen) {
      _scrolls.remove(_index - 1)?.dispose(); // fresh controller so the page lays out again from its end
      _startAtEnd = _index - 1;
    }
    _turnPage(next: false);
  }

  /// One page on or back, in the chosen animation: Wipe (slide), Instant flip, or 3D page curl.
  void _turnPage({required bool next}) {
    final target = next ? _index + 1 : _index - 1;
    if (target < 0 || target > _pages.length) return;
    if (_curlMode) {
      final page = _pageRect(next ? _index : target);
      final grab = Offset(page.width, page.height * 0.72);
      final start = next ? grab : Offset(PageCurl.gone(page.width), grab.dy);
      if (_startCurl(next: next, page: page, grab: grab, finger: start)) {
        _animateCurl(complete: true);
        return;
      }
      _pc!.jumpToPage(target); // couldn't snapshot the page: turn instantly
    } else if (_settings.display.pageTurn == PageTurn.flip) {
      _pc!.jumpToPage(target);
    } else {
      _pc!.animateToPage(target, duration: _turn, curve: Curves.easeOut);
    }
  }

  // ---- 3D page curl (Page turn animation; lib/page_curl.dart) ----------------------------------------------------
  // A turn jumps the page view to the target page at once and draws the turning page over it from a snapshot:
  // forward, this page curls away over the next; back, the previous page uncurls over this one (a snapshot of this
  // page covers the view until then). Letting go before halfway springs back and jumps back.
  final _pagesKey = GlobalKey(); // repaint boundary around the page view: the snapshots
  late final AnimationController _curlAnim =
      AnimationController(vsync: this, duration: const Duration(milliseconds: 380));
  _Curl? _curl;
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
  bool get _curlDrag => _curlMode && !_zoomed && _fingers <= 1 && !_sideways.contains(_index) && _pc != null && !_menu;

  /// Positions in reading-direction space (x from the right edge in a right-to-left book).
  Offset _reading(Offset p) => _rtl ? Offset(_area.width - p.dx, p.dy) : p;

  /// A screen position in [page]'s own coordinates, in reading direction (origin top-left; top-right for a
  /// right-to-left book) - how the curl's geometry is worked out.
  Offset _pagePoint(Offset screen, Rect page) =>
      Offset(_rtl ? page.right - screen.dx : screen.dx - page.left, screen.dy - page.top);

  ui.Image? _snapshot() {
    final b = _pagesKey.currentContext?.findRenderObject();
    if (b is! RenderRepaintBoundary || !b.hasSize) return null;
    try {
      return b.toImageSync(pixelRatio: MediaQuery.devicePixelRatioOf(context));
    } catch (_) {
      return null;
    }
  }

  bool _startCurl({required bool next, required Rect page, required Offset grab, required Offset finger}) {
    final target = next ? _index + 1 : _index - 1;
    if (target < 0 || target > _pages.length || _pc == null || _area.isEmpty) return false;
    _finishCurlNow();
    final now = _snapshot();
    if (now == null) return false;
    final c = _Curl(sheet: now, forward: next, page: page, grab: grab, finger: finger, from: _index,
        under: next ? null : now, pending: !next);
    _curl = c;
    _pc!.jumpToPage(target);
    setState(() {});
    if (!next) {
      // the previous page is now in the view (under the cover): snapshot it to uncurl
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_curl != c || !c.pending) return;
        final prev = _snapshot();
        if (prev == null) { _endCurl(cancel: true); return; }
        setState(() { c.sheet = prev; c.pending = false; });
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
    setState(() => c.finger = Offset.lerp(c.animFrom, c.animTo, Curves.easeOut.transform(_curlAnim.value))!);
  }

  /// The turn is over: let go before halfway -> back to where it started.
  void _endCurl({bool cancel = false}) {
    final c = _curl;
    if (c == null) return;
    _curl = null;
    if (cancel || !c.completing) _pc?.jumpToPage(c.from);
    _maybeIdle();
    setState(() {});
    WidgetsBinding.instance.addPostFrameCallback((_) => c.dispose());
  }

  /// Another turn while one is playing: finish that one at once.
  void _finishCurlNow() {
    if (_curl == null) return;
    _curlAnim.stop();
    _endCurl();
  }

  Offset? _dragStartScreen;

  void _curlDragStart(DragStartDetails d) {
    _finishCurlNow(); // a quick second swipe: the turn still playing ends at once instead of eating this one
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
      final page = _pageRect(next ? _index : _index - 1);
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
    setState(() {
      c.finger = c.forward ? Offset(w + (gone - w) * t, y) : Offset(gone + (w - gone) * t, y);
    });
  }

  void _curlDragEnd(DragEndDetails d) {
    final c = _curl;
    _dragStart = null;
    if (c == null || _curlAnim.isAnimating) return;
    final w = c.page.width, gone = PageCurl.gone(w);
    var vx = d.velocity.pixelsPerSecond.dx;
    if (_rtl) vx = -vx;
    final turned = (w - c.finger.dx) / (w - gone); // 0 = flat on this page, 1 = turned away
    // a flick (diagonal ones carry less sideways speed) or a slow drag about a third of the way
    final complete = c.forward
        ? vx < -250 || (vx < 250 && turned > 0.3)
        : vx > 250 || (vx > -250 && turned < 0.7);
    _animateCurl(complete: complete);
  }

  /// Next book. On the last page or the end card the current book is marked read; before that, ask.
  Future<void> _nextBook() async {
    final finished = _index >= _last;
    var markRead = finished;
    if (!finished) {
      final answer = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text('Mark #${_book['metadata']?['number'] ?? ''} as read?'),
          content: Text('You are on page ${_index + 1} of ${_pages.length}.'),
          actions: [
            TextButton(autofocus: true, onPressed: () => Navigator.pop(ctx, false), child: const Text('Keep in progress')),
            TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Mark read')),
          ],
        ),
      );
      if (answer == null || !mounted) return; // dismissed: stay
      markRead = answer;
    }
    _saveTimer?.cancel();
    try {
      if (markRead) {
        await api.markRead(_book['id']);
      } else {
        _saveNow();
      }
      final next = await api.nextBook(_book['id'], readListId: widget.readListId);
      if (!mounted) return;
      if (next == null) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text(widget.readListId != null ? 'End of the read list' : 'End of the series')));
        Navigator.of(context).pop();
      } else {
        _open(next);
      }
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
    }
  }

  /// Previous book (in the read list it was opened from, else the series). Nothing is marked; this book's place is
  /// kept if a page was turned.
  Future<void> _prevBook() async {
    _saveTimer?.cancel();
    _saveNow();
    try {
      final prev = await api.previousBook(_book['id'], readListId: widget.readListId);
      if (!mounted) return;
      if (prev == null) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text(widget.readListId != null ? 'This is the first book of the read list' : 'This is the first book of the series')));
      } else {
        _open(prev);
      }
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
    }
  }

  /// Delete the open book's file on the server (confirmed first, Cancel focused), then close the reader.
  Future<void> _deleteBook() async {
    final title = '${_book['seriesTitle'] ?? ''} #${_book['metadata']?['number'] ?? ''}';
    final ok = await confirmDelete(context, 'Delete "$title"?',
        'This deletes the file from the server. It cannot be undone from the app.');
    if (!ok || !mounted) return;
    try {
      await api.deleteBookFile(_book['id']);
      _turned = false; // nothing left to save progress to
      _saveTimer?.cancel();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Deleted $title')));
      Navigator.of(context).pop();
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
    }
  }

  /// After an explicit mark read/unread, don't let the automatic save undo it.
  Future<void> _afterMark() async {
    _saveTimer?.cancel();
    _turned = false;
    _openedAt = _index;
    final fresh = await api.book(_book['id']).catchError((_) => null);
    if (mounted && fresh != null) setState(() => _book = fresh);
  }

  // ---- controls
  void _showControls() => setState(() { _menu = true; _scrubbing = false; _scrub = null; });

  void _hideControls() {
    setState(() { _menu = false; _scrub = null; _scrubbing = false; });
    _keys.requestFocus();
  }

  /// The two bars, left to right, as the remote walks them.
  List<_Ctl> get _topBar => [_Ctl.close, _Ctl.fit, _Ctl.night, if (isDesktop) _Ctl.fullscreen, _Ctl.read, _Ctl.delete];
  List<_Ctl> get _bottomBar => [
        _Ctl.prevBook,
        if (_pages.length > 1) _Ctl.slider,
        if (_seriesId != null) _Ctl.image,
        _Ctl.reader, _Ctl.nextBook,
      ];

  /// Remote in the controls (user's layout): Left/Right move along a bar and stop at its ends; Up/Down switch between
  /// the top and bottom bar (keeping the position as near as possible). Up from the top bar or Down from the bottom
  /// bar leaves the bars ("nothing selected", where OK hides the controls). From nothing selected: Up or Left/Right
  /// -> top bar, Down -> bottom bar.
  void _move({int dx = 0, int dy = 0}) {
    final top = _topBar, bottom = _bottomBar;
    final inTop = top.indexWhere((c) => _ctl[c]!.hasFocus);
    final inBottom = bottom.indexWhere((c) => _ctl[c]!.hasFocus);
    _Ctl? target;
    if (inTop < 0 && inBottom < 0) {
      target = dy > 0 ? bottom.first : top.first;
    } else {
      final bar = inTop >= 0 ? top : bottom, i = inTop >= 0 ? inTop : inBottom;
      if (dx != 0) {
        target = bar[(i + dx).clamp(0, bar.length - 1)];
      } else if (inTop >= 0) {
        target = dy > 0 ? bottom[i.clamp(0, bottom.length - 1)] : null;
      } else {
        target = dy < 0 ? top[i.clamp(0, top.length - 1)] : null;
      }
    }
    target == null ? _keys.requestFocus() : _ctl[target]!.requestFocus();
    setState(() {});
  }

  bool _isOk(LogicalKeyboardKey k) =>
      k == LogicalKeyboardKey.enter || k == LogicalKeyboardKey.select || k == LogicalKeyboardKey.numpadEnter;
  // Left/Right follow the reading direction (right to left: Left goes forward); Up/Down and Page Up/Down don't.
  bool _isFwd(LogicalKeyboardKey k) =>
      k == (_rtl ? LogicalKeyboardKey.arrowLeft : LogicalKeyboardKey.arrowRight) ||
      k == LogicalKeyboardKey.arrowDown || k == LogicalKeyboardKey.pageDown;
  bool _isBack(LogicalKeyboardKey k) =>
      k == (_rtl ? LogicalKeyboardKey.arrowRight : LogicalKeyboardKey.arrowLeft) ||
      k == LogicalKeyboardKey.arrowUp || k == LogicalKeyboardKey.pageUp;

  Future<void> _toggleFullscreen() => toggleFullscreen(); // stays on after the book closes (user)
  void _onFullscreen() { if (mounted) setState(() {}); }

  /// Mouse wheel over the page (desktop): in fit width/height it scrolls through the page first; otherwise (or at
  /// the page's end) one notch turns one page - trackpad flicks are gathered up so they don't skip several pages.
  void _onWheel(double dy) {
    if (_menu || _pc == null) return;
    final c = _scrolls[_index];
    if (_prefs.fit != FitMode.screen && c != null && c.hasClients) {
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
    final forward = _wheelAcc > 0;
    _wheelAcc = 0;
    final now = DateTime.now();
    if (now.difference(_lastWheelTurn) < const Duration(milliseconds: 250)) return;
    _lastWheelTurn = now;
    forward ? _forward() : _back();
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent e) {
    if (e is! KeyDownEvent && e is! KeyRepeatEvent) return KeyEventResult.ignored;
    final k = e.logicalKey;
    if (!_menu) {
      if (_isFwd(k) || (k == LogicalKeyboardKey.space && !HardwareKeyboard.instance.isShiftPressed)) {
        _forward();
        return KeyEventResult.handled;
      }
      if (_isBack(k) || k == LogicalKeyboardKey.space) { _back(); return KeyEventResult.handled; }
      if (_isOk(k) && e is KeyDownEvent) { _showControls(); return KeyEventResult.handled; }
      if (k == LogicalKeyboardKey.escape && e is KeyDownEvent) { // nothing showing: Esc closes the book (full screen stays)
        Navigator.of(context).maybePop();
        return KeyEventResult.handled;
      }
      return KeyEventResult.ignored;
    }
    if (k == LogicalKeyboardKey.escape || k == LogicalKeyboardKey.goBack) { _hideControls(); return KeyEventResult.handled; }
    if (k == LogicalKeyboardKey.arrowRight) { _move(dx: 1); return KeyEventResult.handled; }
    if (k == LogicalKeyboardKey.arrowLeft) { _move(dx: -1); return KeyEventResult.handled; }
    if (k == LogicalKeyboardKey.arrowDown) { _move(dy: 1); return KeyEventResult.handled; }
    if (k == LogicalKeyboardKey.arrowUp) { _move(dy: -1); return KeyEventResult.handled; }
    if (_isOk(k) && _keys.hasPrimaryFocus) {
      if (e is KeyDownEvent) _hideControls(); // nothing selected: OK hides, like a tap
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored; // OK on a control reaches the control (= tapping it)
  }

  /// The slider under the remote: OK starts scrubbing, arrows then move the page, OK jumps there.
  KeyEventResult _onSliderKey(FocusNode node, KeyEvent e) {
    if (e is! KeyDownEvent && e is! KeyRepeatEvent) return KeyEventResult.ignored;
    final k = e.logicalKey;
    if (_isOk(k)) {
      if (e is! KeyDownEvent) return KeyEventResult.handled;
      if (_scrubbing) {
        final target = _scrub ?? _index;
        setState(() { _scrubbing = false; _scrub = null; });
        if (target != _index) _pc?.jumpToPage(target);
      } else {
        setState(() { _scrubbing = true; _scrub = _index.clamp(0, _last); });
      }
      return KeyEventResult.handled;
    }
    if (_scrubbing && (_isFwd(k) || _isBack(k))) {
      setState(() => _scrub = ((_scrub ?? _index) + (_isFwd(k) ? 1 : -1)).clamp(0, _last));
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored; // not scrubbing: arrows go on to the next control
  }

  void _setFingers(int n) {
    final pinch = n > 1;
    final wasPinch = _fingers > 1;
    _fingers = n < 0 ? 0 : n;
    if (pinch != wasPinch) setState(() {});
  }

  void _setFit(FitMode f) {
    final id = _seriesId;
    final p = _prefs.copyWith(fit: f);
    id != null ? _settings.setSeries(id, p) : _settings.setDefault(p);
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      // Back (tablet or remote) closes the controls first, then the book
      canPop: !_menu,
      onPopInvokedWithResult: (didPop, _) { if (!didPop) _hideControls(); },
      child: Scaffold(
        backgroundColor: Colors.black,
        body: Focus(
          focusNode: _keys,
          autofocus: true,
          onKeyEvent: _onKey,
          child: _loading || _pc == null
              ? const Center(child: CircularProgressIndicator())
              : Stack(children: [
                  LayoutBuilder(builder: (context, box) {
                    _area = Size(box.maxWidth, box.maxHeight);
                    return Listener(
                      // wheel over the end card or a loading page (over a page, the page itself takes it)
                      onPointerSignal: (e) {
                        if (e is PointerScrollEvent && !HardwareKeyboard.instance.isControlPressed) {
                          GestureBinding.instance.pointerSignalResolver
                              .register(e, (ev) => _onWheel((ev as PointerScrollEvent).scrollDelta.dy));
                        }
                      },
                      onPointerDown: (_) => _setFingers(_fingers + 1),
                      onPointerUp: (_) => _setFingers(_fingers - 1),
                      onPointerCancel: (_) => _setFingers(_fingers - 1),
                      child: GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onSecondaryTap: () => _menu ? _hideControls() : _showControls(), // right-click
                      // 3D page curl: a horizontal drag curls the page (the page view doesn't scroll in that mode)
                      onHorizontalDragStart: _curlDrag ? _curlDragStart : null,
                      onHorizontalDragUpdate: _curlDrag ? _curlDragUpdate : null,
                      onHorizontalDragEnd: _curlDrag ? _curlDragEnd : null,
                      onTapUp: (d) {
                        final x = d.localPosition.dx / box.maxWidth;
                        // tap zones follow the reading direction: the side you read towards goes forward
                        if (x < 0.33) { _rtl ? _forward() : _back(); }
                        else if (x > 0.67) { _rtl ? _back() : _forward(); }
                        else { _showControls(); }
                      },
                      child: RepaintBoundary(
                        key: _pagesKey,
                        child: NotificationListener<ScrollNotification>(
                        onNotification: _onPagesScroll,
                        child: PageView.builder(
                        controller: _pc,
                        // keep the neighbours built, so they're processed before they're turned to (in every mode:
                        // a wipe used to build - and process - the next page while it slid in)
                        allowImplicitScrolling: true,
                        reverse: _rtl, // right to left: page 1 on the right, swipe left-to-right goes forward
                        // zoomed, pinching, or a sideways page: a drag moves the page, not to the next one
                        physics: _zoomed || _fingers > 1 || _sideways.contains(_index) || _curlMode
                            ? const NeverScrollableScrollPhysics()
                            : null,
                        itemCount: _pages.length + 1,
                        onPageChanged: _onPage,
                        itemBuilder: (context, i) => i == _pages.length ? _endCard() : _page(i),
                      ),
                      ),
                      ),
                    ));
                  }),
                  if (_curl != null)
                    Positioned.fill(
                      child: IgnorePointer(
                        child: Stack(fit: StackFit.expand, children: [
                          if (_curl!.under != null) RawImage(image: _curl!.under, fit: BoxFit.fill),
                          if (!_curl!.pending)
                            CustomPaint(painter: PageCurlPainter(program: PageCurl.loaded!, sheet: _curl!.sheet,
                                page: _curl!.page, grab: _curl!.grab, finger: _curl!.finger, mirror: _rtl)),
                        ]),
                      ),
                    ),
                  // "12 / 36" for a moment after a turn - not over the controls (they have the count) or the end card
                  Positioned(
                    right: 14,
                    bottom: 14,
                    child: IgnorePointer(
                      child: AnimatedOpacity(
                        opacity: _flash && !_menu && _index <= _last ? 1 : 0,
                        duration: const Duration(milliseconds: 250),
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                          decoration: BoxDecoration(color: Colors.black.withValues(alpha: 0.65),
                              borderRadius: BorderRadius.circular(12)),
                          child: Text('${_index + 1} / ${_pages.length}',
                              style: const TextStyle(color: Colors.white, fontSize: 13)),
                        ),
                      ),
                    ),
                  ),
                  if (_menu) ..._controls(),
                ]),
        ),
      ),
    );
  }

  Widget _page(int i) {
    return FutureBuilder<PageData>(
      future: _loader!.get(i),
      builder: (context, snap) {
        if (snap.hasError) {
          return Center(child: Column(mainAxisSize: MainAxisSize.min, children: [
            const Icon(Icons.broken_image, color: Colors.white24, size: 48),
            TextButton(onPressed: () => setState(() {}), child: const Text('Retry')),
          ]));
        }
        if (!snap.hasData) return const Center(child: CircularProgressIndicator(strokeWidth: 2));
        return PageCanvas(
          data: snap.data!, prefs: _prefs, scroll: _scrollFor(i),
          startAtEnd: _startAtEnd == i,
          levels: _loader!.bookLevels,
          onZoomChanged: (z) { if (z != _zoomed) setState(() => _zoomed = z); },
          onWheel: _onWheel,
          onPanChanged: (pans) => setState(() => pans ? _sideways.add(i) : _sideways.remove(i)),
          onEdgeSwipe: (forward) => _turnPage(next: forward), // dragged on past the page's edge
          onPageRect: (r) => _pageRects[i] = r, // for the page curl (layout only - no rebuild)
          idle: i == _index ? null : _whenIdle, // neighbours: processed between turns, not during one
          onStepper: (step) => step == null ? _steppers.remove(i) : _steppers[i] = step,
          rtl: _rtl,
          onStartedAtEnd: () => _startAtEnd = null,
        );
      },
    );
  }

  /// The book after this one (in the read list it was opened from, else the series) - looked up once per book, when
  /// the last page is near, for the end card.
  Future<Map<String, dynamic>?> _upNext() {
    final id = _book['id'] as String;
    if (_upNextFor != id || _upNextFuture == null) {
      _upNextFor = id;
      _upNextFuture = api.nextBook(id, readListId: widget.readListId).then((next) {
        if (next != null) _cover(next['id'] as String).ignore(); // fetched ahead, like the lookup itself
        return next;
      });
    }
    return _upNextFuture!;
  }

  String? _coverFor;
  Future<Uint8List?>? _coverFuture;

  /// The next book's first page - its cover at full resolution. Komga's thumbnails are small (300 px wide by
  /// default), and blurry at the end card's poster size (user, 2026-09-29). Null if it can't be had (offline and not
  /// downloaded, say): the thumbnail stays.
  Future<Uint8List?> _cover(String bookId) {
    if (_coverFor != bookId || _coverFuture == null) {
      _coverFor = bookId;
      _coverFuture = api.pageBytes(bookId, 1).then<Uint8List?>((b) => b).catchError((Object _) => null);
    }
    return _coverFuture!;
  }

  String? _upNextFor;
  Future<Map<String, dynamic>?>? _upNextFuture;

  /// After the last page: what's next - its poster and title - or that this was the last one.
  Widget _endCard() {
    final where = widget.readListId != null ? 'this read list' : 'the series';
    final arrow = _rtl ? '←' : '→';
    const dim = TextStyle(color: Colors.white38);
    return FutureBuilder<Map<String, dynamic>?>(
      future: _upNext(),
      builder: (context, snap) {
        final next = snap.data;
        final List<Widget> body;
        if (snap.connectionState != ConnectionState.done) {
          body = [const SizedBox(width: 28, height: 28, child: CircularProgressIndicator(strokeWidth: 2))];
        } else if (snap.hasError) {
          body = [Text('$arrow : next book in $where', style: dim)]; // couldn't look it up: the turn still tries
        } else if (next == null) {
          body = [
            Text(widget.readListId != null ? 'End of the read list' : 'End of the series',
                style: const TextStyle(color: Colors.white70, fontSize: 16)),
            const SizedBox(height: 12),
            Text('$arrow : close the book', style: dim),
          ];
        } else {
          final number = next['metadata']?['number'] ?? next['number'];
          final title = (next['metadata']?['title'] ?? next['name']) as String?;
          final heading = '${next['seriesTitle'] ?? ''} #$number'.trim();
          body = [
            Text('Up next in $where', style: dim),
            const SizedBox(height: 12),
            LayoutBuilder(builder: (context, c) {
              final h = (MediaQuery.sizeOf(context).height * 0.42).clamp(160.0, 520.0);
              final dpr = MediaQuery.devicePixelRatioOf(context);
              final id = next['id'] as String;
              // the thumbnail at once, then the cover page itself (sharp) over it when it's in
              return ClipRRect(
                borderRadius: BorderRadius.circular(6),
                child: SizedBox(
                  height: h,
                  width: h * 0.66,
                  child: Stack(fit: StackFit.expand, children: [
                    Image(
                      image: api.thumbImage(api.bookThumb(id)),
                      fit: BoxFit.cover,
                      errorBuilder: (_, __, ___) => Container(color: const Color(0xFF1C1C1F)),
                    ),
                    FutureBuilder<Uint8List?>(
                      future: _cover(id),
                      builder: (context, cover) => cover.data == null
                          ? const SizedBox.shrink()
                          : Image.memory(cover.data!,
                              fit: BoxFit.cover,
                              // decoded at about the size shown (a little over, for covers narrower than the frame)
                              cacheHeight: (h * dpr * 1.25).round(),
                              filterQuality: FilterQuality.medium,
                              errorBuilder: (_, __, ___) => const SizedBox.shrink()),
                    ),
                  ]),
                ),
              );
            }),
            const SizedBox(height: 14),
            Text(heading, textAlign: TextAlign.center, style: const TextStyle(color: Colors.white, fontSize: 18)),
            if (title != null && title != heading && !title.endsWith('#$number'))
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(title, textAlign: TextAlign.center, maxLines: 2, overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: Colors.white70)),
              ),
            const SizedBox(height: 14),
            Text('$arrow : open it', style: dim),
          ];
        }
        return Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              const Text('End of book', style: TextStyle(color: Colors.white70, fontSize: 18)),
              const SizedBox(height: 16),
              ...body,
            ]),
          ),
        );
      },
    );
  }

  /// Icon-only control (user: no labels except Close); the label is the tooltip. White icon.
  Widget _iconCtl({required FocusNode node, required IconData icon, required String label, required VoidCallback onPressed,
      double size = 26}) =>
      IconButton(focusNode: node, tooltip: label, icon: Icon(icon, color: Colors.white, size: size), onPressed: onPressed);

  static const _fitIcons = {FitMode.screen: Icons.fit_screen, FitMode.width: Icons.swap_horiz, FitMode.height: Icons.swap_vert};

  /// Top bar (close, title, fit, night, read toggle, more) and bottom bar (page counter, slider, display, next book).
  /// A tap anywhere that isn't a control hides them.
  List<Widget> _controls() {
    final completed = _book['readProgress']?['completed'] == true || _index >= _last;
    final shown = _scrub ?? _index.clamp(0, _last);
    final night = _settings.display.night;
    const bar = Color(0xE6101012);
    return [
      Positioned.fill(child: GestureDetector(behavior: HitTestBehavior.opaque, onTap: _hideControls)),
      Positioned(
        left: 0, right: 0, top: 0,
        child: Material(
          color: bar,
          child: Theme(
          data: _controlsTheme(context),
          child: SafeArea(
            bottom: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(10, 12, 8, 12),
              child: Row(children: [
                FilledButton.tonalIcon(
                  focusNode: _ctl[_Ctl.close],
                  style: FilledButton.styleFrom(
                    padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
                    textStyle: const TextStyle(fontSize: 16, fontWeight: FontWeight.w500),
                  ),
                  onPressed: () => Navigator.of(context).pop(),
                  icon: const Icon(Icons.arrow_back, size: 24),
                  label: const Text('Close'),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
                    Text('${_book['seriesTitle'] ?? ''} #${_book['metadata']?['number'] ?? ''}',
                        maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: Colors.white, fontSize: 17)),
                    Text('${_book['metadata']?['title'] ?? ''}',
                        maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: Colors.white60, fontSize: 13)),
                  ]),
                ),
                // one press = next fit mode (screen -> width -> height), label shows which
                _iconCtl(
                  node: _ctl[_Ctl.fit]!,
                  onPressed: () => _setFit(FitMode.values[(_prefs.fit.index + 1) % FitMode.values.length]),
                  icon: _fitIcons[_prefs.fit]!,
                  label: 'Fit ${_prefs.fit.label.toLowerCase()}',
                ),
                IconButton(
                  focusNode: _ctl[_Ctl.night],
                  tooltip: night ? 'Night mode off' : 'Night mode on',
                  icon: Icon(night ? Icons.nightlight : Icons.nightlight_outlined,
                      color: night ? const Color(0xFFFFB74D) : null),
                  onPressed: () => _settings.setDisplay(_settings.display.copyWith(night: !night)),
                ),
                if (isDesktop)
                  _iconCtl(
                    node: _ctl[_Ctl.fullscreen]!,
                    icon: _fullscreen ? Icons.fullscreen_exit : Icons.fullscreen,
                    label: _fullscreen ? 'Leave full screen (F11)' : 'Full screen (F11)',
                    onPressed: _toggleFullscreen,
                  ),
                _iconCtl(
                  node: _ctl[_Ctl.read]!,
                  icon: completed ? Icons.check_circle : Icons.check_circle_outline,
                  label: completed ? 'Mark unread' : 'Mark read',
                  onPressed: () async {
                    try {
                      completed ? await api.markUnread(_book['id']) : await api.markRead(_book['id']);
                      await _afterMark();
                    } catch (e) {
                      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
                    }
                  },
                ),
                IconButton(
                  focusNode: _ctl[_Ctl.delete],
                  tooltip: 'Delete book',
                  icon: const Icon(Icons.delete_outline, color: Color(0xFFFF8A80)),
                  onPressed: _deleteBook,
                ),
              ]),
            ),
          ),
          ),
        ),
      ),
      Positioned(
        left: 0, right: 0, bottom: 0,
        child: Material(
          color: bar,
          child: Theme(
          data: _controlsTheme(context),
          child: SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(8, 8, 8, 8),
              child: Row(children: [
                IconButton(focusNode: _ctl[_Ctl.prevBook], tooltip: 'Previous book', onPressed: _prevBook,
                    icon: const Icon(Icons.skip_previous, size: 28)),
                const SizedBox(width: 4),
                SizedBox(
                  width: 92,
                  child: Text('${shown + 1} / ${_pages.length}',
                      style: TextStyle(color: _scrubbing ? Theme.of(context).colorScheme.primary : Colors.white,
                          fontSize: 15, fontFeatures: const [FontFeature.tabularFigures()])),
                ),
                Expanded(
                  child: _pages.length < 2
                      ? const SizedBox.shrink()
                      // right to left: page 1 at the right end of the slider
                      : Directionality(textDirection: _rtl ? TextDirection.rtl : TextDirection.ltr, child: _slider(shown)),
                ),
                if (_seriesId != null)
                  _iconCtl(node: _ctl[_Ctl.image]!, icon: Icons.settings_brightness, label: 'Image settings',
                      onPressed: () => showImagePanel(context,
                          seriesId: _seriesId!, seriesTitle: _book['seriesTitle'] as String?)),
                _iconCtl(node: _ctl[_Ctl.reader]!, icon: Icons.tune,
                    label: 'Reader settings',
                    onPressed: () => showReaderPanel(context,
                        seriesId: _seriesId, seriesTitle: _book['seriesTitle'] as String?,
                        komgaDirection: _komgaDirection)),
                IconButton(focusNode: _ctl[_Ctl.nextBook], tooltip: 'Next book', onPressed: _nextBook,
                    icon: const Icon(Icons.skip_next, size: 28)),
              ]),
            ),
          ),
          ),
        ),
      ),
    ];
  }

  /// The control the remote is on gets a thick accent outline and a strong accent fill, so it can be seen from the
  /// sofa. Touch never focuses these buttons, so this only ever shows while using the remote.
  ThemeData _controlsTheme(BuildContext context) {
    final t = Theme.of(context);
    final style = strongFocusStyle(t.colorScheme.primary); // same as the rest of the app (main.dart)
    return t.copyWith(
      iconButtonTheme: IconButtonThemeData(style: style),
      textButtonTheme: TextButtonThemeData(style: style),
      filledButtonTheme: FilledButtonThemeData(style: style),
    );
  }


  Widget _slider(int shown) {
    final node = _ctl[_Ctl.slider]!;
    final accent = Theme.of(context).colorScheme.primary;
    return Focus(
      focusNode: node,
      onKeyEvent: _onSliderKey,
      onFocusChange: (_) => setState(() { if (!node.hasFocus) { _scrubbing = false; _scrub = null; } }),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 120),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(20),
          color: node.hasFocus ? accent.withValues(alpha: _scrubbing ? 0.5 : 0.3) : Colors.transparent,
          border: Border.all(color: node.hasFocus ? accent : Colors.transparent, width: 3),
        ),
        child: SliderTheme(
          data: SliderTheme.of(context).copyWith(
            trackHeight: 4,
            inactiveTrackColor: Colors.white24,
            showValueIndicator: ShowValueIndicator.onDrag,
          ),
          child: Slider(
            focusNode: _sliderInner,
            min: 0,
            max: _last.toDouble(),
            divisions: _last,
            value: shown.toDouble(),
            label: 'Page ${shown + 1}',
            onChanged: (v) => setState(() => _scrub = v.round()),
            onChangeEnd: (v) {
              _finishCurlNow();
              _pc?.jumpToPage(v.round());
              setState(() => _scrub = null);
            },
          ),
        ),
      ),
    );
  }
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
