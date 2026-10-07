import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../api.dart';
import '../errors.dart';
import '../offline/connection.dart';
import '../offline/offline_komga.dart' show NotAvailableOffline;
import '../reader/comic_renderer.dart';
import '../reader/end_card.dart';
import '../reader/reader_bars.dart';
import '../reader/reader_device.dart';
import '../reader/reader_slider.dart';
import '../reader/renderer.dart';
import '../reader_keys.dart';
import '../screen.dart';
import '../settings.dart';
import '../widgets/error_text.dart';
import '../widgets/reader_clock.dart';
import 'actions.dart';

export '../reader/comic_renderer.dart' show CurlLayer, trimPictures;

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
///
/// The one Reader (user, 2026-10-07; reports\plan-reader-renderer-2026-10-07.md): the controls, the keys and taps,
/// the book's progress and the moving between books are here; the pages themselves are the comic renderer's
/// (lib/reader/comic_renderer.dart).
class ReaderScreen extends StatefulWidget {
  /// Times the reader has been built (debug builds only; tests).
  @visibleForTesting
  static int debugBuilds = 0;

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

enum _Ctl { close, night, fullscreen, read, delete, prevBook, slider, nextBook }

class _ReaderScreenState extends State<ReaderScreen>
    with TickerProviderStateMixin, ReaderDevice<ReaderScreen>
    implements ReaderHost {
  late dynamic _book = widget.book;
  late final ComicRenderer _comic = ComicRenderer(this)..addListener(_onRenderer);
  bool _menu = false; // controls shown
  final _scrubber = SliderScrub(); // the page picked on the slider, not jumped to yet (lib/reader/reader_slider.dart)
  int? get _scrub => _scrubber.value;
  set _scrub(int? v) => _scrubber.value = v;
  bool get _scrubbing => _scrubber.remote; // the remote is driving the slider
  set _scrubbing(bool v) => _scrubber.remote = v;
  // Where the reader was before the slider took them elsewhere - marked on the slider while scrubbing, and a drag near
  // it snaps to it, so after a look at another page they can get back (user, 2026-10-02). Kept over slider jumps
  // only: an ordinary page turn means reading on from here, so it's forgotten (else reading on from a page looked at
  // kept the old place for good - user, 2026-10-02); also once that page is reached again, or another book opens.
  int? _returnTo;
  int? _jumpingTo; // the page a slider jump is going to: its page change isn't a page turn
  int get _scrubOrigin => _returnTo ?? _index.clamp(0, _last);
  bool _loading = true;
  bool _turned = false; // progress is only saved once a page has been turned in this visit
  int _openedAt = 0;
  Timer? _saveTimer;
  Timer? _flashTimer;
  bool _flash = false; // the page note shows for a moment after a turn (Page corner: After a turn)
  final FocusNode _keys = FocusNode(debugLabel: 'reader-keys', skipTraversal: true);
  final FocusNode _sliderInner = FocusNode(canRequestFocus: false, skipTraversal: true); // the wrapper takes focus
  final Map<_Ctl, FocusNode> _ctl = {for (final c in _Ctl.values) c: FocusNode(debugLabel: 'ctl-${c.name}')};

  @override
  Komga get api => widget.api;
  int get _index => _comic.index;
  List<dynamic> get _pages => _comic.pages;
  int get _last => _comic.last;
  bool get _rtl => _comic.rtl;
  AppSettings get _settings => AppSettings.instance;
  String? get _seriesId => _book['seriesId'] as String?;

  // ---- what the renderer asks of the Reader (lib/reader/renderer.dart)

  @override
  TickerProvider get vsync => this;
  @override
  bool get controlsUp => _menu;
  @override
  bool get busy => _busy;
  @override
  int? get scrub => _scrub;
  @override
  int? get wayBack => _returnTo;
  @override
  void changed() => _onRenderer();
  @override
  void tap(double x) => _tap(x);
  @override
  void toggleControls() => _menu ? _hideControls() : _showControls();
  @override
  void turned(int place) => _pageTurned(place);
  @override
  void nextBook() => _nextBook();
  @override
  void jumpTo(int place) => _sliderJump(place);
  @override
  Widget endCard() => _endCard();

  void _onRenderer() {
    if (mounted) setState(() {});
  }

  @override
  void initState() {
    super.initState();
    openDevice(); // the screen kept on, the rotation lock, the system bars, full screen (lib/reader/reader_device.dart)
    // back in the app (unlocked, switched back to): read further elsewhere meanwhile?
    _life = AppLifecycleListener(onResume: () => unawaited(_checkElsewhere()));
    _visited.add(Map<String, dynamic>.from(_book as Map)); // the visit starts here
    _open(_book);
  }

  @override
  void dispose() {
    _saveTimer?.cancel();
    _flashTimer?.cancel();
    closeDevice();
    _life?.dispose();
    // before Downloads hears the book closed: a book finished here is marked read first. No question while closing:
    // if another device moved the book on meanwhile, nothing is saved over it
    _saveNow(ask: false);
    deviceClosed();
    _comic
      ..removeListener(_onRenderer)
      ..dispose();
    _keys.dispose();
    _sliderInner.dispose();
    _endNext.dispose();
    _endClose.dispose();
    for (final n in _ctl.values) {
      n.dispose();
    }
    super.dispose();
  }

  @override
  void onReaderSettings() {
    // rebuilt only for what it shows: brightness and night warmth are drawn over the whole app, not by the reader
    // (a brightness slider drag rebuilt the reader many times a second - code review 2026-10-05, #44)
    final shown = _shownSettings();
    if (shown == _lastShownSettings) return;
    _lastShownSettings = shown;
    setState(() {});
  }

  String? _lastShownSettings;
  String _shownSettings() {
    final d = _settings.display.toJson()
      ..remove('brightness')
      ..remove('warmth');
    return jsonEncode({'d': d, 'r': _settings.defaults.toJson(), 's': _settings.series[_seriesId]?.toJson()});
  }

  (String, Object, StackTrace)? _openError; // the book couldn't be opened, and there's none on screen

  static String _titleOf(dynamic b) => ComicRenderer.titleOf(b);

  int _openRun = 0; // each _open's number: an older one still loading doesn't take over

  /// Opens [book]. The book being read stays the current one - its pages (under the loading cover), where progress is
  /// saved, the title - until the new one has loaded; a load that fails leaves it exactly as it was (code review,
  /// 2026-09-30: closing mid-load saved the old book's page to the new one). [onOpened] runs once it has loaded.
  Future<void> _open(dynamic book, {VoidCallback? onOpened}) async {
    final run = ++_openRun;
    setState(() { _loading = true; _menu = false; _openError = null; });
    try {
      final fresh = await api.book(book['id']) ?? book; // current progress from the server
      final prepared = await _comic.prepare(fresh as Map);
      if (!mounted || run != _openRun) return; // closed, or another book asked for since
      final start = ComicRenderer.startOf(fresh, prepared.pages.length);
      _comic.show(fresh, prepared, start);
      setState(() {
        _book = fresh; _returnTo = null;
        _openedAt = start; _turned = false;
        _known[fresh['id'] as String] = _progressOf(fresh); // as Komga has it now: a change elsewhere is from here on
        _loading = false;
      });
      onOpened?.call();
      _keys.requestFocus();
    } catch (e, st) {
      if (!mounted || run != _openRun) return;
      final empty = e is NoPages;
      final message = empty
          ? '"${_titleOf(book)}" has no pages (Komga may need to analyse it again).'
          : couldnt('open "${_titleOf(book)}"', e, thing: 'book');
      if (!_comic.opened) {
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

  /// The page view moved to [i] (from the renderer).
  @override
  void pageChanged(int i, {required bool curling}) {
    awake();
    final jump = i == _jumpingTo;
    _jumpingTo = null;
    setState(() {
      if (!jump || i == _returnTo) _returnTo = null; // read on from here, or back where it was
    });
    if (i >= _last - 1) _upNext().ignore(); // look up what's next before the end card shows (errors: shown there)
    if (i > _last && !_menu) {
      _endReached();
    } else if (_endNext.hasFocus || _endClose.hasFocus) {
      _keys.requestFocus(); // off the end card
    }
    // a curl moves the page view underneath as it starts: that counts once the curl completes (turned) - one let go
    // before halfway leaves no trace (code review, 2026-09-30: it un-read a finished book)
    if (!curling) _pageTurned(i);
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
    if (i <= _last && _settings.display.pageNote == PageNote.afterTurn) {
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
    _comic.bookChanged(_book as Map);
    _wentElsewhere++;
    _turned = false; // the other device's progress stands: the jump there isn't a turn of this reader's
    final target = finished ? _pages.length : goTo! - 1; // finished: the end card, with the next book
    _openedAt = target;
    _comic.jumpTo(target);
    return false;
  }

  // ---- taps: the side you read towards goes forward, the other back, the middle shows the controls (a double tap
  // to zoom is the renderer's)

  /// A single tap at [x] (0..1 across the screen). Tap zones follow the reading direction.
  void _tap(double x) {
    if (x < 0.33) {
      _rtl ? _comic.forward() : _comic.back();
    } else if (x > 0.67) {
      _rtl ? _comic.back() : _comic.forward();
    } else {
      _showControls();
    }
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
    if (markRead) {
      try {
        await api.markRead(_book['id']);
        _known[_book['id'] as String] = (_pages.length, true); // this reader's own: not a change from elsewhere
      } catch (e, st) {
        // said as what it is - it used to say "Couldn't find the next book" (#16); the book stays open
        if (mounted) {
          showErrorSnack(context, couldnt('mark "${_titleOf(_book)}" as read', e, thing: 'book'), e, st);
        }
        return;
      }
    } else {
      _saveNow();
    }
    try {
      // settled: nothing more to save for this book on leaving - closing used to save the page over "read" (review)
      _turned = false;
      final next = await _upNext(); // looked up already for the end card: not asked again (#46 - with skip-read,
      // up to 500 requests)
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
    if (mounted && fresh != null && _book['id'] == id && !_busy) {
      setState(() => _book = fresh);
      _comic.bookChanged(fresh);
    }
  }

  // ---- controls
  void _showControls() {
    setState(() { _menu = true; _scrubbing = false; _scrub = null; });
    _keys.requestFocus(); // nothing selected (not the end card's buttons)
    _comic.controlsShown(); // the strip on the page being read now
  }

  void _hideControls() {
    // a finger still on the slider is let go of: hidden by Esc / Back mid-scrub, the scrub is cancelled - its lift
    // still reaches the slider's listener (Flutter sends a pointer's events where it went down) and jumped to the page
    // picked (user, 2026-10-02)
    _scrubber.release();
    setState(() { _menu = false; _scrub = null; _scrubbing = false; });
    _keys.requestFocus();
    if (_onEnd) _endReached();
  }

  /// The two bars, left to right, as the remote walks them: the Reader's own controls with the renderer's in them.
  List<FocusNode> get _topBar => [
        _ctl[_Ctl.close]!,
        for (final b in _comic.topButtons()) b.node,
        _ctl[_Ctl.night]!,
        if (isDesktop) _ctl[_Ctl.fullscreen]!,
        _ctl[_Ctl.read]!,
        _ctl[_Ctl.delete]!,
      ];
  List<FocusNode> _bottomBar(BuildContext context) => [
        _ctl[_Ctl.prevBook]!,
        if (_pages.length > 1) _ctl[_Ctl.slider]!,
        for (final b in _comic.bottomButtons(context)) b.node,
        _ctl[_Ctl.nextBook]!,
      ];

  /// Remote in the controls (user's layout, lib/reader/reader_bars.dart): along a bar, between the bars; with the page
  /// strip open it's a row of its own just above the bottom bar (Left / Right in it are the strip's own).
  void _move({int dx = 0, int dy = 0}) {
    final to = walkControls(
      top: _topBar,
      bottom: _bottomBar(context),
      dx: dx,
      dy: dy,
      row: _comic.stripShown ? _comic.stripNode : null,
      rowBelow: _pages.length > 1 ? _comic.pagesNode : _ctl[_Ctl.prevBook],
    );
    switch (to) {
      case WalkToNode(:final node):
        node.requestFocus();
      case WalkToRow():
        _comic.stripFocus(); // into the strip, on the page shown
        return;
      case WalkOff():
        _keys.requestFocus();
    }
    setState(() {});
  }

  // Fixed keys for moving around the controls and scrubbing the slider (not remappable, so a mapping can't strand the
  // remote); with the controls hidden, keys go through ReaderKeys.
  KeyEventResult _onKey(FocusNode node, KeyEvent e) {
    if (e is! KeyDownEvent && e is! KeyRepeatEvent) return KeyEventResult.ignored;
    awake();
    final k = e.logicalKey;
    if (!_menu) {
      // Volume keys (Android, a setting): down = forward, up = back, in any reading direction. Handled keys don't
      // reach the system, so the volume stays put; a held key turns one page (its repeats are swallowed).
      if ((k == LogicalKeyboardKey.audioVolumeDown || k == LogicalKeyboardKey.audioVolumeUp) &&
          hasVolumeKeys && _settings.display.volumeKeys) {
        if (e is KeyDownEvent) k == LogicalKeyboardKey.audioVolumeDown ? _comic.forward() : _comic.back();
        return KeyEventResult.handled;
      }
      // Shift+Space goes back, whatever Space is set to do
      if (k == LogicalKeyboardKey.space && HardwareKeyboard.instance.isShiftPressed) {
        _comic.back();
        return KeyEventResult.handled;
      }
      // on the end card: Up / Down move between Next book and Close, OK presses the one the remote is on (the EPUB
      // reader's; forward - a fresh press - opens the next book, back goes back to the last page, as below)
      if (_onEnd) {
        if (k == LogicalKeyboardKey.arrowUp || k == LogicalKeyboardKey.arrowDown) {
          final to = k == LogicalKeyboardKey.arrowUp ? _endNext : _endClose;
          if (to.context != null) to.requestFocus();
          return KeyEventResult.handled;
        }
        if (isOkKey(k)) {
          if (e is KeyDownEvent) _endClose.hasFocus ? Navigator.of(context).maybePop() : _comic.forward();
          return KeyEventResult.handled;
        }
      }
      // the rest as set in Settings > Remote and keys (reader_keys.dart); Left and Right swap for right to left
      switch (ReaderKeys.instance.actionFor(k, rtl: _rtl)) {
        case ReaderAction.next:
          // on the end card, moving on to the next book takes a fresh press: a held key's repeats don't
          if (e is KeyDownEvent || _index < _pages.length) _comic.forward();
        case ReaderAction.previous:
          _comic.back();
        case ReaderAction.controls:
          if (e is KeyDownEvent) _showControls();
        case ReaderAction.close: // closes the book (full screen stays)
          if (e is KeyDownEvent) Navigator.of(context).maybePop();
        case ReaderAction.zoomIn: // a step in or out - fit screen, the only fit that zooms
          _comic.zoomStep(true);
        case ReaderAction.zoomOut:
          _comic.zoomStep(false);
        case null:
          return KeyEventResult.ignored;
      }
      return KeyEventResult.handled;
    }
    return controlsKey(e, nothingSelected: _keys.hasPrimaryFocus, hide: _hideControls, move: _move);
  }

  @override
  Widget build(BuildContext context) {
    assert(() {
      ReaderScreen.debugBuilds++;
      return true;
    }());
    final bg = _comic.background;
    return PopScope(
      // Back (tablet or remote) closes the controls first, then the book
      canPop: !_menu,
      onPopInvokedWithResult: (didPop, _) { if (!didPop) _hideControls(); },
      child: Scaffold(
        backgroundColor: bg,
        body: Focus(
          focusNode: _keys,
          autofocus: true,
          onKeyEvent: _onKey,
          child: _openError != null && !_comic.opened
              ? Center(child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 32),
                  child: ErrorText(_openError!.$1, _openError!.$2, stack: _openError!.$3, centre: true,
                      style: TextStyle(color: _comic.ink(0.7)),
                      action: Row(mainAxisSize: MainAxisSize.min, children: [
                        // a book with no pages: retrying won't help - on to the next book instead
                        if (_openError!.$2 is NoPages)
                          TextButton(autofocus: true, onPressed: () => _skipPast(_book), child: const Text('Next book'))
                        else
                          TextButton(autofocus: true, onPressed: () => _open(_book), child: const Text('Retry')),
                        TextButton(onPressed: () => Navigator.of(context).maybePop(), child: const Text('Close')),
                      ])),
                ))
              : !_comic.opened
              ? const Center(child: CircularProgressIndicator())
              : Stack(children: [
                  ..._comic.buildPages(context),
                  // the page note, "12 / 36": always, or for a moment after a turn (Page corner - one setting with
                  // the EPUBs', and their corner: bottom right, user 2026-10-07) - not over the controls (they have
                  // the count) or the end card
                  if (_settings.display.pageNote != PageNote.off)
                  Positioned(
                    right: 14,
                    bottom: 14,
                    child: IgnorePointer(
                      child: AnimatedOpacity(
                        opacity: (_flash || _settings.display.pageNote == PageNote.always) && !_menu && _index <= _last
                            ? 1 : 0,
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
                            backgroundColor: _comic.ink(0.12),
                            color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.85),
                          ),
                        ),
                      ),
                    ),
                  if (_menu) ..._controls(),
                  // another book loading: this one's pages stay underneath (it's still the current book until the new
                  // one is in - a load that fails leaves it as it was), covered, and nothing reaches them
                  if (_loading)
                    Positioned.fill(child: AbsorbPointer(child: ColoredBox(color: bg,
                        child: const Center(child: CircularProgressIndicator())))),
                ]),
        ),
      ),
    );
  }

  /// The book after this one (in the read list it was opened from, else the series) - looked up once per book, when
  /// the last page is near, for the end card.
  Future<Map<String, dynamic>?> _upNext() {
    final id = _book['id'] as String;
    if (_upNextFor != id || _upNextFuture == null) {
      _upNextFor = id;
      final f = _nextFrom(id);
      _upNextFuture = f;
      // a lookup that failed isn't kept: Next book asks again
      f.then((_) {}, onError: (Object _) {
        if (identical(_upNextFuture, f)) _upNextFuture = null;
      });
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

  /// After the last page: what's next, with Next book and Close (lib/reader/end_card.dart).
  Widget _endCard() => ReaderEndCard(
        api: api,
        next: _upNext(),
        ink: _comic.ink,
        where: widget.readListId != null ? 'this read list' : 'the series',
        lastText: _endText,
        skipRead: widget.skipRead,
        nextNode: _endNext,
        closeNode: _endClose,
        onNext: _nextBook,
        onClose: () => Navigator.of(context).maybePop(),
      );

  final _endNext = FocusNode(debugLabel: 'end-next');
  final _endClose = FocusNode(debugLabel: 'end-close');
  bool get _onEnd => _comic.opened && _index > _last;

  /// The end card is reached (or the controls went down over it): the remote on Next book, on Close when there's none.
  void _endReached() =>
      ReaderEndCard.focusOn(_upNext(), _endNext, _endClose, () => mounted && _onEnd && !_menu && !_busy);

  /// Top bar (close, title, the renderer's own, night, read toggle, delete) and bottom bar (previous book, page
  /// counter, slider, the renderer's own, next book) - the shared bars (lib/reader/reader_bars.dart). A tap anywhere
  /// that isn't a control hides them.
  List<Widget> _controls() {
    // read: marked so, or the last page reached in this visit (saved as read at once, _pageTurned). Not merely being
    // on the last page: after Mark unread there, the tick has to show unread (code review, 2026-09-30)
    final completed = _book['readProgress']?['completed'] == true || (_turned && _index >= _last);
    final shown = _scrub ?? _index.clamp(0, _last);
    final night = _settings.display.night;
    return readerBars(
      onTapOutside: _hideControls,
      top: ReaderTopBar(
        closeNode: _ctl[_Ctl.close]!,
        heading: '${_book['seriesTitle'] ?? ''} #${_book['metadata']?['number'] ?? ''}',
        title: '${_book['metadata']?['title'] ?? ''}',
        buttons: [
          for (final b in _comic.topButtons()) b.child,
          IconButton(
            focusNode: _ctl[_Ctl.night],
            tooltip: night ? 'Night mode off' : 'Night mode on',
            icon: Icon(night ? Icons.nightlight : Icons.nightlight_outlined,
                color: night ? const Color(0xFFFFB74D) : null),
            onPressed: () => _settings.setDisplay(_settings.display.copyWith(night: !night)),
          ),
          if (isDesktop) fullscreenButton(_ctl[_Ctl.fullscreen]!),
          barIcon(
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
        ],
      ),
      bottom: ReaderBottomBar(
        prevNode: _ctl[_Ctl.prevBook]!,
        onPrev: _prevBook,
        nextNode: _ctl[_Ctl.nextBook]!,
        onNext: _nextBook,
        above: _comic.stripShown ? _comic.strip(context) : null,
        middle: [
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
        ],
        buttons: [for (final b in _comic.bottomButtons(context)) b.child],
      ),
    );
  }

  Widget _slider(int shown) => ReaderSlider(
        node: _ctl[_Ctl.slider]!,
        innerNode: _sliderInner,
        scrub: _scrubber,
        shown: shown,
        at: _index.clamp(0, _last),
        last: _last,
        rtl: _rtl,
        upDownStep: true,
        wayBack: _scrubOrigin,
        markWayBack: _scrub != null || _returnTo != null, // while scrubbing, and whenever there's a page to go back to
        onScrubStart: _comic.scrubStarted, // not the last scrub's picture
        onJump: _sliderJump,
        changed: () => setState(() {}),
        label: 'Page ${shown + 1}',
        preview: (shown, x) => _comic.preview(context, shown, x),
      );

  /// Off to the page picked on the slider (or the strip) - remembering where the reader was, to come back to.
  void _sliderJump(int target) {
    if (target == _index) return;
    _comic.finishCurlNow();
    if (_index <= _last) _returnTo ??= _index;
    _jumpingTo = target;
    _comic.jumpTo(target);
  }
}
