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
import '../offline/connection.dart';
import '../offline/downloads.dart';
import '../offline/offline_komga.dart' show NotAvailableOffline;
import '../page_curl.dart';
import '../page_image.dart';
import '../reader_keys.dart';
import '../screen.dart';
import '../settings.dart';
import '../widgets/display_panel.dart';
import '../widgets/error_text.dart';
import '../widgets/focus_style.dart';
import '../widgets/native_poster.dart';
import '../widgets/reader_clock.dart';
import 'actions.dart';

/// Page reader: full screen on the chosen background (black, dark grey or white), follows the tablet's rotation
/// (tilt for spreads).
///
/// Remote: Right/Down = forward, Left/Up = back (in fit width/height that first scrolls through the page).
/// OK = show/hide the controls, like a tap in the middle. With the controls up, the arrows step through them one at a
/// time (after the last comes "nothing selected", where OK hides them again); OK on a control = tapping it; OK on the
/// page slider starts scrubbing (arrows change the page, OK jumps there). Picking a page on the slider shows a
/// preview of it over the thumb.
///
/// Touch: tap the left/right third to go back/forward, the middle for the controls; any tap off the controls hides
/// them. Pinch or double-tap to zoom in fit-screen mode. Android: the volume keys turn pages (a setting). Progress
/// goes straight to Komga (no local copy).
class ReaderScreen extends StatefulWidget {
  const ReaderScreen({super.key, required this.api, required this.book, this.readListId, this.skipRead = false});
  final Komga api;
  final dynamic book;
  final String? readListId; // continue within this read list at the end of the book

  /// Opened from a series or read list with Hide read on: the next book is the next one not read yet (user,
  /// 2026-09-30) - for the whole visit, books moved on to included. Elsewhere it's simply the next in order.
  final bool skipRead;
  @override
  State<ReaderScreen> createState() => _ReaderScreenState();
}

enum _Ctl { close, fit, night, fullscreen, read, delete, prevBook, slider, pages, image, reader, nextBook, strip }

class _ReaderScreenState extends State<ReaderScreen> with SingleTickerProviderStateMixin {
  late dynamic _book = widget.book;
  List<dynamic> _pages = [];
  PageLoader? _loader;
  PageController? _pc;
  int _index = 0;
  bool _menu = false; // controls shown
  int? _scrub; // page picked on the slider but not jumped to yet
  bool _scrubbing = false; // remote is driving the slider
  // Where the reader was before the slider took them elsewhere - marked on the slider while scrubbing, and a drag near
  // it snaps to it, so after a look at another page they can get back (user, 2026-10-02). Kept over slider jumps
  // only: an ordinary page turn means reading on from here, so it's forgotten (else reading on from a page looked at
  // kept the old place for good - user, 2026-10-02); also once that page is reached again, or another book opens.
  int? _returnTo;
  int? _jumpingTo; // the page a slider jump is going to: its page change isn't a page turn
  int get _scrubOrigin => _returnTo ?? _index.clamp(0, _last);
  int? _startAtEnd; // page to show from its bottom/right end (came back from the next page)
  bool _loading = true;
  bool _turned = false; // progress is only saved once a page has been turned in this visit
  int _openedAt = 0;
  bool _zoomed = false; // pinch-zoomed in: page swiping is paused so a drag pans the page
  final Set<int> _sideways = {}; // pages (fit height, wider than the screen) that a drag moves sideways
  /// A page says whether a drag moves it sideways. It also says "no longer" from its dispose - while the framework is
  /// unmounting it at the end of a frame, when setState isn't allowed - so the rebuild then waits for the frame to end
  /// (missing-tests audit, 2026-09-30: debug builds asserted "widget tree was locked" two turns past a wide page).
  void _setSideways(int i, bool pans) {
    if (!(pans ? _sideways.add(i) : _sideways.remove(i))) return;
    if (SchedulerBinding.instance.schedulerPhase == SchedulerPhase.persistentCallbacks) {
      WidgetsBinding.instance.addPostFrameCallback((_) { if (mounted) setState(() {}); });
    } else {
      setState(() {});
    }
  }
  bool get _fullscreen => fullscreen.value; // desktop, whole app: F11 / the full-screen button (lib/screen.dart)
  double _wheelAcc = 0; // mouse wheel travel towards the next page turn
  DateTime _lastWheelTurn = DateTime(0);
  int _fingers = 0; // two or more on the page = a pinch: page swiping pauses at once so it can't steal the gesture
  Timer? _saveTimer;
  Timer? _flashTimer;
  bool _flash = false; // the page number shows for a moment after a turn (setting: Show the page number after a turn)
  final Map<int, ScrollController> _scrolls = {};
  final Map<int, bool Function(bool forward)> _steppers = {}; // zoomed-in pan steps, per page (page_image.dart)
  final Map<int, void Function(Offset global)> _zoomers = {}; // double-tap zoom, per page (page_image.dart)
  final Map<int, void Function(bool zoomIn)> _zoomSteps = {}; // zoom keys, per page (page_image.dart)
  final FocusNode _keys = FocusNode(debugLabel: 'reader-keys', skipTraversal: true);
  final FocusNode _sliderInner = FocusNode(canRequestFocus: false, skipTraversal: true); // the wrapper takes focus
  final Map<_Ctl, FocusNode> _ctl = {for (final c in _Ctl.values) c: FocusNode(debugLabel: 'ctl-${c.name}')};

  Komga get api => widget.api;
  int get _last => _pages.length - 1;
  AppSettings get _settings => AppSettings.instance;
  String? get _seriesId => _book['seriesId'] as String?;
  // the series' settings as they apply - with the fit for this book only (the top bar's fit button while the series
  // follows the default layout) on top
  ReaderPrefs get _prefs {
    final p = _settings.prefsFor(_seriesId);
    final f = _bookFit;
    return f == null || p.ownLayout ? p : p.copyWith(fit: f);
  }

