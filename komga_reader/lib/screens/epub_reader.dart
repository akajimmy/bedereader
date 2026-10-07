import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart' show defaultTargetPlatform;
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';

import '../api.dart';
import '../epub/book.dart';
import '../epub/hyphenator.dart';
import '../epub/layout.dart';
import '../epub/progress.dart';
import '../epub/source.dart';
import '../epub/trace.dart';
import '../epub/xhtml.dart';
import '../errors.dart';
import '../offline/connection.dart';
import '../offline/offline_komga.dart';
import '../reader/reader_bars.dart';
import '../reader/reader_device.dart';
import '../reader/reader_slider.dart';
import '../reader_keys.dart';
import '../screen.dart';
import '../settings.dart';
import '../widgets/display_panel.dart';
import '../widgets/epub_settings.dart';
import '../widgets/error_text.dart';
import '../widgets/focus_style.dart';
import '../widgets/native_poster.dart';
import '../widgets/reader_clock.dart';
import '../widgets/setting_rows.dart';
import 'open_book.dart';

/// The EPUB reader (plan: reports\epub-plan-2026-10-06.md): the book laid out by the app itself (lib/epub/), page by
/// page. Taps: left third back, right third forward, the middle shows the controls; swipes turn; the remote and the
/// volume keys as in the comic reader. The slider and "page X of Y" cover the whole book once every chapter has
/// been counted (in the background after the first page shows); until then they go by chapter.
class EpubReaderScreen extends StatefulWidget {
  const EpubReaderScreen({super.key, required this.api, required this.book, this.source, this.saveProgress = true,
      this.readListId, this.skipRead = false});

  /// Opened from a read list: the next and previous books are the read list's (else the series'). [skipRead]: opened
  /// with Hide read on - the next / previous one not read yet (the comic reader's).
  final String? readListId;
  final bool skipRead;

  /// Opens at, and saves, the reading place through [api] (Komga online; the device offline, sent later). Off: neither
  /// (a book shown from memory in tests).
  final bool saveProgress;
  final Komga api;
  final Map<String, dynamic> book;

  /// Where the book's files come from (default: Komga) - the downloaded file offline.
  final EpubSource? source;

  /// Forgets the closing saves still on their way (tests: each starts with none).
  @visibleForTesting
  static void forgetClosingSaves() => _EpubReaderScreenState._closingSaves.clear();

  /// The page's left / right margin at [width]: the setting's, or more on a wide screen, where lines stop at the
  /// setting's length ([EpubMargins.lineEms]) and the rest goes to the margins.
  static double sideMargin(EpubPrefs e, double width) =>
      math.max(e.margins.side, (width - e.size * e.margins.lineEms) / 2);

  @override
  State<EpubReaderScreen> createState() => _EpubReaderScreenState();
}

/// The controls the remote walks (the comic reader's model): the top bar, then the bottom bar.
enum _Ctl { close, fullscreen, read, prevBook, slider, contents, settings, nextBook }

class _EpubReaderScreenState extends State<EpubReaderScreen> with ReaderDevice<EpubReaderScreen> {
  static Hyphenators? _hyphenators; // loaded once (the value, not the future: a future is tied to where it began)

  EpubBook? _book;
  Object? _error;
  int _chapter = 0; // the chapter shown
  int _page = 0; // its page
  bool _end = false; // on the end card
  PageController _pc = PageController();
  bool _bookWide = false; // the page view runs over the whole book (all counted) - else over [_chapter]
  bool _controls = false;
  final _focus = FocusNode();
  final Map<_Ctl, FocusNode> _ctl = {for (final c in _Ctl.values) c: FocusNode(debugLabel: 'epub-${c.name}')};
  late Map<String, dynamic> _bookNow = widget.book; // refreshed after Mark read / unread

  String get _title => (widget.book['metadata']?['title'] ?? widget.book['name'] ?? '') as String;

  Size _size = Size.zero; // the page area, from the last layout

  /// The book's look from the EPUB settings (synced; the Aa panel): font, size, spacing, margins, theme, formatting.
  /// Lines stay a comfortable length on a wide window (~34 em): the extra width goes to the margins.
  EpubTheme get _theme {
    final e = AppSettings.instance.epub;
    final family = e.font.family ?? switch (e.font) {
      EpubFont.deviceSerif => defaultTargetPlatform == TargetPlatform.windows ? 'Georgia' : 'serif',
      _ => null,
    };
    final side = EpubReaderScreen.sideMargin(e, _size.width);
    return EpubTheme(
      background: e.colours.background,
      text: e.colours.text,
      fontFamily: family,
      fontSize: e.size,
      lineHeight: e.lineSpacing,
      margins: EdgeInsets.fromLTRB(side, e.margins.topBottom, side, e.margins.topBottom),
      bookFormatting: e.bookFormatting,
      paragraphGap: e.paragraphGap.ems,
      accent: Theme.of(context).colorScheme.primary,
      pixelRatio: MediaQuery.devicePixelRatioOf(context),
    );
  }

  @override
  void onReaderSettings() {
    if (mounted) setState(() {}); // a new look: laid out again on the next build (same place kept)
  }

  @override
  void initState() {
    super.initState();
    openDevice(); // the screen kept on, the rotation lock, the system bars, full screen (lib/reader/reader_device.dart)
    if (readerTiming) SchedulerBinding.instance.addTimingsCallback(_onFrames); // a measuring build only
    // back in the app: has the book moved on on another device meanwhile?
    if (_online) _life = AppLifecycleListener(onResume: () => unawaited(_checkElsewhere()));
    _open();
  }

  // frame times for the trace (how smooth turns are, measured on the device)
  final _frameStats = FrameStats();
  void _onFrames(List<ui.FrameTiming> timings) {
    for (final t in timings) {
      final line = _frameStats.add(t.buildDuration.inMicroseconds / 1000, t.rasterDuration.inMicroseconds / 1000,
          DateTime.fromMicrosecondsSinceEpoch(t.timestampInMicroseconds(ui.FramePhase.rasterFinishWallTime)),
          vsyncUs: t.timestampInMicroseconds(ui.FramePhase.vsyncStart));
      if (line != null) EpubTrace.instance.log(line);
    }
  }

  @override
  void dispose() {
    if (readerTiming) {
      SchedulerBinding.instance.removeTimingsCallback(_onFrames);
      final last = _frameStats.flush();
      if (last != null) EpubTrace.instance.log(last);
    }
    EpubTrace.instance.log('closed');
    closeDevice();
    _cornerTimer?.cancel();
    for (final t in _prefetchTimers) {
      t.cancel();
    }
    _life?.dispose();
    _saveNow(ask: false); // closing: the place goes now, not after the settle time (not over another device's)
    // the book opened again before this lands waits for it - else it loaded the place before, and this save then
    // looked like another device's (EPUB review R8)
    final id = widget.book['id'] as String, closing = _saves;
    _closingSaves[id] = closing;
    closing.whenComplete(() {
      if (identical(_closingSaves[id], closing)) _closingSaves.remove(id);
    });
    deviceClosed(); // after the last save: a book finished here is marked read before Delete once read hears of it
    _book?.removeListener(_onBook);
    _book?.dispose();
    _pc.dispose();
    _focus.dispose();
    for (final n in _ctl.values) {
      n.dispose();
    }
    _endNext.dispose();
    _endClose.dispose();
    super.dispose();
  }

  Future<void> _open() async {
    unawaited(EpubTrace.instance.open());
    EpubTrace.instance.log('open ${widget.book['id']} "$_title" ${widget.source == null ? 'from Komga' : 'from a file'}');
    try {
      final hy = _hyphenators ??= await Hyphenators.load(rootBundle.loadString);
      final source = widget.source ?? KomgaEpubSource(widget.api, widget.book['id'] as String);
      final info = await source.info();
      if (info.spine.isEmpty) throw StateError('This book has no chapters');
      // where reading stopped (Komga's progression, shared with its web reader); a book not started: the start
      if (_online) {
        try {
          await _closingSaves[widget.book['id']]?.timeout(const Duration(seconds: 20), onTimeout: () {});
          final at = await _progress.load(widget.book);
          final i = at == null ? -1 : info.spine.indexOf(at.path);
          if (i >= 0) {
            _chapter = i;
            _startFraction = at!.progression;
          }
        } catch (_) {
          // Komga can't say: the start
        }
        try {
          _known = await _progress.place(); // what another device's change is told from
        } catch (_) {
          // learnt at the first save instead
        }
      }
      if (!mounted) return;
      // the book's own text size first (a book set smaller or larger all through shows at the reader's size)
      final book = EpubBook(source, info, hy);
      await book.measureTextSize();
      // the chapters' shares of the book till they're counted (Komga's positions; kept with a downloaded book too)
      // (only where progress is kept, as the place above: else Komga isn't asked)
      if (_online) {
        try {
          book.estimateFrom([
            for (final p in await _progress.positions()) EpubProgress.pathOf((p as Map)['href'] as String),
          ]);
        } catch (_) {
          // none: equal shares till counted
        }
      }
      if (!mounted) {
        book.dispose();
        return;
      }
      setState(() => _book = book..addListener(_onBook));
    } catch (e) {
      if (mounted) setState(() => _error = e);
    }
  }

  // ---- progress (Komga's progression; plan step 4)

  late final EpubProgress _progress = EpubProgress(widget.api, widget.book['id'] as String);
  bool get _online => widget.saveProgress; // (offline the api is OfflineKomga: kept on the device, sent later)
  double? _startFraction; // the saved place in the opening chapter, 0..1
  Timer? _saveTimer;
  EpubPosition? _saved; // the last place saved (not saved again)
  bool _markedRead = false;
  bool _moved = false; // turned / jumped since opening: only then is a place saved (opening alone saves nothing)

  /// A page turned: saved once it has been on screen for a moment (turning on quickly saves only the last).
  void _settled() {
    _saveTimer?.cancel();
    _saveTimer = Timer(const Duration(milliseconds: 1500), _saveNow);
  }

  /// [ask]: false while closing (no question then): if another device has moved the book on meanwhile, nothing is
  /// saved over it.
  void _saveNow({bool ask = true}) {
    _saveTimer?.cancel();
    final b = _book;
    if (b == null || !_online || _end || !_moved) return;
    final at = b.positionOf(_chapter, _page);
    if (at == _saved) return;
    final length = b.lengthOf(_chapter);
    if (length == 0) return;
    _saved = at;
    final path = b.info.spine[_chapter], progression = at.position / length, total = b.progression(at);
    // one at a time, in order; one queued before the reader went to another device's place is dropped (as comics)
    final went = _wentElsewhere;
    _saves = _saves.then((_) => went == _wentElsewhere ? _save(path, progression, total, at, ask: ask) : null);
  }

  // ---- the book moved on on another device while it was open here (as the comic reader does with pages - user,
  // 2026-10-05: read on the PC, then the tablet, left open on that book, saved its old page over it). Before a save,
  // and on coming back to the app, the reader asks Komga where the book is; if that isn't what this reader last
  // loaded, saved or accepted, another device moved it, and it asks: Stay here / Go there.

  /// Each book's save from its last closing, while it's on its way (the book opened again waits for it).
  static final Map<String, Future<void>> _closingSaves = {};

  EpubKomgaPlace? _known; // Komga's place as this reader last loaded, saved or accepted (null: not known yet)
  Future<void> _saves = Future.value();
  Future<bool>? _question; // the question on screen: a second asker waits for its answer
  int _wentElsewhere = 0; // times the reader went to another device's place (saves queued before: dropped)
  AppLifecycleListener? _life;

  /// Komga's place if another device moved the book on; null if not, or if Komga can't say (the save goes ahead).
  Future<EpubKomgaPlace?> _movedElsewhere() async {
    if (!_online || Connection.instance.offline) return null;
    try {
      final now = await _progress.place();
      final known = _known;
      if (known == null) {
        _known = now; // nothing to compare with yet: from now on
        return null;
      }
      return now.sameAs(known) ? null : now;
    } catch (_) {
      return null;
    }
  }

  Future<void> _save(String path, double progression, double total, EpubPosition at, {required bool ask}) async {
    final moved = await _movedElsewhere();
    if (moved != null) {
      if (!ask || !mounted) return; // closing: theirs stands
      if (!await _askAboutElsewhere(moved)) return; // gone to theirs: nothing of this one's to save
    }
    // a failed save isn't counted as saved: the next turn - or closing - saves it again (it was marked saved before
    // it went, so closing skipped it - EPUB review R7)
    try {
      await _progress.save(path, progression, total);
    } catch (_) {
      if (_saved == at) _saved = null;
      return;
    }
    // Komga's place now is this reader's own: noted as saved, then read back (Komga may change the read state with
    // it) - a failed read-back left the place before, and the next save asked about this reader's own (R6)
    _known = EpubKomgaPlace(path, progression, total, finished: false);
    try {
      _known = await _progress.place();
    } catch (_) {}
  }

  /// Mark read / unread, in line with the saves: a save still waiting is dropped and one under way finishes first,
  /// so the mark is the last word; the state Komga has afterwards is this reader's doing, not another device's.
  /// (Done outside the queue, a pending save could land after the mark - the book back in progress - or ask about
  /// this reader's own mark: EPUB review R4.)
  Future<void> _markBook({required bool read}) {
    _saveTimer?.cancel();
    _moved = false; // the mark stands: not undone by a save on closing
    _wentElsewhere++; // saves queued before it don't run after it
    final id = widget.book['id'] as String;
    final done = _saves.then((_) async {
      read ? await widget.api.markRead(id) : await widget.api.markUnread(id);
      try {
        _known = await _progress.place();
      } catch (_) {
        _known = null; // learnt afresh at the next look
      }
    });
    _saves = done.catchError((Object _) {});
    return done;
  }

  /// Back in the app with the book open: has it moved on elsewhere meanwhile? In line with the saves.
  Future<void> _checkElsewhere() {
    _saves = _saves.then((_) async {
      if (!mounted || _book == null || _question != null) return;
      final moved = await _movedElsewhere();
      if (moved != null && mounted) await _askAboutElsewhere(moved);
    });
    return _saves;
  }

  /// The question. True: stay here (this reader's place is saved next); false: went to the other device's. Asked
  /// once at a time: a second asker waits for the answer.
  Future<bool> _askAboutElsewhere(EpubKomgaPlace moved) =>
      _question ??= _ask(moved).whenComplete(() => _question = null);