  FitMode? _bookFit; // this book only, for now: not saved; a book opening goes back to the default (user, 2026-09-30)
  Color get _bg => _prefs.background.colour; // the series' own, or the reading defaults'
  Color _ink(double alpha) => _prefs.background.ink.withValues(alpha: alpha); // text on it

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
    Downloads.instance.readerOpened(); // Delete once read waits for it too
    AppSettings.instance.readerOpened(); // the screen brightness setting is the reader's
    // back in the app (unlocked, switched back to): read further elsewhere meanwhile?
    _life = AppLifecycleListener(onResume: () => unawaited(_checkElsewhere()));
    // Rotation as set (the app otherwise follows the sensor, via the manifest), hide the system bars, keep the screen on.
    _applyRotation();
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    _awake();
    _settings.addListener(_onSettings);
    fullscreen.addListener(_onFullscreen); // F11 is app-wide (main.dart): the button follows
    PageCurl.program().ignore(); // load the curl shader ahead of the first turn
    _curlAnim
      ..addListener(_onCurlTick)
      ..addStatusListener((s) { if (s == AnimationStatus.completed) _endCurl(); });
    _visited.add(Map<String, dynamic>.from(_book as Map)); // the visit starts here
    _open(_book);
  }

  @override
  void dispose() {
    _saveTimer?.cancel();
    _flashTimer?.cancel();
    _tapTimer?.cancel();
    _awakeTimer?.cancel();
    _curlAnim.dispose();
    _curl?.dispose();
    _idle?.complete(); // nothing left waiting
    Connection.instance.readerClosed();
    AppSettings.instance.readerClosed(); // the screen follows the system again
    _life?.dispose();
    // before Downloads hears the book closed: a book finished here is marked read first. No question while closing:
    // if another device moved the book on meanwhile, nothing is saved over it
    _saveNow(ask: false);
    Downloads.instance.readerClosed();
    _settings.removeListener(_onSettings);
    fullscreen.removeListener(_onFullscreen);
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    if (_rotation != Rotation.auto) SystemChrome.setPreferredOrientations(const []); // a lock ends with the book
    if (_screenHeld) keepScreenOn(false);
    _pc?.dispose();
    _disposeScrolls();
    _keys.dispose();
    _sliderInner.dispose();
    _stripScroll.dispose();
    for (final n in _ctl.values) {
      n.dispose();
    }
    super.dispose();
  }

  // ---- Rotation (Settings > Reader, and the Reader panel): follow the device, or hold portrait / landscape
  Rotation? _rotation;

  void _applyRotation() {
    final r = _settings.display.rotation;
    if (r == _rotation) return;
    _rotation = r;
    SystemChrome.setPreferredOrientations(switch (r) {
      Rotation.auto => DeviceOrientation.values,
      Rotation.portrait => const [DeviceOrientation.portraitUp, DeviceOrientation.portraitDown],
      Rotation.landscape => const [DeviceOrientation.landscapeLeft, DeviceOrientation.landscapeRight],
    });
  }

  void _onSettings() {
    if (!mounted) return;
    _applyRotation();
    if (_settings.display.screenOn != _screenOnFor) _awake(); // Keep the screen on changed
    setState(() {});
  }

  // ---- Keep the screen on (Settings > Reader): always while a book is open, for N minutes after the last page turn
  // or touch, or never (the system's own timeout)
  Timer? _awakeTimer;
  bool _screenHeld = false;
  int? _screenOnFor;

  void _awake() {
    final minutes = _screenOnFor = _settings.display.screenOn;
    _awakeTimer?.cancel();
    final hold = minutes != 0;
    if (hold != _screenHeld) {
      _screenHeld = hold;
      keepScreenOn(hold);
    }
    if (minutes > 0) {
      _awakeTimer = Timer(Duration(minutes: minutes), () {
        _screenHeld = false;
        keepScreenOn(false); // the system's timeout takes over; the next turn or touch holds it again
      });
    }
  }

  void _disposeScrolls() {
    for (final c in _scrolls.values) {
      c.dispose();
    }
    _scrolls.clear();
  }

  ScrollController _scrollFor(int i) => _scrolls.putIfAbsent(i, ScrollController.new);

  (String, Object, StackTrace)? _openError; // the book couldn't be opened, and there's none on screen

  static String _titleOf(dynamic b) => '${b['seriesTitle'] ?? ''} #${b['metadata']?['number'] ?? ''}'.trim();

  int _openRun = 0; // each _open's number: an older one still loading doesn't take over

  /// Opens [book]. The book being read stays the current one - its pages (under the loading cover), where progress is
  /// saved, the title - until the new one has loaded; a load that fails leaves it exactly as it was (code review,
  /// 2026-09-30: closing mid-load saved the old book's page to the new one). [onOpened] runs once it has loaded.
  Future<void> _open(dynamic book, {VoidCallback? onOpened}) async {
    final run = ++_openRun;
    setState(() { _loading = true; _menu = false; _openError = null; });
    try {
      final fresh = await api.book(book['id']) ?? book; // current progress from the server
      final pages = await api.pages(book['id']);
      if (pages.isEmpty) throw _NoPages();
      final seriesId = fresh['seriesId'] as String?;
      String? direction = _komgaDirection;
      if (seriesId != null && seriesId != _directionSeries) {
        try {
          direction = (await api.oneSeries(seriesId))?['metadata']?['readingDirection'] as String?;
        } catch (_) {
          direction = null; // unknown: left to right
        }
      }
      if (!mounted || run != _openRun) return; // closed, or another book asked for since
      _komgaDirection = direction;
      _directionSeries = seriesId;
      final rp = fresh['readProgress'];
      final start = rp == null || rp['completed'] == true ? 0 : ((rp['page'] as int) - 1).clamp(0, pages.length - 1);
      // the last book's page view is still up (under the cover): its controllers go once the new one has replaced it
      final oldPc = _pc, oldScrolls = List.of(_scrolls.values);
      _scrolls.clear();
      _clearThumbs();
      final loader = PageLoader(api, fresh['id'] as String,
          [for (var i = 0; i < pages.length; i++) (pages[i]['number'] ?? i + 1) as int]);
      loader.around(start);
      setState(() {
        _book = fresh; _pages = pages; _index = start; _loader = loader; _returnTo = null;
        _openedAt = start; _turned = false; _zoomed = false; _bookFit = null;
        _known[fresh['id'] as String] = _progressOf(fresh); // as Komga has it now: a change elsewhere is from here on
        _pc = PageController(initialPage: start, keepPage: false); // (a kept page would be the last book's)
        _loading = false;
      });
      WidgetsBinding.instance.addPostFrameCallback((_) {
        oldPc?.dispose();
        for (final c in oldScrolls) {
          c.dispose();
        }
      });
      onOpened?.call();
      _keys.requestFocus();
    } catch (e, st) {
      if (!mounted || run != _openRun) return;
      final empty = e is _NoPages;
      final message = empty
          ? '"${_titleOf(book)}" has no pages (Komga may need to analyse it again).'
          : couldnt('open "${_titleOf(book)}"', e, thing: 'book');
      if (_pc == null) {
        // nothing to show: say so on the screen (a book with no pages: Close, or on to the next book)
        setState(() { _loading = false; _openError = (message, e, st); });
      } else {
        setState(() => _loading = false); // the book being read stays
        if (empty) {
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message),
              action: SnackBarAction(label: 'Next book', onPressed: () => _skipPast(book))));
        } else {
          showErrorSnack(context, message, e, st);
        }
      }
    }
  }

  /// On past a book that can't be read (no pages): the one after it.
  Future<void> _skipPast(dynamic book) async {
    if (_busy) return;
    _switching = true;
    try {
      final next = await _nextFrom(book['id'] as String);
      if (!mounted) return;
      if (next == null) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(_endText)));
        Navigator.of(context).pop();
      } else {
        await _goTo(next, forward: true);
      }
    } catch (e, st) {
      if (mounted) showErrorSnack(context, couldnt('find the next book', e, thing: 'book'), e, st);
    } finally {
      _switching = false;
    }
  }

  /// Moving to another book (Next / Previous book at work, or it's loading): page turns and book moves wait - a second
  /// "next" meanwhile opened the book after, marking the one in between read (code review, 2026-09-30).
  bool _switching = false;
  bool get _busy => _loading || _switching;

  // ---- progress: saved 1.5 s after the page settles, and on leaving
  void _onPage(int i) {
    _awake();
    final jump = i == _jumpingTo;
    _jumpingTo = null;
    setState(() {
      _index = i;
      _zoomed = false;
      if (!jump || i == _returnTo) _returnTo = null; // read on from here, or back where it was
    });
    if (i <= _last) _loader?.around(i);
    if (i >= _last - 1) _upNext().ignore(); // look up what's next before the end card shows (errors: shown there)
    // a curl moves the page view underneath as it starts: that counts once the curl completes (_endCurl) - one let go
    // before halfway leaves no trace (code review, 2026-09-30: it un-read a finished book)
    if (_curl == null) _pageTurned(i);
  }

  /// A page turn that stands: progress is saved once the page settles - at once on the last page, where the book
  /// counts as read (user, 2026-09-30) - and the page number flashes.
  void _pageTurned(int i) {
    if (i != _openedAt) _turned = true;
    _saveTimer?.cancel();
    if (_turned && i == _last) {
      _saveNow();
    } else {
      _saveTimer = Timer(const Duration(milliseconds: 1500), _saveNow);
    }
    if (i <= _last && _settings.display.pageNumber) {
      _flashTimer?.cancel();
      setState(() => _flash = true);
      _flashTimer = Timer(const Duration(milliseconds: 1200), () { if (mounted) setState(() => _flash = false); });
    }
  }

  /// Opening a book and closing it without turning a page leaves no trace. Turning pages in a finished book starts
  /// it over (Komga's own behaviour). [ask]: false while closing (no question then): if another device has moved the
  /// book on meanwhile, nothing is saved over it.
  void _saveNow({bool ask = true}) {
    if (!_turned || _pages.isEmpty) return;
    // the end card counts as the last page: finished (closing from it used to save nothing if the last page's
    // save hadn't happened yet - the 1.5 s settle timer is cancelled by the turn onto the card)
    final page = math.min(_index, _last);
    final id = _book['id'] as String;
    // one at a time, in order; one queued before the reader went to another device's page is dropped (it waited for
    // the question's answer, then saved this reader's page over theirs - #5)
    final wentElsewhere = _wentElsewhere;
    _saves = _saves.then((_) => wentElsewhere == _wentElsewhere ? _save(id, page + 1, page >= _last, ask: ask) : null);
  }

  // ---- progress moved on another device while this book was open (user, 2026-10-05: read on the PC, then the
  // tablet - left open on that book - saved its old page over it). Before a save, and on coming back to the app, the
  // reader asks Komga again; if Komga's progress isn't what this reader last loaded, saved or accepted, another device
  // changed it, and it asks: finished there -> Stay here / Mark as read; another page -> Stay / Go to that page.
  // Content is compared, not times: Komga doesn't hand back the time of the reader's own saves.

  // per book (a book left for the next one is saved after that one has opened): (page from 1, or null: not started;
  // finished)
  final Map<String, (int?, bool)> _known = {};
  Future<void> _saves = Future.value();
  Future<bool>? _question; // the question on screen: a second asker waits for its answer
  int _wentElsewhere = 0; // times the reader went with another device's progress (saves queued before: dropped)
  AppLifecycleListener? _life;

  static (int?, bool) _progressOf(dynamic book) {
    final rp = book?['readProgress'];
    return rp == null ? (null, false) : ((rp['page'] as num?)?.toInt(), rp['completed'] == true);
  }

  /// Komga's progress for [id] if it's not what this reader knows (another device moved it); null if it is, or if
  /// Komga can't say (offline, unreachable - the save goes ahead as before).
  Future<(int?, bool)?> _movedElsewhere(String id) async {
    if (Connection.instance.offline) return null;
    try {
      final now = _progressOf(await api.book(id));
      final known = _known[id];
      return known == null || now == known ? null : now;
    } catch (_) {
      return null;
    }
  }

  Future<void> _save(String id, int page, bool completed, {required bool ask}) async {
    final moved = await _movedElsewhere(id);
    if (moved != null) {
      if (!ask || !mounted || _book['id'] != id) return; // closing, or another book by now: theirs stands
      if (!await _askAboutElsewhere(moved)) return; // gone with theirs: nothing of this one's to save
    }
    // known as this reader's page once Komga has it: noted before, a save that failed (a network blip) left Komga on
    // the earlier page, and the next save asked about this reader's own page as if another device had moved it
    // (code review 2026-10-05, #4). A failed save stays silent: the next one carries the newer page.
    try {
      await api.setProgress(id, page, completed: completed);
      _known[id] = (page, completed);
    } catch (_) {}
  }

  /// Back in the app with the book open: has it moved on elsewhere meanwhile?
  /// In line with the saves: a save on its way when the app came back was taken for another device's (#4).
  Future<void> _checkElsewhere() {
    _saves = _saves.then((_) async {
      if (!mounted || _loading || _pages.isEmpty || _question != null) return;
      final moved = await _movedElsewhere(_book['id'] as String);
      if (moved != null && mounted) await _askAboutElsewhere(moved);
    });
    return _saves;
  }

  /// The question. True: stay here (this reader's progress is saved next); false: went with the other device's.
  /// Asked once at a time: a second asker (a save coming due while it's on screen) waits for the answer - Stay: it
  /// saves; the other device's: it doesn't (it used to be told "stay" at once and save over the other device's page
  /// with the question still up - code review 2026-10-05, #5).
  Future<bool> _askAboutElsewhere((int?, bool) moved) =>
      _question ??= _ask(moved).whenComplete(() => _question = null);

  Future<bool> _ask((int?, bool) moved) async {
    final (page, finished) = moved;
    final here = math.min(_index, _last) + 1;
    final goTo = finished ? null : (page ?? 1).clamp(1, _pages.length);
    final stay = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text(finished ? 'Finished on another device' : 'Read further on another device'),
        content: Text(finished
            ? 'This book was read to the end on another device.'
            : page == null
                ? 'This book was marked unread on another device.'
                : 'On another device this book is on page $page.'),
        actions: [
          TextButton(autofocus: true, onPressed: () => Navigator.pop(c, true),
              child: Text(finished ? 'Stay here' : 'Stay on page $here')),
          TextButton(onPressed: () => Navigator.pop(c, false),
              child: Text(finished ? 'Mark as read' : 'Go to page $goTo')),
        ],
      ),
    );
    _known[_book['id'] as String] = moved; // answered: asked again only if it moves again
    if (stay != false || !mounted) return true; // Stay (or dismissed: Back = stay) - this reader's page goes next
    _saveTimer?.cancel();
    setState(() => _book = {..._book, 'readProgress': finished
        ? {'page': _pages.length, 'completed': true}
        : page == null ? null : {'page': page, 'completed': false}});
    _wentElsewhere++;
    _turned = false; // the other device's progress stands: the jump there isn't a turn of this reader's
    _finishCurlNow();
    final target = finished ? _pages.length : goTo! - 1; // finished: the end card, with the next book
    _openedAt = target;
    _pc?.jumpToPage(target);
    return false;
  }

  // ---- navigation (the page after the last is the "end of book" card)
  static const _turn = Duration(milliseconds: 180);

  /// Forward: in fit width/height scroll on through the page first, then turn.
  void _forward() {
    if (_pc == null || _busy || _curlSettling) return;
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
    if (_pc == null || _busy || _curlSettling) return;
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
    if (_busy || _curlSettling) return;
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

  // ---- taps: the side you read towards goes forward, the other back, the middle shows the controls ----------------
  // With Double-tap to zoom on (fit screen, a page showing), a tap waits [_doubleTapWait] to see whether a second
  // one follows near it: a double tap zooms in on that spot (again: back out), and no single tap happens.
  static const _doubleTapWait = Duration(milliseconds: 250);
  static const _doubleTapSlop = 60.0; // how far apart the two taps may be
  Timer? _tapTimer;
  Offset? _firstTap; // waiting for a possible second tap

  void _onTapUp(TapUpDetails d, double width) {
    final zoomer = _settings.display.doubleTapZoom && _prefs.fit == FitMode.screen ? _zoomers[_index] : null;
    final waiting = _firstTap;
    final pending = waiting != null && (_tapTimer?.isActive ?? false);
    _tapTimer?.cancel();
    _firstTap = null;
    if (pending && (d.localPosition - waiting).distance > _doubleTapSlop) _tap(waiting.dx / width); // not a pair
    if (zoomer == null) {
      _tap(d.localPosition.dx / width);
    } else if (pending && (d.localPosition - waiting).distance <= _doubleTapSlop) {
      zoomer(d.globalPosition);
    } else {
      _firstTap = d.localPosition;
      _tapTimer = Timer(_doubleTapWait, () {
        _firstTap = null;
        if (mounted && !_menu) _tap(d.localPosition.dx / width);
      });
    }
  }

  /// A single tap at [x] (0..1 across the screen). Tap zones follow the reading direction.
  void _tap(double x) {
    if (x < 0.33) {
      _rtl ? _forward() : _back();
    } else if (x > 0.67) {
      _rtl ? _back() : _forward();
    } else {
      _showControls();
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

  /// A curl is playing out after the finger let go (turning, or springing back): taps and keys wait for it (user,
  /// 2026-09-30) - one during a spring-back skipped a page, from the last page it even opened the next book.
  bool get _curlSettling => _curl != null && _curlAnim.isAnimating;

  /// The turn is over: let go before halfway -> back to where it started, and nothing counted; else the turn counts.
  void _endCurl({bool cancel = false}) {
    final c = _curl;
    if (c == null) return;
    final back = cancel || !c.completing;
    if (back) _pc?.jumpToPage(c.from); // while _curl is still set: not counted as a turn (_onPage)
    _curl = null;
    if (!back) _pageTurned(_index);
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

  /// Next book. On the last page or the end card the current book is marked read; before that, it depends on "Next
  /// book before the last page" (Settings > Reader): ask, mark read, or keep it in progress.
  Future<void> _nextBook() async {
    if (_busy) return; // already on the way to another book
    _switching = true;
    try {
      await _toNextBook();
    } finally {
      _switching = false;
    }
  }

  Future<void> _toNextBook() async {
    final finished = _index >= _last;
    final midBook = _settings.display.midBook;
    var markRead = finished || midBook == MidBook.markRead;
    if (!finished && midBook == MidBook.ask) {
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
        _known[_book['id'] as String] = (_pages.length, true); // this reader's own: not a change from elsewhere
      } else {
        _saveNow();
      }
      // settled: nothing more to save for this book on leaving - closing used to save the page over "read" (review)
      _turned = false;
      final next = await _nextFrom(_book['id'] as String);
      if (!mounted) return;
      if (next == null) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(_endText)));
        Navigator.of(context).pop();
      } else {
        await _goTo(next, forward: true);
      }
    } on NotAvailableOffline {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("The next book isn't downloaded")));
      Navigator.of(context).pop();
    } catch (e, st) {
      if (mounted) showErrorSnack(context, couldnt('find the next book', e, thing: 'book'), e, st);
    }
  }

  /// Previous book: the one read before this in this visit (read or not now); from the book the visit started with,
  /// the one before it in the read list it was opened from, else the series - opened from a view with read books
  /// hidden, the previous one not read yet (user, 2026-09-30). Nothing is marked; this book's place is kept if a
  /// page was turned.
  Future<void> _prevBook() async {
    if (_busy) return; // already on the way to another book
    _switching = true;
    try {
      await _toPrevBook();
    } finally {
      _switching = false;
    }
  }

  Future<void> _toPrevBook() async {
    _saveTimer?.cancel();
    _saveNow();
    if (_at > 0) {
      await _goTo(_visited[_at - 1], forward: false);
      return;
    }
    try {
      var prev = await api.previousBook(_book['id'], readListId: widget.readListId);
      for (var hops = 0; widget.skipRead && prev != null && _isRead(prev) && hops < 500; hops++) {
        prev = await api.previousBook(prev['id'] as String, readListId: widget.readListId);
      }
      if (!mounted) return;
      if (prev == null) {
        final where = widget.readListId != null ? 'read list' : 'series';
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(widget.skipRead
            ? 'No unread books before this one in the $where'
            : 'This is the first book of the $where')));
      } else {
        await _goTo(prev, forward: false);
      }
    } catch (e, st) {
      if (mounted) showErrorSnack(context, couldnt('find the previous book', e, thing: 'book'), e, st);
    }
  }

  /// Delete the open book's file on the server (confirmed first, Cancel focused), then close the reader.
  // ---- Save page / Copy page (the Reader panel; user, 2026-10-02): the page's own image as Komga sends it - not
  // the picture on screen (no crop, levels or Enhance) - from what's loaded already, else asked for

  /// The page being read: (its picture file, a name for it). Null on the end card.
  Future<(Uint8List, String)?> _pageFile() async {
    final i = _index;
    if (i > _last || _loader == null) return null;
    final bytes = _loader!.loadedBytes(i) ?? await api.pageBytes(_book['id'] as String, _loader!.pageNumbers[i]);
    return (bytes, '${_titleOf(_book)} - page ${i + 1}');
  }

  Future<void> _savePage() async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      final f = await _pageFile();
      if (f == null) return;
      final where = await savePicture(f.$1, f.$2);
      messenger // a message for each save, the last one shown at once (not queued behind the one before)
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text('Page saved: $where')));
    } catch (e, st) {
      if (mounted) showErrorSnack(context, couldnt('save the page', e), e, st);
    }
  }

  Future<void> _copyPage() async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      final f = await _pageFile();
      if (f == null) return;
      await copyPicture(f.$1, f.$2);
      messenger
        ..hideCurrentSnackBar()
        ..showSnackBar(const SnackBar(content: Text('Page copied')));
    } catch (e, st) {
      if (mounted) showErrorSnack(context, couldnt('copy the page', e), e, st);
    }
  }

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
    } catch (e, st) {
      if (mounted) {
        showErrorSnack(context, couldnt('delete "$title"', e, thing: 'book', forbidden: deleteNeedsAdmin), e, st);
      }
    }
  }

  /// After an explicit mark read/unread, don't let the automatic save undo it.
  Future<void> _afterMark() async {
    _saveTimer?.cancel();
    _turned = false;
    _openedAt = _index;
    final id = _book['id'];
    final fresh = await api.book(id).catchError((_) => null);
    if (fresh != null) _known[id as String] = _progressOf(fresh); // this reader's own mark: not another device's
    // only if that book is still the one open (a quick Next book meanwhile: the answer is for the book left behind)
    if (mounted && fresh != null && _book['id'] == id && !_busy) setState(() => _book = fresh);
  }

  // ---- controls
  void _showControls() {
    setState(() { _menu = true; _scrubbing = false; _scrub = null; });
    if (_stripShown) _stripCentre(_index.clamp(0, _last), jump: true); // on the page being read now
  }

  void _hideControls() {
    // a finger still on the slider is let go of: hidden by Esc / Back mid-scrub, the scrub is cancelled - its lift
    // still reaches the slider's listener (Flutter sends a pointer's events where it went down) and jumped to the page
    // picked (user, 2026-10-02)
    _sliderPointer = null;
    setState(() { _menu = false; _scrub = null; _scrubbing = false; });
    _keys.requestFocus();
  }

  /// The two bars, left to right, as the remote walks them.
  List<_Ctl> get _topBar => [_Ctl.close, _Ctl.fit, _Ctl.night, if (isDesktop) _Ctl.fullscreen, _Ctl.read, _Ctl.delete];
  List<_Ctl> get _bottomBar => [
        _Ctl.prevBook,
        if (_pages.length > 1) ...[_Ctl.slider, _Ctl.pages],
        if (_seriesId != null) _Ctl.image,
        _Ctl.reader, _Ctl.nextBook,
      ];
  bool get _stripShown => _stripOpen && _pages.length > 1;

  /// Remote in the controls (user's layout): Left/Right move along a bar and stop at its ends; Up/Down switch between
  /// the top and bottom bar (keeping the position as near as possible). Up from the top bar or Down from the bottom
  /// bar leaves the bars ("nothing selected", where OK hides the controls). From nothing selected: Up or Left/Right
  /// -> top bar, Down -> bottom bar.
  /// With the page strip open it's a row of its own, just above the bottom bar: Up from the bottom bar goes into it,
  /// Down from it to the bottom bar, Up from it to the top bar (Left / Right in it are the strip's own, _onStripKey).
  void _move({int dx = 0, int dy = 0}) {
    final top = _topBar, bottom = _bottomBar;
    final inTop = top.indexWhere((c) => _ctl[c]!.hasFocus);
    final inBottom = bottom.indexWhere((c) => _ctl[c]!.hasFocus);
    _Ctl? target;
    if (_ctl[_Ctl.strip]!.hasFocus) {
      if (dy == 0) return;
      target = dy < 0 ? top.first : bottom[bottom.indexOf(_Ctl.pages).clamp(0, bottom.length - 1)];
    } else if (inBottom >= 0 && dy < 0 && dx == 0 && _stripShown) {
      _stripFocus(); // up from the bottom bar: into the strip, on the page shown
      return;
    } else if (inTop < 0 && inBottom < 0) {
      target = dy > 0 ? bottom.first : top.first;
    } else {
      final bar = inTop >= 0 ? top : bottom, i = inTop >= 0 ? inTop : inBottom;
      if (dx != 0) {
        target = bar[(i + dx).clamp(0, bar.length - 1)];
      } else if (inTop >= 0) {
        if (dy > 0 && _stripShown) { _stripFocus(); return; } // down from the top bar: the strip comes first
        target = dy > 0 ? bottom[i.clamp(0, bottom.length - 1)] : null;
      } else {
        target = dy < 0 ? top[i.clamp(0, top.length - 1)] : null;
      }
    }
    target == null ? _keys.requestFocus() : _ctl[target]!.requestFocus();
    setState(() {});
  }

  // Fixed keys for moving around the controls and scrubbing the slider (not remappable, so a mapping can't strand the
  // remote); with the controls hidden, keys go through ReaderKeys.
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
    _awake();
    final k = e.logicalKey;
    if (!_menu) {
      // Volume keys (Android, a setting): down = forward, up = back, in any reading direction. Handled keys don't
      // reach the system, so the volume stays put; a held key turns one page (its repeats are swallowed).
      if ((k == LogicalKeyboardKey.audioVolumeDown || k == LogicalKeyboardKey.audioVolumeUp) &&
          hasVolumeKeys && _settings.display.volumeKeys) {
        if (e is KeyDownEvent) k == LogicalKeyboardKey.audioVolumeDown ? _forward() : _back();
        return KeyEventResult.handled;
      }
      // Shift+Space goes back, whatever Space is set to do
      if (k == LogicalKeyboardKey.space && HardwareKeyboard.instance.isShiftPressed) { _back(); return KeyEventResult.handled; }
      // the rest as set in Settings > Remote and keys (reader_keys.dart); Left and Right swap for right to left
      switch (ReaderKeys.instance.actionFor(k, rtl: _rtl)) {
        case ReaderAction.next:
          // on the end card, moving on to the next book takes a fresh press: a held key's repeats don't
          if (e is KeyDownEvent || _index < _pages.length) _forward();
        case ReaderAction.previous:
          _back();
        case ReaderAction.controls:
          if (e is KeyDownEvent) _showControls();
        case ReaderAction.close: // closes the book (full screen stays)
          if (e is KeyDownEvent) Navigator.of(context).maybePop();
        case ReaderAction.zoomIn: // a step in or out - fit screen, the only fit that zooms
          if (_prefs.fit == FitMode.screen) _zoomSteps[_index]?.call(true);
        case ReaderAction.zoomOut:
          if (_prefs.fit == FitMode.screen) _zoomSteps[_index]?.call(false);
        case null:
          return KeyEventResult.ignored;
      }
      return KeyEventResult.handled;
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
        _sliderJump(target);
      } else {
        _thumbShown = null; // not the last scrub's page
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

  /// The top bar's fit button: the series' own fit when it overrides the default layout (saved, synced); otherwise
  /// this book only, for now (the Reader panel's toggle turns the override on). A book with no series: the default.
  void _setFit(FitMode f) {
    final id = _seriesId;
    if (id == null) {
      _settings.setDefault(_settings.defaults.copyWith(fit: f));
    } else if (_settings.ownsLayout(id)) {
      _settings.setSeriesLayout(id, _prefs.copyWith(fit: f));
    } else {
      setState(() => _bookFit = f);
    }
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      // Back (tablet or remote) closes the controls first, then the book
      canPop: !_menu,
      onPopInvokedWithResult: (didPop, _) { if (!didPop) _hideControls(); },
      child: Scaffold(
        backgroundColor: _bg,
        body: Focus(
          focusNode: _keys,
          autofocus: true,
          onKeyEvent: _onKey,
          child: _openError != null && _pc == null
              ? Center(child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 32),
                  child: ErrorText(_openError!.$1, _openError!.$2, stack: _openError!.$3, centre: true,
                      style: TextStyle(color: _ink(0.7)),
                      action: Row(mainAxisSize: MainAxisSize.min, children: [
                        // a book with no pages: retrying won't help - on to the next book instead
                        if (_openError!.$2 is _NoPages)
                          TextButton(autofocus: true, onPressed: () => _skipPast(_book), child: const Text('Next book'))
                        else
                          TextButton(autofocus: true, onPressed: () => _open(_book), child: const Text('Retry')),
                        TextButton(onPressed: () => Navigator.of(context).maybePop(), child: const Text('Close')),
                      ])),
                ))
              : _pc == null
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
                      onPointerDown: (_) {
                        _awake();
                        _setFingers(_fingers + 1);
                      },
                      onPointerUp: (_) => _setFingers(_fingers - 1),
                      onPointerCancel: (_) => _setFingers(_fingers - 1),
                      child: GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onSecondaryTap: () => _menu ? _hideControls() : _showControls(), // right-click
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
                  // "12 / 36" for a moment after a turn, bottom left (user, 2026-09-30) - not over the controls (they
                  // have the count) or the end card
                  Positioned(
                    left: 14,
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
                  // Clock and battery, Always: top right while the controls are hidden (with them up it's on the top bar)
                  if (!_menu && _settings.display.clock == ShowWhen.always)
                    Positioned(
                      top: 8,
                      right: 10,
                      child: IgnorePointer(
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                          decoration: BoxDecoration(color: Colors.black.withValues(alpha: 0.55),
                              borderRadius: BorderRadius.circular(10)),
                          child: const ReaderClock(fontSize: 12),
                        ),
                      ),
                    ),
                  // Progress bar: a thin line along the bottom while the controls are hidden (their slider shows it)
                  if (!_menu && _settings.display.progressBar && _pages.isNotEmpty && _index <= _last)
                    Positioned(
                      left: 0,
                      right: 0,
                      bottom: 0,
                      height: 3,
                      child: IgnorePointer(
                        child: Directionality(
                          textDirection: _rtl ? TextDirection.rtl : TextDirection.ltr, // fills from the reading side
                          child: LinearProgressIndicator(
                            key: const ValueKey('reading-progress'),
                            value: (_index + 1) / _pages.length,
                            minHeight: 3,
                            backgroundColor: _ink(0.12),
                            color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.85),
                          ),
                        ),
                      ),
                    ),
                  if (_menu) ..._controls(),
                  // another book loading: this one's pages stay underneath (it's still the current book until the new
                  // one is in - a load that fails leaves it as it was), covered, and nothing reaches them
                  if (_loading)
                    Positioned.fill(child: AbsorbPointer(child: ColoredBox(color: _bg,
                        child: const Center(child: CircularProgressIndicator())))),
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
          // the reason on the page itself (user's mock-ups, 2026-09-29): "This page didn't load: can't reach Komga."
          final e = snap.error!;
          final ex = explain(e, thing: 'page');
          final message = ex.kind == ErrorKind.unreadablePage ? ex.message : "This page didn't load: ${ex.reason}.";
          return Center(child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 32),
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              Icon(Icons.broken_image, color: _ink(0.24), size: 48),
              const SizedBox(height: 10),
              ErrorText(message, e, stack: snap.stackTrace, centre: true, style: TextStyle(color: _ink(0.7)),
                  action: TextButton(onPressed: () => setState(() {}), child: const Text('Retry'))),
            ]),
          ));
        }
        if (!snap.hasData) return const Center(child: CircularProgressIndicator(strokeWidth: 2));
        return PageCanvas(
          data: snap.data!, prefs: _prefs, scroll: _scrollFor(i),
          startAtEnd: _startAtEnd == i,
          levels: _loader!.bookLevels,
          onZoomChanged: (z) { if (z != _zoomed) setState(() => _zoomed = z); },
          onWheel: _onWheel,
          onPanChanged: (pans) => _setSideways(i, pans),
          onEdgeSwipe: (forward) => _turnPage(next: forward), // dragged on past the page's edge
          onPageRect: (r) => _pageRects[i] = r, // for the page curl (layout only - no rebuild)
          idle: i == _index ? null : _whenIdle, // neighbours: processed between turns, not during one
          current: i == _index, // moved off, a zoomed page goes back to fit
          onStepper: (step) => step == null ? _steppers.remove(i) : _steppers[i] = step,
          onZoomToggle: (zoom) => zoom == null ? _zoomers.remove(i) : _zoomers[i] = zoom,
          onZoomStep: (step) => step == null ? _zoomSteps.remove(i) : _zoomSteps[i] = step,
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
      _upNextFuture = _nextFrom(id);
    }
    return _upNextFuture!;
  }

  String? _upNextFor;
  Future<Map<String, dynamic>?>? _upNextFuture;

  // ---- the books read in this visit, in order (user, 2026-09-30): Previous goes back through them, and after going
  // back Next retraces them forward again, like a browser. Past either end, the next / previous book is looked up.
  final List<Map<String, dynamic>> _visited = [];
  int _at = 0; // where [_book] is in [_visited]

  /// Moves to [book], the next (forward) or previous one: steps along the visited books when that's where it is,
  /// else records it (going forward from the middle, the books after here are left behind).
  /// (The visit only moves once the book has loaded: one that fails to open leaves it as it was.)
  Future<void> _goTo(Map<String, dynamic> book, {required bool forward}) {
    final id = book['id'];
    return _open(book, onOpened: () {
      if (forward) {
        if (_at + 1 < _visited.length && _visited[_at + 1]['id'] == id) {
          _at++;
        } else {
          _visited
            ..removeRange(_at + 1, _visited.length)
            ..add(book);
          _at = _visited.length - 1;
        }
      } else if (_at > 0 && _visited[_at - 1]['id'] == id) {
        _at--;
      } else {
        _visited.insert(_at, book); // before where this visit started (or [_at] is 0 anyway)
      }
      _upNextFuture = null; // what's next depends on where in the visit this is
    });
  }

  /// The book after [id]: the one moved on to before, when this visit went back from it; else the one after it in
  /// the read list it was opened from, or the series - opened from a view with read books hidden
  /// ([ReaderScreen.skipRead]), the next one after it that isn't read yet.
  Future<Map<String, dynamic>?> _nextFrom(String id) async {
    if (_at + 1 < _visited.length && _visited[_at]['id'] == id) return _visited[_at + 1];
    var next = await api.nextBook(id, readListId: widget.readListId);
    for (var hops = 0; widget.skipRead && next != null && _isRead(next) && hops < 500; hops++) {
      next = await api.nextBook(next['id'] as String, readListId: widget.readListId);
    }
    return next;
  }

  static bool _isRead(Map<String, dynamic> book) => book['readProgress']?['completed'] == true;

  String get _endText => switch ((widget.readListId != null, widget.skipRead)) {
        (true, true) => 'No unread books left in the read list',
        (true, false) => 'End of the read list',
        (false, true) => 'No unread books left in the series',
        (false, false) => 'End of the series',
      };

  /// After the last page: what's next - its poster and title - or that this was the last one.
  Widget _endCard() {
    final where = widget.readListId != null ? 'this read list' : 'the series';
    final arrow = _rtl ? '←' : '→';
    final dim = TextStyle(color: _ink(0.38));
    return FutureBuilder<Map<String, dynamic>?>(
      future: _upNext(),
      builder: (context, snap) {
        final next = snap.data;
        final List<Widget> body;
        if (snap.connectionState != ConnectionState.done) {
          body = [const SizedBox(width: 28, height: 28, child: CircularProgressIndicator(strokeWidth: 2))];
        } else if (snap.error is NotAvailableOffline) {
          body = [ // offline, and the book that comes next isn't downloaded: no jumping ahead to one that is
            Text("The next book in $where isn't downloaded", textAlign: TextAlign.center,
                style: TextStyle(color: _ink(0.7), fontSize: 16)),
            const SizedBox(height: 12),
            Text('$arrow : close the book', style: dim),
          ];
        } else if (snap.hasError) {
          body = [Text('$arrow : next book in $where', style: dim)]; // couldn't look it up: the turn still tries
        } else if (next == null) {
          body = [
            Text(_endText, style: TextStyle(color: _ink(0.7), fontSize: 16)),
            const SizedBox(height: 12),
            Text('$arrow : close the book', style: dim),
          ];
        } else {
          final number = next['metadata']?['number'] ?? next['number'];
          final title = (next['metadata']?['title'] ?? next['name']) as String?;
          final heading = '${next['seriesTitle'] ?? ''} #$number'.trim();
          body = [
            Text(widget.skipRead ? 'Next unread in $where' : 'Up next in $where', style: dim),
            const SizedBox(height: 12),
            LayoutBuilder(builder: (context, c) {
              final h = (MediaQuery.sizeOf(context).height * 0.42).clamp(160.0, 520.0);
              // the book's poster as Komga has it (a poster picked in Komga included), at its own size - so its size
              // follows the server's thumbnail size - and no bigger than the plate (user, 2026-10-03; the cover page
              // used before showed the middle of a spread when page 1 was one)
              return NativePoster(api.thumbImage(api.bookThumb(next['id'] as String)), max: Size(h * 0.8, h));
            }),
            const SizedBox(height: 14),
            Text(heading, textAlign: TextAlign.center, style: TextStyle(color: _ink(1), fontSize: 18)),
            if (title != null && title != heading && !title.endsWith('#$number'))
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(title, textAlign: TextAlign.center, maxLines: 2, overflow: TextOverflow.ellipsis,
                    style: TextStyle(color: _ink(0.7))),
              ),
            const SizedBox(height: 14),
            Text('$arrow : open it', style: dim),
          ];
        }
        return Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              Text('End of book', style: TextStyle(color: _ink(0.7), fontSize: 18)),
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


  /// Top bar (close, title, fit, night, read toggle, more) and bottom bar (page counter, slider, display, next book).
  /// A tap anywhere that isn't a control hides them.
  List<Widget> _controls() {
    // read: marked so, or the last page reached in this visit (saved as read at once, _pageTurned). Not merely being
    // on the last page: after Mark unread there, the tick has to show unread (code review, 2026-09-30)
    final completed = _book['readProgress']?['completed'] == true || (_turned && _index >= _last);
    final shown = _scrub ?? _index.clamp(0, _last);
    final night = _settings.display.night;
    const bar = Color(0xE6101012);
    final showClock = _settings.display.clock != ShowWhen.off; // with the controls up: With the controls, or Always
    final clockInBar = MediaQuery.sizeOf(context).width >= 700; // a phone's top bar has no room for it
    return [
      Positioned.fill(child: GestureDetector(behavior: HitTestBehavior.opaque, onTap: _hideControls)),
      Positioned(
        left: 0, right: 0, top: 0,
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Material(
          color: bar,
          child: Theme(
          data: readerControlsTheme(context),
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
                // Clock and battery with the controls up, where the bar has room (else just under it, below)
                if (showClock && clockInBar)
                  const Padding(padding: EdgeInsets.symmetric(horizontal: 8), child: ReaderClock()),
                // one press = next fit mode (screen -> width -> height -> original size), label shows which
                IconButton(
                  focusNode: _ctl[_Ctl.fit],
                  tooltip: _prefs.fit == FitMode.original ? 'Original size' : 'Fit ${_prefs.fit.label.toLowerCase()}',
                  onPressed: () => _setFit(FitMode.values[(_prefs.fit.index + 1) % FitMode.values.length]),
                  icon: fitIcon(_prefs.fit, size: 26, color: Colors.white), // ↔ / ↕ (display_panel.dart)
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
                    } catch (e, st) {
                      if (mounted) {
                        showErrorSnack(context,
                            couldnt('mark "${_titleOf(_book)}" as ${completed ? 'unread' : 'read'}', e, thing: 'book'), e, st);
                      }
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
        // narrow screens: no room on the top bar - the clock sits just under it, at the right
        if (showClock && !clockInBar)
          Align(
            alignment: Alignment.centerRight,
            child: IgnorePointer(
              child: Container(
                margin: const EdgeInsets.fromLTRB(0, 8, 10, 0),
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(color: bar, borderRadius: BorderRadius.circular(10)),
                child: const ReaderClock(fontSize: 12),
              ),
            ),
          ),
        ]),
      ),
      Positioned(
        left: 0, right: 0, bottom: 0,
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        if (_stripShown) _filmStrip(bar),
        Material(
          color: bar,
          child: Theme(
          data: readerControlsTheme(context),
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
                if (_pages.length > 1)
                  _iconCtl(node: _ctl[_Ctl.pages]!, icon: _stripOpen ? Icons.view_carousel : Icons.view_carousel_outlined,
                      label: _stripOpen ? 'Hide pages' : 'Show pages', onPressed: _toggleStrip),
                if (_seriesId != null)
                  _iconCtl(node: _ctl[_Ctl.image]!, icon: Icons.settings_brightness, label: 'Image settings',
                      onPressed: () => showImagePanel(context,
                          seriesId: _seriesId!, seriesTitle: _book['seriesTitle'] as String?)),
                _iconCtl(node: _ctl[_Ctl.reader]!, icon: Icons.tune,
                    label: 'Reader settings',
                    onPressed: () => showReaderPanel(context,
                        seriesId: _seriesId, seriesTitle: _book['seriesTitle'] as String?,
                        komgaDirection: _komgaDirection, bookFit: _bookFit,
                        page: canSaveCopyPictures && _index <= _last
                            ? PageActions(save: _savePage, copy: _copyPage) : null)),
                IconButton(focusNode: _ctl[_Ctl.nextBook], tooltip: 'Next book', onPressed: _nextBook,
                    icon: const Icon(Icons.skip_next, size: 28)),
              ]),
            ),
          ),
          ),
        ),
        ]),
      ),
    ];
  }

  // ---- the page strip (user, 2026-10-02): a film strip of the book's pages above the bottom bar, opened by the
  // Pages button. A page tapped (or OK on it) is gone to; the strip and the controls stay up. Right to left, page 1
  // is at the right.
  // open or closed is kept on the device: open, it's there every time the controls come up, book after book, until
  // closed with the button (user, 2026-10-02)
  bool get _stripOpen => _settings.display.pageStrip;
  int? _stripAt; // the page the remote is on in the strip
  final _stripScroll = ScrollController();
  static const _stripGap = 6.0, _stripMaxHeight = 100.0, _stripAtLeast = 8, _stripAspect = 2 / 3;

  /// A thumbnail's width for a strip [width] wide: at most ~100 px tall, smaller so at least 8 always fit across.
  double _tileWidth(double width) =>
      math.min(_stripMaxHeight * _stripAspect, (width - 16 - (_stripAtLeast - 1) * _stripGap) / _stripAtLeast);

  void _toggleStrip() {
    final open = !_stripOpen;
    _settings.setDisplay(_settings.display.copyWith(pageStrip: open));
    if (open) _stripCentre(_index.clamp(0, _last), jump: true);
  }

  /// Scrolls the strip so page [i] is in the middle (or as near as its ends allow); null: the page being read, as it
  /// is once this frame is drawn.
  void _stripCentre(int? at, {bool jump = false}) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_stripScroll.hasClients) return;
      final i = at ?? _index.clamp(0, _last);
      final p = _stripScroll.position;
      final tile = _tileWidth(p.viewportDimension + 16) + _stripGap; // the list sits inside 8 px of padding each side
      final target = (i * tile - (p.viewportDimension - tile) / 2).clamp(0.0, p.maxScrollExtent);
      jump ? _stripScroll.jumpTo(target) : _stripScroll.animateTo(target,
          duration: const Duration(milliseconds: 180), curve: Curves.easeOut);
    });
  }

  void _stripFocus() {
    _stripAt = _index.clamp(0, _last);
    _ctl[_Ctl.strip]!.requestFocus();
    _stripCentre(_stripAt!);
    setState(() {});
  }

  void _stripGo(int i) {
    _stripAt = i;
    _sliderJump(i); // as the slider: the way back is kept
    setState(() {});
  }

  /// The remote in the strip: Left / Right along it (on screen: right to left, Right is back a page), OK goes there.
  /// Up / Down are the controls' own (_move).
  KeyEventResult _onStripKey(FocusNode _, KeyEvent e) {
    if (e is! KeyDownEvent && e is! KeyRepeatEvent) return KeyEventResult.ignored;
    final k = e.logicalKey;
    final at = _stripAt ?? _index.clamp(0, _last);
    if (k == LogicalKeyboardKey.arrowLeft || k == LogicalKeyboardKey.arrowRight) {
      final step = (k == LogicalKeyboardKey.arrowRight) != _rtl ? 1 : -1;
      setState(() => _stripAt = (at + step).clamp(0, _last));
      _stripCentre(_stripAt!);
      return KeyEventResult.handled;
    }
    if (_isOk(k)) {
      if (e is KeyDownEvent) _stripGo(at);
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  int? _stripFollowed; // the slider's page the strip last followed (null: not scrubbing)

  Widget _filmStrip(Color bar) {
    // scrubbing the slider (finger, mouse or remote): the strip follows the page picked; when the scrub ends (gone
    // there, or cancelled), back to the page being read (user, 2026-10-03)
    final follow = _scrub;
    if (follow != _stripFollowed) {
      final wasScrubbing = _stripFollowed != null;
      _stripFollowed = follow;
      if (follow != null) {
        _stripCentre(follow, jump: true);
      } else if (wasScrubbing) {
        _stripCentre(null, jump: true);
      }
    }
    final accent = Theme.of(context).colorScheme.primary;
    final dpr = MediaQuery.devicePixelRatioOf(context);
    final node = _ctl[_Ctl.strip]!;
    return Focus(
      focusNode: node,
      onKeyEvent: _onStripKey,
      onFocusChange: (_) => setState(() {}),
      child: Material(
        key: const ValueKey('page-strip'),
        color: bar,
        child: LayoutBuilder(builder: (context, box) {
          final w = _tileWidth(box.maxWidth), h = w / _stripAspect;
          return SizedBox(
            height: h + 16 + 10, // room for the way-back mark under a tile
            child: ListView.builder(
              controller: _stripScroll,
              scrollDirection: Axis.horizontal,
              reverse: _rtl,
              padding: const EdgeInsets.fromLTRB(8, 8, 8, 0),
              itemExtent: w + _stripGap,
              itemCount: _last + 1,
              itemBuilder: (context, i) {
                final current = i == _index;
                // white: where the remote is in the strip, or the page being picked on the slider
                final remote = (node.hasFocus && i == (_stripAt ?? _index)) || i == _scrub;
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
                    if (i == _returnTo)
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
            showValueIndicator: ShowValueIndicator.never, // the preview says which page
            // a known inset, so the preview can sit over the thumb: the track runs edge to edge inside it
            padding: const EdgeInsets.symmetric(horizontal: _sliderInset, vertical: 12),
          ),
          child: LayoutBuilder(builder: (context, box) => Stack(clipBehavior: Clip.none, children: [
            _sliderItself(shown, box.maxWidth),
            // over the track, under the preview: while scrubbing, and whenever there's a page to go back to
            if (_scrub != null || _returnTo != null) _startMark(box.maxWidth),
            if (_scrub != null) _preview(shown, box.maxWidth),
          ])),
        ),
      ),
    );
  }

  static const _sliderInset = 20.0;
  static const _previewSize = Size(120, 196);

  /// Page previews on the slider: while a page is being picked (dragging, or the remote scrubbing), a small picture
  /// of it and its number, over the thumb.
  Widget _preview(int shown, double width) {
    final x = _xOf(shown, width);
    if (!_settings.display.pagePreviews) {
      // Page previews off (Settings > Reader): just the number over the thumb - nothing asked of Komga
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
        _thumbQueue..remove(i)..add(i);
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
    if (!mounted || _thumbsLoading.length >= _thumbsAtOnce) return;
    final int i;
    if (_thumbWanted != null) {
      i = _thumbWanted!;
      _thumbWanted = null;
    } else if (_thumbQueue.isNotEmpty) {
      i = _thumbQueue.removeLast();
    } else {
      return;
    }
    if (_thumbs.containsKey(i) || _thumbsLoading.contains(i) || i > _last) { _nextThumb(); return; }
    final bookId = _book['id'] as String;
    _thumbsLoading.add(i);
    void done(void Function() record) {
      if (!mounted || _book['id'] != bookId) return; // another book since
      _thumbsLoading.remove(i);
      record();
      while (_thumbs.length > _thumbsKept) {
        _thumbs.remove(_thumbs.keys.first);
      }
      if (_scrub != null || (_menu && _stripShown)) setState(() {});
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

  // Touch on the slider is followed here, not by the Slider's own drag: that could be cancelled mid-drag, which
  // jumped to the page with the finger still down and left the preview stuck (user, 2026-09-30). Now the page
  // changes only when the finger lifts.
  int? _sliderPointer;

  int _pageAt(double x, double width) {
    final along = ((x - _sliderInset) / (width - 2 * _sliderInset)).clamp(0.0, 1.0);
    return ((_rtl ? 1 - along : along) * _last).round();
  }

  /// Where page [i] sits on the slider (right to left: page 1 at the right end).
  double _xOf(int i, double width) {
    final along = _sliderInset + (_last == 0 ? 0 : i / _last) * (width - 2 * _sliderInset);
    return _rtl ? width - along : along;
  }

  static const _snap = 14.0; // a finger this close to the start mark lands on it

  /// The page under a finger dragging along the slider: the start mark's page when it's close to it.
  int _dragPageAt(double x, double width) =>
      (x - _xOf(_scrubOrigin, width)).abs() <= _snap ? _scrubOrigin : _pageAt(x, width);

  /// Off to the page picked on the slider - remembering where the reader was, to come back to.
  void _sliderJump(int target) {
    if (target == _index) return;
    _finishCurlNow();
    if (_index <= _last) _returnTo ??= _index;
    _jumpingTo = target;
    _pc?.jumpToPage(target);
  }

  /// A line across the slider at the page to go back to - shown while scrubbing (the page it started from) and, after
  /// a jump, all the time until it's forgotten (user, 2026-10-02).
  Widget _startMark(double width) {
    final accent = Theme.of(context).colorScheme.primary;
    return Positioned(
      left: _xOf(_scrubOrigin, width) - 1.5,
      top: 0,
      bottom: 0,
      width: 3,
      child: IgnorePointer(
        child: Center(
          child: Container(
            key: const ValueKey('scrub-start'),
            height: 22,
            decoration: BoxDecoration(color: accent, borderRadius: BorderRadius.circular(1.5),
                boxShadow: const [BoxShadow(color: Colors.black54, blurRadius: 2)]),
          ),
        ),
      ),
    );
  }

  Widget _sliderItself(int shown, double width) => Listener(
        behavior: HitTestBehavior.opaque,
        onPointerDown: (e) {
          if (_sliderPointer != null) return; // one finger scrubs
          _sliderPointer = e.pointer;
          _thumbShown = null; // not the last scrub's page
          setState(() => _scrub = _dragPageAt(e.localPosition.dx, width));
        },
        onPointerMove: (e) {
          if (e.pointer != _sliderPointer) return;
          final p = _dragPageAt(e.localPosition.dx, width);
          if (p != _scrub) setState(() => _scrub = p);
        },
        onPointerUp: (e) {
          if (e.pointer != _sliderPointer) return;
          _sliderPointer = null;
          _sliderJump(_dragPageAt(e.localPosition.dx, width));
          setState(() => _scrub = null);
        },
        onPointerCancel: (e) {
          if (e.pointer != _sliderPointer) return;
          _sliderPointer = null;
          setState(() => _scrub = null); // the system took the touch: stay where we were
        },
        child: IgnorePointer(
          child: Slider(
            focusNode: _sliderInner,
            min: 0,
            max: _last.toDouble(),
            divisions: _last,
            value: shown.toDouble(),
            label: 'Page ${shown + 1}',
            onChanged: (_) {}, // enabled look; touch and keys are handled above
          ),
        ),
      );
}

/// Komga lists the book with no pages (a damaged file, or not analysed yet).
class _NoPages implements Exception {}

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