  Future<bool> _ask(EpubKomgaPlace moved) async {
    final b = _book!;
    final here = (b.progression(b.positionOf(_chapter, _page)) * 100).round();
    final chapter = moved.path == null ? null : b.chapterOf(moved.path!);
    final there = moved.total == null ? null : (moved.total! * 100).round();
    final (title, text, go) = moved.finished
        ? ('Finished on another device', 'This book was read to the end on another device.', 'Go to the end')
        : moved.path == null || chapter == null
            ? ('Started over on another device', 'This book was marked unread on another device.', 'Go to the start')
            : ('Read on another device',
                there == null ? 'This book was read further on another device.' : 'On another device this book is at $there%.',
                there == null ? 'Go there' : 'Go to $there%');
    final stay = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text(title),
        content: Text(text),
        actions: [
          TextButton(autofocus: true, onPressed: () => Navigator.pop(c, true), child: Text('Stay at $here%')),
          TextButton(onPressed: () => Navigator.pop(c, false), child: Text(go)),
        ],
      ),
    );
    _known = moved; // answered: asked again only if it moves again
    if (stay != false || !mounted) return true; // Stay (or dismissed: Back = stay) - this reader's place goes next
    _saveTimer?.cancel();
    _wentElsewhere++;
    _moved = false; // the other device's place stands: going there isn't a turn of this reader's
    _saved = null;
    if (moved.finished) {
      await _show(b.chapterCount - 1, 1 << 30); // the last page; a turn on is the end card
    } else if (chapter == null) {
      await _show(0, 0);
    } else {
      await _show(chapter, 0, fraction: moved.progression);
    }
    return false;
  }

  /// The end card: the book is read.
  void _reachedEnd() {
    if (_markedRead || !_online) return;
    _markedRead = true;
    final id = widget.book['id'] as String;
    // in line with the saves; Komga's place read back after (its read state is this reader's doing)
    _saves = _saves.then((_) async {
      try {
        await widget.api.markRead(id);
        _known = await _progress.place();
      } catch (_) {}
    });
  }

  // ---- layout

  bool _counting = false;

  void _layout(Size size) {
    final b = _book!;
    // no room at all (a minimised window): nothing to lay out - it lost the place, and opened at the chapter's
    // start afterwards (EPUB review R12)
    if (size.isEmpty) return;
    _size = size;
    if (b.size == size && b.theme == _theme) return;
    // still opening (the saved place not shown yet): the saved place again, not what's on screen - the system bars
    // hiding right after opening change the size before it's shown (found on the tablet)
    final opening = _startFraction;
    if (opening != null) {
      b.setLayout(_theme, size);
      _bookWide = false;
      _counting = false;
      if (b.size != Size.zero) {
        WidgetsBinding.instance.addPostFrameCallback((_) => _show(_chapter, 0, fraction: opening));
      }
      return;
    }
    // the place being read: the anchor from the layout before, if nothing has moved since - not the start of the page
    // now on screen, which is earlier than the place, so each new size or setting walked back a little more
    // (Windows, build 79: two resizes and back, a page back)
    final keep = _book!.size == Size.zero ? null : (_anchor ?? b.positionOf(_chapter, _page));
    _anchor = keep;
    b.setLayout(_theme, size);
    _bookWide = false;
    _counting = false;
    // the same text stays in view: back to its chapter, its page found once laid out again (the first layout: the
    // opening shows the saved place itself - a "start of the chapter" here overrode it, found on the tablet)
    if (keep != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _show(keep.chapter, keep.position, relayout: true));
    }
  }

  /// The place being read through new layouts (window sizes, settings); let go of at any other move.
  EpubPosition? _anchor;

  void _onBook() {
    final b = _book;
    if (b == null || !mounted) return;
    if (SchedulerBinding.instance.schedulerPhase == SchedulerPhase.persistentCallbacks) {
      // told mid-build (a new layout is set while laying the screen out): after this frame
      WidgetsBinding.instance.addPostFrameCallback((_) => _onBook());
      return;
    }
    if (_bookWide && b.countChanges != _countChanges && b.counted && !_end) {
      // a chapter's number of pages changed after counting: the book's page numbers after it moved - back to the
      // same page (the page view kept its number, now another page - EPUB review R5)
      _countChanges = b.countChanges;
      final at = b.bookPage(_chapter, _page);
      if (at != null && _pc.hasClients && (_pc.page ?? 0).round() != at) _jumpView(at);
    }
    if (!_bookWide && b.counted && !_end) {
      // every chapter counted: the page view goes over the whole book, on the same page
      final at = b.bookPage(_chapter, _page)!;
      final old = _pc;
      _countChanges = b.countChanges;
      setState(() {
        _bookWide = true;
        _pc = PageController(initialPage: at);
        _scrub = null; // the slider's units change (thousandths -> pages): a scrub under way is let go (R11)
      });
      WidgetsBinding.instance.addPostFrameCallback((_) => old.dispose());
    } else {
      setState(() {});
    }
  }

  /// Shows chapter [chapter] at [position] (laying it out first).
  /// Chapter [i] laid out ahead (a neighbour, ready to turn into); a failure is the chapter's, shown when it's reached.
  /// Laid out a moment later, once the turn that called for it has finished sliding: laying a chapter out holds the
  /// screen up, and doing it mid-slide made the turn stutter (user, 2026-10-06).
  void _prefetch(int i) {
    final b = _book!;
    if (b.pagesNow(i) != null) return;
    _prefetchTimers.add(Timer(const Duration(milliseconds: 350), () {
      if (!mounted || _book != b) return;
      unawaited(b.pages(i).then<void>((_) {}, onError: (Object _) {}));
    }));
    _prefetchTimers.removeWhere((t) => !t.isActive);
  }

  final _prefetchTimers = <Timer>[];

  /// When the reader last turned a page: background counting waits while pages are being turned.
  DateTime _lastTurn = DateTime.fromMillisecondsSinceEpoch(0);
  bool get _turning => DateTime.now().difference(_lastTurn) < const Duration(milliseconds: 1200);

  /// The reader moved somewhere (contents, a link, the slider): shown, and saved once it settles.
  Future<void> _jump(int chapter, int position) async {
    _moved = true;
    await _show(chapter, position);
    _settled();
  }

  /// Shows chapter [chapter] at [position] - or at [fraction] of the way through it (a saved place).
  /// [relayout]: the place kept through a new layout ([_anchor] stays); any other show is a move of its own.
  Future<void> _show(int chapter, int position, {double? fraction, bool relayout = false}) async {
    if (!relayout) _anchor = null;
    final b = _book!;
    EpubTrace.instance.log('show chapter $chapter at ${fraction ?? position}');
    final List<EpubPage>? pages;
    try {
      pages = await b.pages(chapter);
    } catch (_) {
      // that chapter, showing why it can't be shown, with Retry (the book has the error) - not the page before, as if
      // nothing had happened
      if (mounted) {
        setState(() {
          _chapter = chapter;
          _page = 0;
          _end = false;
        });
        // the whole book in one page view: to that chapter's page, where its error and Retry show (the page view
        // stayed on the page before - EPUB review R2)
        final at = _bookWide ? b.bookPage(chapter, 0) : null;
        if (at != null && _pc.hasClients) _jumpView(at);
      }
      return;
    }
    if (!mounted || pages == null) return;
    if (fraction != null) position = (fraction * b.lengthOf(chapter)).round();
    final page = pageFor(pages, position);
    b.keepAround(chapter);
    setState(() {
      _chapter = chapter;
      _page = page;
      _end = false;
      if (fraction != null && fraction == _startFraction) _startFraction = null; // opened at the saved place
    });
    final target = _bookWide ? b.bookPage(chapter, page)! : page;
    if (_pc.hasClients) {
      _jumpView(target);
    } else {
      final old = _pc;
      setState(() => _pc = PageController(initialPage: target));
      WidgetsBinding.instance.addPostFrameCallback((_) => old.dispose());
    }
    if (!_counting) {
      _counting = true;
      unawaited(b.countAll(current: () => _chapter, busy: () => _turning));
    }
    // the neighbours ready for turning into
    if (chapter + 1 < b.chapterCount) _prefetch(chapter + 1);
    if (chapter > 0) _prefetch(chapter - 1);
  }

  // ---- turning

  int get _itemCount {
    final b = _book!;
    if (_bookWide) return b.totalPages! + 1; // + the end card
    final n = b.pagesNow(_chapter)?.length ?? 1;
    return _chapter == b.chapterCount - 1 ? n + 1 : n;
  }

  void _onPageChanged(int i) {
    if (!readerTiming) return _pageChanged(i);
    // timed (a measuring build): it runs mid-turn, where tap turns missed a refresh (tablet, build 77) - logged when
    // it takes 2 ms or more
    final clock = Stopwatch()..start();
    _pageChanged(i);
    final ms = clock.elapsedMicroseconds / 1000;
    if (ms >= 2) EpubTrace.instance.log('page change took ${ms.toStringAsFixed(1)} ms');
  }

  void _pageChanged(int i) {
    final b = _book!;
    if (!_ownJump) _anchor = null; // a turn: the page shown is the place now
    if (!_ownJump) _lastTurn = DateTime.now(); // (swipes too)
    EpubTrace.instance.log('page $i (${_bookWide ? 'book' : 'chapter $_chapter'})${_ownJump ? ' by the reader' : ''}');
    awake();
    if (_bookWide) {
      if (i >= b.totalPages!) {
        setState(() => _end = true);
        _reachedEnd();
        _endReached();
        return;
      }
      final (c, p) = b.chapterPage(i);
      if (c != _chapter) b.keepAround(c);
      setState(() {
        _chapter = c;
        _page = p;
        _end = false;
      });
      if (c + 1 < b.chapterCount) _prefetch(c + 1);
      if (c > 0) _prefetch(c - 1);
    } else {
      final n = b.pagesNow(_chapter)?.length ?? 0;
      setState(() {
        _end = i >= n;
        _page = math.min(i, math.max(0, n - 1));
      });
    }
    _flashCorner();
    if (_ownJump) return; // the reader moved the page itself: not the reader's turn (a jump saves via _jump)
    _moved = true;
    if (_end) {
      _reachedEnd();
      _endReached();
    } else {
      _settled();
    }
  }

  bool _ownJump = false;

  /// The reader's own move of the page view (opening, laid out again, a jump): not a turn - it saves nothing by itself.
  void _jumpView(int page) {
    _ownJump = true;
    _pc.jumpToPage(page);
    _ownJump = false;
  }

  int _countChanges = 0; // the book's countChanges this reader has gone along with
  bool _overscrolled = false; // this drag already turned past a chapter's end (R3)

  // A turn's slide: 320 ms, easing in and out. The old 220 ms ease-out moved the page ~150 px a frame at the start -
  // sharp text moving that far a frame reads as judder even at a full 60 fps (user, build 75: "not smooth in the way
  // that comics are"); this one peaks near 100 px.
  Duration get _turnTime =>
      AppSettings.instance.epub.turn == EpubTurn.none ? Duration.zero : const Duration(milliseconds: 320);
  static const _turnCurve = Curves.easeInOut;

  // the wheel: notches added up to a turn, at most one turn a quarter second (a spun wheel doesn't race through the
  // book) - as the comic reader's
  double _wheelAcc = 0;
  DateTime _lastWheelTurn = DateTime(0);

  void _onWheel(double dy) {
    if (_book == null) return;
    _wheelAcc += dy;
    if (_wheelAcc.abs() < 40) return;
    final forward = _wheelAcc > 0;
    _wheelAcc = 0;
    final now = DateTime.now();
    if (now.difference(_lastWheelTurn) < const Duration(milliseconds: 250)) return;
    _lastWheelTurn = now;
    unawaited(_turn(forward ? 1 : -1));
  }

  Future<void> _turn(int by) async {
    _lastTurn = DateTime.now();
    final b = _book;
    EpubTrace.instance.log('turn $by from chapter $_chapter page $_page');
    if (b == null) return;
    awake();
    if (!_bookWide) {
      final n = b.pagesNow(_chapter)?.length ?? 0;
      final next = _page + by;
      if (by > 0 && next >= n && !(_chapter == b.chapterCount - 1)) {
        await _jump(_chapter + 1, 0); // into the next chapter (by chapter until the book is counted) - a turn
        return;
      }
      if (by < 0 && next < 0) {
        if (_chapter > 0) await _jump(_chapter - 1, 1 << 30); // the previous chapter's last page
        return;
      }
    }
    // (a chapter that failed has no page view: turning leaves it through the chapter jumps above - EPUB review R2)
    if (!_pc.hasClients) return;
    final target = (_pc.page ?? 0).round() + by;
    if (target < 0 || target >= _itemCount) return;
    if (_turnTime == Duration.zero) {
      _pc.jumpToPage(target);
    } else {
      _sliding = true;
      try {
        await _pc.animateToPage(target, duration: _turnTime, curve: _turnCurve);
      } finally {
        _sliding = false;
      }
    }
  }

  /// A turn's slide is under way: a held key's repeats wait for it to end (each one restarted the slide at its
  /// slowest part, so a held key crept and never turned a page - user, build 82, Windows).
  bool _sliding = false;

  void _tap(TapUpDetails d, Size size, EpubPage? page) {
    // a link under the finger first (footnotes)
    for (final l in page?.links ?? const <EpubLink>[]) {
      if (l.rect.inflate(10).contains(d.localPosition)) {
        _openLink(l);
        return;
      }
    }
    final x = d.localPosition.dx / size.width;
    // a big picture tapped in the middle of the screen: full screen over the book (the sides still turn the page -
    // a picture can fill the page)
    if (!_controls && x >= 1 / 3 && x <= 2 / 3) {
      for (final (rect, image) in page?.pictures ?? const <(Rect, ui.Image)>[]) {
        if (rect.contains(d.localPosition)) {
          unawaited(_showPicture(image));
          return;
        }
      }
    }
    if (_controls) {
      _hideControls();
    } else if (x < 1 / 3) {
      _turn(-1);
    } else if (x > 2 / 3) {
      _turn(1);
    } else {
      _showControls();
    }
  }

  void _showControls() => setState(() {
        _controls = true;
        _scrub = null;
        _scrubber.remote = false;
      });

  void _hideControls() {
    _scrubber.release(); // a finger still on the slider: its scrub is let go of
    setState(() {
      _controls = false;
      _scrub = null;
      _scrubber.remote = false;
    });
    _focus.requestFocus();
  }

  // ---- the remote in the controls (the comic reader's model): Left / Right along a bar, Up / Down between the bars;
  // Up from the top bar or Down from the bottom one leaves them (OK then hides the controls); OK on a control presses it

  List<_Ctl> get _topBar => [_Ctl.close, if (isDesktop) _Ctl.fullscreen, _Ctl.read];
  List<_Ctl> get _bottomBar => [_Ctl.prevBook, _Ctl.slider, _Ctl.contents, _Ctl.settings, _Ctl.nextBook];

  void _move({int dx = 0, int dy = 0}) {
    final to = walkControls(
        top: [for (final c in _topBar) _ctl[c]!], bottom: [for (final c in _bottomBar) _ctl[c]!], dx: dx, dy: dy);
    switch (to) {
      case WalkToNode(:final node):
        node.requestFocus();
      case WalkToRow() || WalkOff():
        _focus.requestFocus();
    }
    setState(() {});
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent e) {
    if (e is! KeyDownEvent && e is! KeyRepeatEvent) return KeyEventResult.ignored;
    final k = e.logicalKey;
    if (_controls) return controlsKey(e, nothingSelected: _focus.hasPrimaryFocus, hide: _hideControls, move: _move);
    if (_end) return _onEndKey(e);
    if ((k == LogicalKeyboardKey.audioVolumeDown || k == LogicalKeyboardKey.audioVolumeUp) && hasVolumeKeys &&
        AppSettings.instance.display.volumeKeys) {
      if (e is KeyDownEvent) _turn(k == LogicalKeyboardKey.audioVolumeDown ? 1 : -1);
      return KeyEventResult.handled;
    }
    // a held key turns a page each time the slide before has ended, not on every repeat
    final repeatWhileSliding = e is KeyRepeatEvent && _sliding;
    // Shift+Space goes back, whatever Space is set to do (as in the comic reader)
    if (k == LogicalKeyboardKey.space && HardwareKeyboard.instance.isShiftPressed) {
      if (!repeatWhileSliding) _turn(-1);
      return KeyEventResult.handled;
    }
    switch (ReaderKeys.instance.actionFor(k)) {
      case ReaderAction.next:
        if (!repeatWhileSliding) _turn(1);
      case ReaderAction.previous:
        if (!repeatWhileSliding) _turn(-1);
      case ReaderAction.controls:
        if (e is KeyDownEvent) _showControls();
      case ReaderAction.close:
        if (e is KeyDownEvent) Navigator.of(context).maybePop();
      case ReaderAction.zoomIn || ReaderAction.zoomOut || null:
        return KeyEventResult.ignored;
    }
    return KeyEventResult.handled;
  }

  // ---- links, footnotes, contents

  Future<void> _openLink(EpubLink l) async {
    final b = _book!;
    if (l.href.contains('://')) return; // the web: not from the reader
    final hash = l.href.indexOf('#');
    final path = hash < 0 ? l.href : l.href.substring(0, hash);
    final frag = hash < 0 ? null : l.href.substring(hash + 1);
    // a footnote marker ("*", "[1]", a superscript number): the note in a pop-up, the page stays
    final marker = l.text.length <= 4 || RegExp(r'^[\[\(]?[0-9⁰¹²³⁴⁵⁶⁷⁸⁹*†‡§]+[\]\)]?$').hasMatch(l.text);
    if (marker && frag != null) {
      final note = await _noteText(path, frag);
      if (note != null && mounted) {
        await showDialog<void>(context: context, builder: (c) => AlertDialog(
          content: SingleChildScrollView(child: Text(note, style: const TextStyle(fontSize: 16, height: 1.4))),
          actions: [TextButton(onPressed: () => Navigator.pop(c), child: const Text('Close'))],
        ));
        return;
      }
    }
    final ch = b.chapterOf(path);
    if (ch == null) return;
    await _jump(ch, frag == null ? 0 : await _fragmentOr0(b, ch, frag));
  }

  /// Where [fragment] is in chapter [ch] - or its start if that can't be found out (the chapter couldn't be
  /// fetched): the link still goes somewhere, it used to do nothing at all (EPUB review R13).
  Future<int> _fragmentOr0(EpubBook b, int ch, String fragment) async {
    try {
      return await b.positionOfFragment(ch, fragment);
    } catch (_) {
      return 0;
    }
  }

  /// A picture full screen over the book, fitted to the screen (user, 2026-10-06: "a lightbox style view"): pinch
  /// or wheel to zoom, a tap, Back or Esc closes it. Drawn from its own handle on the picture, so the chapter being
  /// let go of meanwhile can't free it from under the view.
  Future<void> _showPicture(ui.Image image) async {
    // the view owns this handle and lets it go when it's gone - after its fade-out, not when the dialog's future
    // completes (the picture is still drawn while it fades)
    final own = image.clone();
    await showGeneralDialog<void>(
      context: context,
      barrierDismissible: true,
      barrierLabel: 'Close',
      barrierColor: Colors.black.withValues(alpha: 0.92),
      transitionDuration: const Duration(milliseconds: 150),
      pageBuilder: (c, _, __) => _PictureView(image: own),
      transitionBuilder: (c, a, _, child) => FadeTransition(opacity: a, child: child),
    );
  }

  static String text0(XElement e) => e.children.map((n) => n is XText ? n.text : text0(n as XElement)).join();

  /// The text of the note with id [frag] in [path]: its paragraph (or the element holding it).
  Future<String?> _noteText(String path, String frag) async {
    try {
      final root = parseXhtml(utf8.decode(await _book!.resource(path), allowMalformed: true));
      XElement? find(XElement e) {
        for (final c in e.elements) {
          if (c.id == frag) return c;
          final f = find(c);
          if (f != null) return f;
        }
        return null;
      }
      var el = find(root);
      if (el == null) return null;
      // an anchor inside the note: the paragraph around it
      while (el!.parent != null && const {'a', 'span', 'sup'}.contains(el.name)) {
        el = el.parent;
      }
      // the note's own marker linking back to the page ("*", "[1]") left out
      bool backLink(XElement e) => e.name == 'a' && e.attr('href') != null && text0(e).trim().length <= 4;
      String text(XElement e) => e.children
          .map((n) => n is XText ? n.text : (backLink(n as XElement) ? '' : text(n)))
          .join();
      final t = text(el).replaceAll(RegExp(r'\s+'), ' ').trim();
      return t.isEmpty ? null : t;
    } catch (_) {
      return null;
    }
  }

  Future<void> _contents() async {
    final b = _book!;
    final toc = b.info.toc;
    TocEntry? picked;
    // the comic reader's panel look (user, 2026-10-06): a side sheet on a wide screen, a bottom sheet on a narrow one
    await showReaderPanelFrame(context, title: 'Contents', children: (c, _) => [
          if (toc.isEmpty) const Padding(padding: EdgeInsets.all(14), child: Text('This book has no table of contents')),
          for (final t in toc)
            ListTile(
              dense: true,
              contentPadding: EdgeInsets.only(left: 4 + 18.0 * t.depth, right: 4),
              title: Text(t.title.isEmpty ? '(untitled)' : t.title,
                  style: TextStyle(fontSize: 15, fontWeight: b.chapterOf(t.path) == _chapter
                      ? FontWeight.bold
                      : FontWeight.normal)),
              onTap: () {
                picked = t;
                Navigator.of(c).pop();
              },
            ),
        ]);
    final chosen = picked;
    if (chosen == null || !mounted) return;
    await _jumpTo(b, chosen);
  }

  Future<void> _jumpTo(EpubBook b, TocEntry picked) async {
    final ch = b.chapterOf(picked.path);
    if (ch == null) return;
    final hash = picked.href.indexOf('#');
    _hideControls(); // (the remote's focus back on the page, as any other way of hiding them)
    await _jump(ch, hash < 0 ? 0 : await _fragmentOr0(b, ch, picked.href.substring(hash + 1)));
  }

  /// The Aa panel: the EPUB settings while reading; the page changes behind it as they're set.
  Future<void> _settingsPanel() async {
    // the comic reader's panel look: the page stays in view beside it (wide) or above it (narrow), changing live;
    // the controls stay up behind it, as with comics. This device's reading settings below the book's, as in the
    // comic reader's panel (user, 2026-10-06: the panels as the comics')
    await showReaderPanelFrame(context, title: 'Text and page', children: (c, s) => [
          ...epubSettingRows(c, s.epub, s.setEpub),
          SettingsGroup(title: 'This device', children: [
            ...brightnessRows(s, compact: true),
            ...nightRows(s),
            if (canRotate) rotationRow(s),
            screenOnRow(s),
          ]),
        ]);
  }

  // ---- what's shown

  /// The chapter's name from the contents (the last entry for its file), else "Chapter N of M".
  /// The chapter's name from the contents (the last entry for its file), else "Chapter N of M".
  String _chapterNameOf(int chapter) {
    final b = _book!;
    final path = b.info.spine[chapter];
    final named = b.info.toc.where((t) => t.path == path && t.title.isNotEmpty);
    return named.isEmpty ? 'Chapter ${chapter + 1} of ${b.chapterCount}' : named.first.title;
  }

  /// Where chapter [chapter]'s page [page] is (option F, user 2026-10-06): the book's page and % ("Book · Pg. 112/342 ·
  /// 33%"; just the % until the book is counted), the chapter's name, and the chapter's page ("Ch. 7 · Pg. 4/12";
  /// the chapter counted as the book's files run, as everywhere in the reader).
  (String book, String title, String inChapter) _positionOf(int chapter, int page) {
    final b = _book!;
    final pct = (b.progression(b.positionOf(chapter, page)) * 100).round();
    final at = b.bookPage(chapter, page);
    final total = b.totalPages;
    final n = b.pageCount(chapter);
    return (
      at != null && total != null ? 'Book · Pg. ${at + 1}/$total · $pct%' : 'Book · $pct%',
      _chapterNameOf(chapter),
      'Ch. ${chapter + 1} · Pg. ${page + 1}${n == null ? '' : '/$n'}',
    );
  }

  /// The page corner (option H): pages left in the chapter and the book's %.
  String get _cornerText {
    final b = _book!;
    final pct = (b.progression(b.positionOf(_chapter, _page)) * 100).round();
    final n = b.pageCount(_chapter);
    if (n == null) return '$pct%';
    final left = n - _page - 1;
    return '${left <= 0 ? 'End of chapter' : '$left left in chapter'} · $pct%';
  }

  // the corner note "After a turn": shown for a moment after each turn
  bool _cornerFlash = false;
  Timer? _cornerTimer;

  void _flashCorner() {
    if (AppSettings.instance.display.pageNote != PageNote.afterTurn) return;
    _cornerTimer?.cancel();
    setState(() => _cornerFlash = true);
    _cornerTimer = Timer(const Duration(milliseconds: 2500), () {
      if (mounted) setState(() => _cornerFlash = false);
    });
  }

  Widget _pageAt(int i, Size size) {
    final b = _book!;
    final theme = _theme;
    int c, p;
    if (_bookWide) {
      if (i >= b.totalPages!) return _endCard(theme);
      (c, p) = b.chapterPage(i);
    } else {
      final n = b.pagesNow(_chapter)?.length ?? 0;
      if (i >= n) return _endCard(theme);
      (c, p) = (_chapter, i);
    }
    final pages = b.pagesNow(c);
    if (pages == null) {
      if (b.errorOf(c) != null) return _chapterError(b, c, theme);
      // the page on screen: laid out now (a failure shows here, with Retry); a neighbour built ahead (implicit
      // scrolling): after the usual pause, so its layout doesn't land in the next turn
      final onScreen = !_pc.hasClients || _pc.page == null || _pc.page!.round() == i;
      if (onScreen) {
        unawaited(b.pages(c).then<void>((_) {}, onError: (Object _) {}));
      } else {
        _prefetch(c);
      }
      return ColoredBox(color: theme.background, child: const Center(child: CircularProgressIndicator()));
    }
    return CustomPaint(size: size, painter: _PagePainter(pages[p.clamp(0, pages.length - 1)], theme.background));
  }

  /// A chapter that couldn't be loaded or laid out: why, and Retry (never a spinner for good).
  /// [bare]: without the page's background (over the reader's tap layer, which has its own under it).
  Widget _chapterError(EpubBook b, int chapter, EpubTheme theme, {bool bare = false}) {
    final e = b.errorOf(chapter)!;
    final message = Center(child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          ErrorText(couldnt('show this chapter', e, thing: 'book'), e, centre: true),
          const SizedBox(height: 16),
          FilledButton.icon(
            onPressed: () {
              b.retry(chapter);
              unawaited(_show(chapter, b.positionOf(chapter, chapter == _chapter ? _page : 0).position));
            },
            icon: const Icon(Icons.refresh),
            label: const Text('Retry'),
          ),
        ]),
      ));
    return bare ? message : ColoredBox(color: theme.background, child: message);
  }

  /// Chapter by chapter (the book not counted yet), a swipe pulled past the chapter's last page - or before its
  /// first - goes on to the next (previous) chapter, once per swipe: the page view only holds this chapter, and
  /// the swipe did nothing (taps, keys and the wheel went on - EPUB review R3).
  bool _onScroll(ScrollNotification n) {
    if (n is ScrollStartNotification) _overscrolled = false;
    if (n is OverscrollNotification && !_bookWide && !_overscrolled && n.dragDetails != null && n.overscroll != 0) {
      _overscrolled = true;
      unawaited(_turn(n.overscroll > 0 ? 1 : -1));
    }
    return false;
  }

  // ---- the end card: the next book's poster and title (the comic reader's, user 2026-10-06), Next book and Close -
  // both reachable with the remote

  final _endNext = FocusNode(debugLabel: 'epub-end-next');
  final _endClose = FocusNode(debugLabel: 'epub-end-close');
  Future<Map<String, dynamic>?>? _upNextFuture;

  /// What comes after this book (looked up once; a lookup that failed is asked again by Next book).
  Future<Map<String, dynamic>?> get _upNext => _upNextFuture ??= _nextFrom(widget.book['id'] as String);

  /// The book after [id] in the read list it was opened from, else the series - with read books hidden, the next one
  /// not read yet.
  Future<Map<String, dynamic>?> _nextFrom(String id) async {
    var next = await widget.api.nextBook(id, readListId: widget.readListId);
    for (var hops = 0; widget.skipRead && next != null && _isRead(next) && hops < 500; hops++) {
      next = await widget.api.nextBook(next['id'] as String, readListId: widget.readListId);
    }
    return next;
  }

  static bool _isRead(Map<String, dynamic> book) => book['readProgress']?['completed'] == true;

  String get _where => widget.readListId != null ? 'this read list' : 'the series';

  /// The end card is reached: the remote on Next book (on Close when there's none).
  void _endReached() {
    _upNext.then((next) {
      if (mounted && _end) (next == null ? _endClose : _endNext).requestFocus();
    }, onError: (Object _) {
      if (mounted && _end) _endClose.requestFocus();
    });
  }

  /// Keys on the end card: Right (next page) goes on to the next book - a fresh press, a held key's repeats don't -
  /// or closes when there's none; Up / Down move between Next book and Close; OK presses the one the remote is on;
  /// Left (previous page) goes back to the last page.
  KeyEventResult _onEndKey(KeyEvent e) {
    final k = e.logicalKey;
    if (k == LogicalKeyboardKey.arrowUp || k == LogicalKeyboardKey.arrowDown) {
      final to = k == LogicalKeyboardKey.arrowUp ? _endNext : _endClose;
      if (to.context != null) to.requestFocus();
      return KeyEventResult.handled;
    }
    if (isOkKey(k)) {
      if (e is KeyDownEvent) _endClose.hasFocus ? Navigator.of(context).maybePop() : _nextOrClose();
      return KeyEventResult.handled;
    }
    switch (ReaderKeys.instance.actionFor(k)) {
      case ReaderAction.next:
        if (e is KeyDownEvent) _nextOrClose();
        return KeyEventResult.handled;
      case ReaderAction.previous:
        _focus.requestFocus();
        _turn(-1);
        return KeyEventResult.handled;
      case ReaderAction.close:
        if (e is KeyDownEvent) Navigator.of(context).maybePop();
        return KeyEventResult.handled;
      default:
        return KeyEventResult.ignored;
    }
  }

  /// Next book - or, when there's none, close.
  Future<void> _nextOrClose() async {
    Map<String, dynamic>? next;
    try {
      next = await _upNext;
    } catch (_) {
      next = const {}; // couldn't look it up: Next book tries again (and says why if it can't)
    }
    if (!mounted) return;
    next == null ? await Navigator.of(context).maybePop() : await _nextBook();
  }

  Widget _endCard(EpubTheme theme) {
    final ink = theme.text;
    final dim = TextStyle(color: ink.withValues(alpha: 0.55));
    return ColoredBox(
      color: theme.background,
      child: Center(child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Theme(
          data: readerControlsTheme(context),
          child: FutureBuilder<Map<String, dynamic>?>(
            future: _upNext,
            builder: (context, snap) {
              final next = snap.data;
              final waiting = snap.connectionState != ConnectionState.done;
              final offline = snap.error is NotAvailableOffline;
              final number = next?['metadata']?['number'] ?? next?['number'];
              final nextTitle = (next?['metadata']?['title'] ?? next?['name']) as String?;
              final heading = next == null ? '' : '${next['seriesTitle'] ?? ''} #$number'.trim();
              final canGoOn = !waiting && (next != null || (snap.hasError && !offline));
              return Column(mainAxisSize: MainAxisSize.min, children: [
                Text('The End', style: TextStyle(color: ink, fontSize: 28)),
                const SizedBox(height: 6),
                Text(_title, textAlign: TextAlign.center, style: TextStyle(color: ink.withValues(alpha: 0.7))),
                const SizedBox(height: 28),
                if (waiting)
                  const SizedBox(width: 28, height: 28, child: CircularProgressIndicator(strokeWidth: 2))
                else if (next != null) ...[
                  Text(widget.skipRead ? 'Next unread in $_where' : 'Up next in $_where', style: dim),
                  const SizedBox(height: 12),
                  Builder(builder: (context) {
                    final h = (MediaQuery.sizeOf(context).height * 0.38).clamp(160.0, 480.0);
                    return NativePoster(widget.api.thumbImage(widget.api.bookThumb(next['id'] as String)),
                        max: Size(h * 0.8, h));
                  }),
                  const SizedBox(height: 14),
                  Text(heading, textAlign: TextAlign.center, style: TextStyle(color: ink, fontSize: 18)),
                  if (nextTitle != null && nextTitle != heading && !nextTitle.endsWith('#$number'))
                    Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: Text(nextTitle, textAlign: TextAlign.center, maxLines: 2, overflow: TextOverflow.ellipsis,
                          style: TextStyle(color: ink.withValues(alpha: 0.7))),
                    ),
                ] else if (offline)
                  Text("The next book in $_where isn't downloaded", textAlign: TextAlign.center, style: dim)
                else if (!snap.hasError)
                  Text(_lastText, textAlign: TextAlign.center, style: dim),
                const SizedBox(height: 22),
                if (canGoOn)
                  FilledButton.icon(
                    focusNode: _endNext,
                    onPressed: _nextBook,
                    icon: const Icon(Icons.skip_next),
                    label: const Text('Next book'),
                  ),
                const SizedBox(height: 8),
                TextButton(focusNode: _endClose, onPressed: () => Navigator.of(context).maybePop(),
                    child: const Text('Close')),
              ]);
            },
          ),
        ),
      )),
    );
  }

  /// Next book. From the end card the book is marked read; before it, as Settings > Reader says for comics ("Next
  /// book before the last page": ask, mark read, or keep it in progress). The next book opens in its own reader.
  Future<void> _nextBook() async {
    var markRead = _end || AppSettings.instance.display.midBook == MidBook.markRead;
    if (!_end && AppSettings.instance.display.midBook == MidBook.ask) {
      final pct = (_book!.progression(_book!.positionOf(_chapter, _page)) * 100).round();
      final answer = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text('Mark "$_title" as read?'),
          content: Text("You're $pct% of the way through."),
          actions: [
            TextButton(autofocus: true, onPressed: () => Navigator.pop(ctx, false), child: const Text('Keep in progress')),
            TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Mark read')),
          ],
        ),
      );
      if (answer == null || !mounted) return; // dismissed: stay
      markRead = answer;
    }
    try {
      if (markRead) {
        await _markBook(read: true); // read: closing doesn't save a place over it
      } else {
        _saveNow();
      }
      final Map<String, dynamic>? next;
      try {
        next = await _upNext; // the end card's answer, not asked again
      } catch (_) {
        _upNextFuture = null; // asked again next time
        rethrow;
      }
      if (!mounted) return;
      if (next == null) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(_lastText)));
        return;
      }
      await Navigator.of(context).pushReplacement(MaterialPageRoute(
          builder: (_) => readerFor(widget.api, next, readListId: widget.readListId, skipRead: widget.skipRead)));
    } catch (e, st) {
      if (mounted) showErrorSnack(context, couldnt('open the next book', e, thing: 'book'), e, st);
    }
  }

  /// Previous book (nothing marked; this one's place kept), in its own reader.
  Future<void> _prevBook() async {
    _saveNow();
    try {
      var prev = await widget.api.previousBook(widget.book['id'] as String, readListId: widget.readListId);
      for (var hops = 0; widget.skipRead && prev != null && _isRead(prev) && hops < 500; hops++) {
        prev = await widget.api.previousBook(prev['id'] as String, readListId: widget.readListId);
      }
      if (!mounted) return;
      if (prev == null) {
        final where = widget.readListId != null ? 'read list' : 'series';
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(widget.skipRead
            ? 'No unread books before this one in the $where'
            : 'This is the first book of the $where')));
        return;
      }
      final open = prev;
      await Navigator.of(context).pushReplacement(MaterialPageRoute(
          builder: (_) => readerFor(widget.api, open, readListId: widget.readListId, skipRead: widget.skipRead)));
    } catch (e, st) {
      if (mounted) showErrorSnack(context, couldnt('find the previous book', e, thing: 'book'), e, st);
    }
  }

  String get _lastText => switch ((widget.readListId != null, widget.skipRead)) {
        (true, true) => 'No unread books left in the read list',
        (true, false) => 'That was the last book in the read list',
        (false, true) => 'No unread books left in the series',
        (false, false) => 'That was the last book in the series',
      };

  bool get _completed => _bookNow['readProgress']?['completed'] == true || _markedRead;

  /// The top bar's Mark read / Mark unread (as the comic reader's).
  Future<void> _toggleRead() async {
    final id = widget.book['id'] as String;
    final read = _completed;
    try {
      await _markBook(read: !read);
      _markedRead = !read;
      final fresh = await widget.api.book(id).catchError((Object _) => null);
      if (mounted) setState(() => _bookNow = fresh ?? _bookNow);
    } catch (e, st) {
      if (mounted) {
        showErrorSnack(context, couldnt('mark "$_title" as ${read ? 'unread' : 'read'}', e, thing: 'book'), e, st);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final b = _book;
    final theme = _theme;
    if (_error != null) {
      return Scaffold(appBar: AppBar(title: Text(_title)), body: Padding(
        padding: const EdgeInsets.all(24),
        child: Center(child: ErrorText(couldnt('open this book', _error!, thing: 'book'), _error!, centre: true)),
      ));
    }
    if (b == null) {
      return Scaffold(backgroundColor: theme.background, body: const Center(child: CircularProgressIndicator()));
    }
    final display = AppSettings.instance.display;
    return PopScope(
      // Back (tablet or remote) closes the controls first, then the book - as in the comic reader
      canPop: !_controls,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _hideControls();
      },
      child: Focus(
        focusNode: _focus,
        autofocus: true,
        onKeyEvent: _onKey,
        child: Scaffold(
          backgroundColor: theme.background,
          body: LayoutBuilder(builder: (context, box) {
            final size = box.biggest;
            _layout(size);
            final failed = b.pagesNow(_chapter) == null && b.errorOf(_chapter) != null;
            // the whole book in one page view: a chapter not laid out yet waits as a page of it (the page view lays
            // it out) - replacing the page view opened it at its first page, turning back into it (EPUB review R1)
            if (b.pagesNow(_chapter) == null && !failed && !_bookWide) {
              // laid out afresh (a new size or setting): to the place kept through it, as [_layout] does - not the
              // chapter's start, which raced it (and let go of the place)
              final anchor = _anchor;
              unawaited(anchor != null && anchor.chapter == _chapter
                  ? _show(anchor.chapter, anchor.position, relayout: true)
                  : _show(_chapter, 0, fraction: _startFraction));
              return const Center(child: CircularProgressIndicator());
            }
            final pages = b.pagesNow(_chapter) ?? const <EpubPage>[];
            final shown = _end || pages.isEmpty ? null : pages[_page.clamp(0, pages.length - 1)];
            // a chapter that failed (chapter by chapter): its error where the page goes - the controls, the taps and
            // the turns stay (it took the whole screen: only Retry and Close - EPUB review R2)
            final errorHere = failed && !_bookWide;
            return Stack(children: [
              if (errorHere) Positioned.fill(child: ColoredBox(color: theme.background))
              else NotificationListener<ScrollNotification>(
                onNotification: _onScroll,
                child: PageView.builder(
                key: ValueKey(_bookWide),
                controller: _pc,
                itemCount: _itemCount,
                onPageChanged: _onPageChanged,
                // the pages either side built ahead, as the comic reader's are: a tap's turn no longer builds the
                // incoming page in its first frame (most tap turns missed one refresh there - measured on the
                // tablet, build 76; swipes and comics didn't)
                allowImplicitScrolling: true,
                // each page drawn once and kept as a picture: sliding moves it, rather than drawing every line
                // of both pages again each frame
                itemBuilder: (_, i) => RepaintBoundary(child: _pageAt(i, size)),
              )),
              // the mouse wheel turns pages, as with comics (the page view scrolls sideways: it lets a vertical wheel
              // by - Windows check, build 79)
              Positioned.fill(child: Listener(
                behavior: HitTestBehavior.translucent,
                onPointerSignal: (e) {
                  if (e is PointerScrollEvent && !HardwareKeyboard.instance.isControlPressed) {
                    GestureBinding.instance.pointerSignalResolver
                        .register(e, (ev) => _onWheel((ev as PointerScrollEvent).scrollDelta.dy));
                  }
                },
                child: const SizedBox.expand(),
              )),
              Positioned.fill(child: GestureDetector(
                behavior: HitTestBehavior.translucent,
                onTapUp: (d) => _tap(d, size, shown),
                onSecondaryTap: () => _controls ? _hideControls() : _showControls(), // right-click, as with comics
              )),
              // (above the taps: Retry takes its own; the rest of the screen still turns and shows the controls)
              if (errorHere) Positioned.fill(child: _chapterError(b, _chapter, theme, bare: true)),
              // Clock and battery, Always: top right while the controls are hidden (with them up it's on the top bar)
              if (!_controls && display.clock == ShowWhen.always)
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
              // the page corner (option H): quiet, in the page's own colour, bottom right
              if (!_controls && !_end && AppSettings.instance.display.pageNote != PageNote.off)
                Positioned(
                  right: math.max(12, theme.margins.right - 4),
                  bottom: 8,
                  child: IgnorePointer(
                    child: AnimatedOpacity(
                      opacity: AppSettings.instance.display.pageNote == PageNote.always || _cornerFlash ? 1 : 0,
                      duration: const Duration(milliseconds: 250),
                      child: Text(_cornerText, key: const ValueKey('epub-corner'),
                          style: TextStyle(color: theme.text.withValues(alpha: 0.5), fontSize: 12,
                              fontFeatures: const [FontFeature.tabularFigures()])),
                    ),
                  ),
                ),
              // Progress bar (Settings > Reader, as for comics): a thin line along the bottom while the controls are
              // hidden - through the book
              if (!_controls && display.progressBar && !_end)
                Positioned(
                  left: 0,
                  right: 0,
                  bottom: 0,
                  height: 3,
                  child: IgnorePointer(
                    child: LinearProgressIndicator(
                      key: const ValueKey('reading-progress'),
                      value: b.progression(b.positionOf(_chapter, _page)),
                      minHeight: 3,
                      backgroundColor: theme.text.withValues(alpha: 0.12),
                      color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.85),
                    ),
                  ),
                ),
              if (_controls) ..._controlsOver(b),
            ]);
          }),
        ),
      ),
    );
  }

  // ---- the controls: the comic reader's bars (user, 2026-10-06: "it still looks disjointed from the comics")

  final _scrubber = SliderScrub(); // the place picked on the slider, shown as it moves (lib/reader/reader_slider.dart)
  int? get _scrub => _scrubber.value;
  set _scrub(int? v) => _scrubber.value = v;

  /// The slider always runs through the whole book (user, 2026-10-06: it ran through the chapter until the book
  /// was counted, so it couldn't go far): by page once the book is counted, by thousandths of the book till then.
  static const _steps = 1000;
  bool get _byPage => _book!.totalPages != null && _book!.bookPage(_chapter, _page) != null;

  (int at, int last) get _sliderRange {
    final b = _book!;
    if (_byPage) return (b.bookPage(_chapter, _page)!, math.max(0, b.totalPages! - 1));
    return ((b.progression(b.positionOf(_chapter, _page)) * _steps).round(), _steps);
  }

  /// Slider place [i] as (chapter, page) - by thousandths: the page of the chapter it falls in, as far as it's known.
  (int, int) _sliderPage(int i) {
    final b = _book!;
    if (_byPage) return b.chapterPage(i);
    final (c, within) = b.chapterAtFraction(i / _steps);
    return (c, b.pageAt(c, (within * b.lengthOf(c)).round()));
  }

  /// The page picked on the slider while the reader goes there: the slider and the counter stay on it - they showed
  /// the page left for a moment, then the new one, the slider jumping (user, build 70).
  int? _seeking;

  void _sliderJump(int i) {
    final (at, _) = _sliderRange;
    if (i == at) return;
    setState(() => _seeking = i);
    final Future<void> going;
    if (_byPage) {
      final (c, p) = _sliderPage(i);
      going = _jump(c, _book!.positionOf(c, p).position);
    } else {
      // a chapter not counted yet: gone to by how far through it, laid out on the way
      final (c, within) = _book!.chapterAtFraction(i / _steps);
      _moved = true;
      going = _show(c, 0, fraction: within).then((_) => _settled());
    }
    unawaited(going.whenComplete(() {
      if (mounted && _seeking == i) setState(() => _seeking = null);
    }));
  }

  Widget _slider() {
    final (at, last) = _sliderRange;
    return ReaderSlider(
      node: _ctl[_Ctl.slider]!,
      scrub: _scrubber,
      shown: _scrub ?? _seeking ?? at,
      at: at,
      last: last,
      step: _byPage ? 1 : _steps ~/ 100, // by thousandths: a press is 1% of the book
      onJump: _sliderJump,
      changed: () => setState(() {}),
    );
  }

  List<Widget> _controlsOver(EpubBook b) {
    final accent = Theme.of(context).colorScheme.primary;
    final (at, _) = _sliderRange;
    final picked = _scrub ?? _seeking;
    final (sc, sp) = _sliderPage(picked ?? at);
    final (bookAt, title, inChapter) = picked == null ? _positionOf(_chapter, _page) : _positionOf(sc, sp);
    final numbers = TextStyle(color: picked != null ? accent : Colors.white70, fontSize: 13,
        fontFeatures: const [FontFeature.tabularFigures()]);
    final series = _bookNow['seriesTitle'] as String?;
    final number = _bookNow['metadata']?['number'];
    final completed = _completed;
    // the shared bars (lib/reader/reader_bars.dart) with the EPUB reader's buttons
    return readerBars(
      top: ReaderTopBar(
        closeNode: _ctl[_Ctl.close]!,
        heading: series != null && series.isNotEmpty ? '$series${number == null ? '' : ' #$number'}' : null,
        title: _title,
        buttons: [
          if (isDesktop) fullscreenButton(_ctl[_Ctl.fullscreen]!),
          barIcon(node: _ctl[_Ctl.read]!, icon: completed ? Icons.check_circle : Icons.check_circle_outline,
              label: completed ? 'Mark unread' : 'Mark read', onPressed: _toggleRead),
        ],
      ),
      bottom: ReaderBottomBar(
        prevNode: _ctl[_Ctl.prevBook]!,
        onPrev: _prevBook,
        nextNode: _ctl[_Ctl.nextBook]!,
        onNext: _nextBook,
        middle: [
          // option F (user, 2026-10-06): the chapter's name over the slider, the book's page and % at the
          // left, the chapter's page at the right - of the page picked while the slider moves
          Expanded(
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                child: Row(children: [
                  Expanded(
                    flex: 2,
                    child: Text(bookAt, key: const ValueKey('epub-book-position'), style: numbers,
                        maxLines: 1, overflow: TextOverflow.ellipsis),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    flex: 3,
                    child: Text(title, key: const ValueKey('epub-chapter-title'), maxLines: 1,
                        overflow: TextOverflow.ellipsis, textAlign: TextAlign.center,
                        style: TextStyle(color: picked != null ? accent : Colors.white, fontSize: 14)),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    flex: 2,
                    child: Text(inChapter, key: const ValueKey('epub-chapter-position'), style: numbers,
                        maxLines: 1, overflow: TextOverflow.ellipsis, textAlign: TextAlign.right),
                  ),
                ]),
              ),
              _slider(),
            ]),
          ),
        ],
        buttons: [
          barIcon(node: _ctl[_Ctl.contents]!, icon: Icons.toc, label: 'Contents', onPressed: _contents),
          barIcon(node: _ctl[_Ctl.settings]!, icon: Icons.text_fields, label: 'Text and page settings',
              onPressed: _settingsPanel),
        ],
      ),
    );
  }
}

/// The picture full screen: fitted to the screen (enlarged if small), pinch or wheel to zoom; a tap, Back, Esc or OK
/// closes it.
class _PictureView extends StatefulWidget {
  const _PictureView({required this.image});
  final ui.Image image; // its own handle: let go of with the view

  @override
  State<_PictureView> createState() => _PictureViewState();
}

class _PictureViewState extends State<_PictureView> {
  @override
  void dispose() {
    widget.image.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Focus(
        autofocus: true,
        onKeyEvent: (_, e) {
          if (e is! KeyDownEvent) return KeyEventResult.ignored;
          final k = e.logicalKey;
          if (k == LogicalKeyboardKey.escape || k == LogicalKeyboardKey.enter || k == LogicalKeyboardKey.select ||
              k == LogicalKeyboardKey.numpadEnter) {
            Navigator.of(context).pop();
            return KeyEventResult.handled;
          }
          return KeyEventResult.ignored;
        },
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () => Navigator.of(context).pop(),
          child: SafeArea(
            child: InteractiveViewer(
              maxScale: 6,
              child: SizedBox.expand(
                child: RawImage(image: widget.image, fit: BoxFit.contain, filterQuality: FilterQuality.medium),
              ),
            ),
          ),
        ),
      );
}

class _PagePainter extends CustomPainter {
  _PagePainter(this.page, this.background);
  final EpubPage page;
  final Color background;
  @override
  void paint(Canvas c, Size size) {
    c.drawRect(Offset.zero & size, Paint()..color = background);
    for (final p in page.pieces) {
      p.paint(c);
    }
  }

  @override
  bool shouldRepaint(_PagePainter old) => old.page != page || old.background != background;
}
