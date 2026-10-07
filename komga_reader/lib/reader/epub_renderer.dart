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
import '../epub/count_store.dart';
import '../epub/hyphenator.dart';
import '../epub/layout.dart';
import '../epub/progress.dart';
import '../epub/source.dart';
import '../epub/trace.dart';
import '../epub/xhtml.dart';
import '../errors.dart';
import '../offline/offline_komga.dart';
import '../screen.dart';
import '../settings.dart';
import '../widgets/display_panel.dart';
import '../widgets/epub_settings.dart';
import '../widgets/error_text.dart';
import '../widgets/setting_rows.dart';
import 'position_row.dart';
import 'reader_bars.dart';
import 'renderer.dart';

/// An EPUB ready to show (from [EpubRenderer.prepare]).
class _Prepared {
  _Prepared(this.book, this.startChapter, this.startFraction, this.known);
  final EpubBook book;
  final int startChapter;
  final double? startFraction;
  final EpubKomgaPlace? known;
}

/// The EPUB renderer (the one Reader, user 2026-10-07; the EPUB plan: reports\epub-plan-2026-10-06.md): the book laid
/// out by the app itself (lib/epub/) and shown once every page is counted (a spinner with the chapter counted till
/// then; counts remembered per book and layout); the page view over the whole book and its slide; links, footnotes
/// and pictures; the Contents and Aa panels on the Reader's bottom bar. The Reader around it does the rest.
///
/// Places are the book's pages, 0..[last]; [last] + 1 is the end card.
class EpubRenderer extends Renderer {
  EpubRenderer(super.host, {this.source, this.saves = true}) {
    if (readerTiming) SchedulerBinding.instance.addTimingsCallback(_onFrames); // a measuring build only
  }

  /// Where the first book's files come from (tests: from memory); others: Komga, or the downloaded file offline.
  final EpubSource? source;

  /// Progress is loaded and saved (tests showing a book from memory: not).
  final bool saves;

  static Hyphenators? _hyphenators; // loaded once (the value, not the future: a future is tied to where it began)

  /// The page's left / right margin at [width]: the setting's, or more on a wide screen, where lines stop at the
  /// setting's length ([EpubMargins.lineEms]) and the rest goes to the margins.
  static double sideMargin(EpubPrefs e, double width) =>
      math.max(e.margins.side, (width - e.size * e.margins.lineEms) / 2);

  /// Where book [id]'s files come from: offline, a downloaded EPUB's file (its progress kept on the device, sent to
  /// Komga later); else Komga.
  static EpubSource sourceFor(Komga api, String id) {
    final file = api is OfflineKomga ? api.epubFile(id) : null;
    return file != null ? FileEpubSource(file) : KomgaEpubSource(api, id);
  }

  EpubBook? _book;
  Map _record = const {}; // the book as Komga lists it
  EpubProgress? _progress;
  EpubKomgaPlace? _openedKnown;
  int _chapter = 0; // the chapter shown
  int _page = 0; // its page
  bool _end = false; // on the end card
  PageController _pc = PageController();
  bool _disposed = false;

  // the book is counted in this layout and the place shown: until then a spinner covers it, with the chapters
  // counted (user, 2026-10-07: "a second or two on open ... avoids a bunch of oddness and complexity")
  bool _ready = false;
  double? _startFraction; // the saved place in the opening chapter, 0..1 (till it's shown)

  void _changed() {
    if (!_disposed) notifyListeners();
  }

  @override
  bool get savesProgress => saves;
  @override
  bool get opened => _book != null;
  @override
  bool get ready => _ready;
  @override
  Map get book => _record;
  @override
  void bookChanged(Map book) => _record = book;

  // ---- places: the book's pages, the end card after them

  @override
  int get place => _book == null || !_ready ? 0 : (_end ? _book!.totalPages! : _book!.bookPage(_chapter, _page)!);
  @override
  int get last => _book?.totalPages == null ? 0 : _book!.totalPages! - 1;
  @override
  int openedAt = 0;
  @override
  bool get sliding => _sliding;

  // ---- the look: the EPUB settings (synced; the Aa panel)

  Size _size = Size.zero; // the page area, from the last layout

  /// The book's look: font, size, spacing, margins, theme, formatting. Lines stay a comfortable length on a wide
  /// window (~34 em): the extra width goes to the margins.
  EpubTheme get _theme {
    final e = AppSettings.instance.epub;
    final family = e.font.family ?? switch (e.font) {
      EpubFont.deviceSerif => defaultTargetPlatform == TargetPlatform.windows ? 'Georgia' : 'serif',
      _ => null,
    };
    final side = sideMargin(e, _size.width);
    final context = host.context;
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
  Color get background => AppSettings.instance.epub.colours.background;
  @override
  Color ink(double alpha) => AppSettings.instance.epub.colours.text.withValues(alpha: alpha);

  // ---- opening

  @override
  Future<Object> prepare(Map book) async {
    final id = book['id'] as String;
    EpubTrace.instance.log('open $id "${book['metadata']?['title'] ?? book['name']}"');
    final hy = _hyphenators ??= await Hyphenators.load(rootBundle.loadString);
    final from = source ?? sourceFor(api, id);
    final info = await from.info();
    if (info.spine.isEmpty) throw StateError('This book has no chapters');
    var chapter = 0;
    double? fraction;
    EpubKomgaPlace? known;
    final progress = EpubProgress(api, id);
    // where reading stopped (Komga's progression, shared with its web reader); a book not started: the start
    if (saves) {
      try {
        final at = await progress.load(Map<String, dynamic>.from(book));
        final i = at == null ? -1 : info.spine.indexOf(at.path);
        if (i >= 0) {
          chapter = i;
          fraction = at!.progression;
        }
      } catch (_) {
        // Komga can't say: the start
      }
      try {
        known = await progress.place(); // what another device's change is told from
      } catch (_) {
        // learnt at the first save instead
      }
    }
    // the book's own text size first (a book set smaller or larger all through shows at the reader's size)
    final b = EpubBook(from, info, hy);
    await b.measureTextSize();
    _progress = progress;
    return _Prepared(b, chapter, fraction, known);
  }

  @override
  void show(Map book, Object prepared) {
    prepared as _Prepared;
    _record = book;
    _book?.removeListener(_onBook);
    _book?.dispose();
    _book = prepared.book..addListener(_onBook);
    _chapter = prepared.startChapter;
    _page = 0;
    _end = false;
    _startFraction = prepared.startFraction ?? 0;
    _openedKnown = prepared.known;
    _ready = false;
    _anchor = null;
    _changed();
  }

  @override
  Object? get openedProgress => _openedKnown;

  @override
  void dispose() {
    _disposed = true;
    if (readerTiming) {
      SchedulerBinding.instance.removeTimingsCallback(_onFrames);
      final last = _frameStats.flush();
      if (last != null) EpubTrace.instance.log(last);
    }
    EpubTrace.instance.log('closed');
    for (final t in _prefetchTimers) {
      t.cancel();
    }
    _book?.removeListener(_onBook);
    _book?.dispose();
    _pc.dispose();
    _contentsNode.dispose();
    _settingsNode.dispose();
    super.dispose();
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

  // ---- layout: every new size or setting is counted again (or its counts remembered) before the book shows

  void _layout(Size size) {
    final b = _book!;
    // no room at all (a minimised window): nothing to lay out - it lost the place, and opened at the chapter's
    // start afterwards (EPUB review R12)
    if (size.isEmpty) return;
    _size = size;
    final theme = _theme;
    if (b.size == size && b.theme == theme) return;
    // the place being read: the anchor from the layout before, if nothing has moved since - not the start of the page
    // now on screen, which is earlier than the place, so each new size or setting walked back a little more
    // (Windows, build 79: two resizes and back, a page back). Still opening (the saved place not shown yet): the
    // saved place again ([_startFraction]) - the system bars hiding right after opening change the size before it's
    // shown (found on the tablet). Laid out again before the last layout was counted: its anchor still stands.
    if (_ready && !_end) _anchor ??= b.positionOf(_chapter, _page);
    b.setLayout(theme, size);
    _ready = false;
    WidgetsBinding.instance.addPostFrameCallback((_) => _count());
  }

  /// The place being read through new layouts (window sizes, settings); let go of at any other move.
  EpubPosition? _anchor;

  int _countRun = 0; // each layout's counting: an older one still going stops when it sees it's not the last

  /// The layout's counts - remembered from before, else counted - then the place shown in it.
  Future<void> _count() async {
    final b = _book;
    if (b == null || _disposed || b.size == Size.zero) return;
    final run = ++_countRun;
    final key = await _layoutKey(b);
    final id = _record['id'] as String;
    final kept = await EpubCountStore.instance.load(id, key).catchError((Object _) => null);
    if (run != _countRun || _disposed || _book != b) return;
    if (kept == null || !b.restoreCounts(kept)) {
      await b.countAll(current: () => _chapter);
      if (run != _countRun || _disposed || _book != b) return;
      final counts = b.counts;
      if (counts != null) unawaited(EpubCountStore.instance.save(id, key, counts));
    }
    if (!b.counted) return; // laid out again meanwhile: that layout's counting carries on
    // the place: the anchor kept through the new layout, else the saved place
    final keep = _anchor;
    final int to;
    if (_end) {
      to = b.totalPages!;
    } else if (keep != null) {
      to = b.bookPage(keep.chapter, b.pageAt(keep.chapter, keep.position))!;
    } else {
      final c = _chapter;
      to = b.bookPage(c, b.pageAt(c, ((_startFraction ?? 0) * b.lengthOf(c)).round()))!;
      _startFraction = null;
    }
    _setPlace(to);
    final old = _pc;
    _pc = PageController(initialPage: to);
    WidgetsBinding.instance.addPostFrameCallback((_) => old.dispose());
    _countChanges = b.countChanges;
    _ready = true;
    openedAt = to;
    host.placed(to); // not a turn
    _prefetchAround();
    _changed();
  }

  /// What a book's counts depend on: this app's build (its layout code), the book's file, the page size and the
  /// look - not the colours.
  Future<String> _layoutKey(EpubBook b) async {
    final t = b.theme, m = t.margins;
    final file = '${_record['fileLastModified'] ?? ''}/${_record['sizeBytes'] ?? ''}';
    return [
      _appVersion ??= await getAppVersion() ?? '',
      file,
      '${b.size.width.toStringAsFixed(1)}x${b.size.height.toStringAsFixed(1)}@${t.pixelRatio}',
      '${t.fontFamily}/${t.fontSize}/${t.lineHeight}/${t.paragraphGap}',
      '${m.left}/${m.top}/${m.right}/${m.bottom}',
      '${t.bookFormatting}/${t.hyphenate}/${b.textSize}/${b.textBold}',
    ].join('|');
  }

  static String? _appVersion; // the value, not the future: a future is tied to where it began (tests)

  int _countChanges = 0; // the book's countChanges this renderer has gone along with

  void _onBook() {
    final b = _book;
    if (b == null || _disposed) return;
    if (SchedulerBinding.instance.schedulerPhase == SchedulerPhase.persistentCallbacks) {
      // told mid-build (a new layout is set while laying the screen out): after this frame
      WidgetsBinding.instance.addPostFrameCallback((_) => _onBook());
      return;
    }
    if (_ready && b.countChanges != _countChanges && b.counted && !_end) {
      // a chapter's number of pages changed after counting: the book's page numbers after it moved - back to the
      // same page (the page view kept its number, now another page - EPUB review R5)
      _countChanges = b.countChanges;
      final at = b.bookPage(_chapter, _page);
      if (at != null && _pc.hasClients && (_pc.page ?? 0).round() != at) _jumpView(at);
    }
    _changed(); // the spinner's count, a chapter laid out
  }

  void _setPlace(int i) {
    final b = _book!;
    if (i > last) {
      _end = true;
      return;
    }
    final (c, p) = b.chapterPage(i);
    if (c != _chapter) b.keepAround(c);
    _chapter = c;
    _page = p;
    _end = false;
  }

  /// Chapter [i] laid out ahead (a neighbour, ready to turn into); a failure is the chapter's, shown when it's
  /// reached. Laid out a moment later, once the turn that called for it has finished sliding: laying a chapter out
  /// holds the screen up, and doing it mid-slide made the turn stutter (user, 2026-10-06).
  void _prefetch(int i) {
    final b = _book!;
    if (b.pagesNow(i) != null) return;
    _prefetchTimers.add(Timer(const Duration(milliseconds: 350), () {
      if (_disposed || _book != b) return;
      unawaited(b.pages(i).then<void>((_) {}, onError: (Object _) {}));
    }));
    _prefetchTimers.removeWhere((t) => !t.isActive);
  }

  final _prefetchTimers = <Timer>[];

  void _prefetchAround() {
    final b = _book!;
    if (_chapter + 1 < b.chapterCount) _prefetch(_chapter + 1);
    if (_chapter > 0) _prefetch(_chapter - 1);
  }

  // ---- turning

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
    if (!_ownJump) _anchor = null; // a turn: the page shown is the place now
    EpubTrace.instance.log('page $i${_ownJump ? ' by the reader' : ''}');
    _setPlace(i);
    if (!_end) _prefetchAround();
    _changed();
    if (_ownJump) return; // the renderer moved the page itself (a layout, a count change): not a turn
    host.pageChanged(i, curling: false);
  }

  bool _ownJump = false;

  /// The renderer's own move of the page view (laid out again, a count change): not a turn.
  void _jumpView(int page) {
    _queued = 0; // a turn waiting on a slide is dropped: the reader went elsewhere
    _ownJump = true;
    _pc.jumpToPage(page);
    _ownJump = false;
  }

  @override
  void jumpTo(int place) {
    _queued = 0;
    _anchor = null;
    if (_pc.hasClients) _pc.jumpToPage(place);
  }

  // A turn's slide: 320 ms, easing in and out. The old 220 ms ease-out moved the page ~150 px a frame at the start -
  // sharp text moving that far a frame reads as judder even at a full 60 fps (user, build 75: "not smooth in the way
  // that comics are"); this one peaks near 100 px.
  Duration get _turnTime =>
      AppSettings.instance.epub.turn == EpubTurn.none ? Duration.zero : const Duration(milliseconds: 320);
  static const _turnCurve = Curves.easeInOut;

  @override
  void forward({bool snap = false}) {
    if (_end) {
      host.nextBook();
      return;
    }
    unawaited(_turn(1, snap: snap));
  }

  @override
  void back({bool snap = false}) => unawaited(_turn(-1, snap: snap));

  // the wheel: notches added up to a turn, at most one turn a quarter second (a spun wheel doesn't race through the
  // book) - as the comic reader's
  double _wheelAcc = 0;
  DateTime _lastWheelTurn = DateTime(0);

  void _onWheel(double dy) {
    if (!_ready || host.controlsUp) return;
    _wheelAcc += dy;
    if (_wheelAcc.abs() < 40) return;
    final fwd = _wheelAcc > 0;
    _wheelAcc = 0;
    final now = DateTime.now();
    if (now.difference(_lastWheelTurn) < const Duration(milliseconds: 250)) return;
    _lastWheelTurn = now;
    fwd ? forward() : back();
  }

  /// A page turn. One asked for while a slide is under way is never started over from the middle of it: that began
  /// the slide again at its slowest part, so a held remote button or quick taps crept and never turned (user,
  /// 2026-10-07). It waits, and is made the moment the slide ends - only the latest one, so a held button turns a
  /// page per slide and letting go turns at most one more. [snap] (a tap - it can't be held): the slide under way
  /// ends at once and the next starts, so each tap turns a page.
  Future<void> _turn(int by, {bool snap = false}) async {
    EpubTrace.instance.log('turn $by from chapter $_chapter page $_page${_sliding ? ' (waits for the slide)' : ''}');
    if (_book == null || !_ready || host.busy) return;
    host.awake();
    if (!_pc.hasClients) return;
    if (_sliding) {
      _queued = by;
      if (snap) _pc.jumpToPage(_slideTarget); // the slide ends here: the turn waiting goes at once
      return;
    }
    // a tap's finger stops the slide under way where it is (the page view holds for a drag) before the tap is
    // known: a turn straight after a slide cut short goes on from where that slide was going - counted from the
    // half-turned page, it landed on the same page again
    final cut = _cutShort;
    _cutShort = null;
    final from = cut != null && DateTime.now().difference(cut.$2) < const Duration(milliseconds: 400)
        ? cut.$1
        : (_pc.page ?? 0).round();
    final target = from + by;
    if (target < 0 || target > last + 1) return;
    if (_turnTime == Duration.zero) {
      _pc.jumpToPage(target);
      return;
    }
    _sliding = true;
    _slideTarget = target;
    try {
      await _pc.animateToPage(target, duration: _turnTime, curve: _turnCurve);
    } finally {
      _sliding = false;
    }
    final landed = _pc.hasClients ? _pc.page : null;
    if (landed != null && (landed - target).abs() > 0.01) _cutShort = (target, DateTime.now());
    final next = _queued;
    _queued = 0;
    if (next != 0 && !_disposed && _pc.hasClients) await _turn(next);
  }

  int _queued = 0; // a turn asked for during the slide: made when it ends (0: none)
  int _slideTarget = 0; // the page the slide under way goes to
  (int, DateTime)? _cutShort; // the last slide stopped short of its page (by a finger): that page, and when

  /// A turn's slide is under way: a held key's repeats wait for it to end (each one restarted the slide at its
  /// slowest part, so a held key crept and never turned a page - user, build 82, Windows).
  bool _sliding = false;

  void _tap(TapUpDetails d, Size size, EpubPage? page) {
    // a link under the finger first (footnotes)
    for (final l in page?.links ?? const <EpubLink>[]) {
      if (l.rect.inflate(10).contains(d.localPosition)) {
        unawaited(_openLink(l));
        return;
      }
    }
    final x = d.localPosition.dx / size.width;
    // a big picture tapped in the middle of the screen: full screen over the book (the sides still turn the page -
    // a picture can fill the page)
    if (!host.controlsUp && x >= 1 / 3 && x <= 2 / 3) {
      for (final (rect, image) in page?.pictures ?? const <(Rect, ui.Image)>[]) {
        if (rect.contains(d.localPosition)) {
          unawaited(_showPicture(image));
          return;
        }
      }
    }
    host.tap(x);
  }

  // ---- links, footnotes, contents: a move there is a jump, as the slider's (the way back kept)

  /// To [chapter] at [position] (characters into it).
  void _goTo(int chapter, int position) {
    final b = _book!;
    host.jumpTo(b.bookPage(chapter, b.pageAt(chapter, position))!);
  }

  Future<void> _openLink(EpubLink l) async {
    final b = _book!;
    if (l.href.contains('://')) return; // the web: not from the reader
    final hash = l.href.indexOf('#');
    final path = hash < 0 ? l.href : l.href.substring(0, hash);
    final frag = hash < 0 ? null : l.href.substring(hash + 1);
    // a footnote marker ("*", "[1]", a superscript number): the note in a pop-up, the page stays
    final marker = l.text.length <= 4 || RegExp(r'^[\[\(]?[0-9⁰¹²³⁴⁵⁶⁷⁸⁹*†‡§]+[\]\)]?$').hasMatch(l.text);
    if (marker && frag != null) {
      final ctx = host.context;
      final note = await _noteText(path, frag);
      if (note != null && ctx.mounted) {
        await showDialog<void>(context: ctx, builder: (c) => AlertDialog(
          content: SingleChildScrollView(child: Text(note, style: const TextStyle(fontSize: 16, height: 1.4))),
          actions: [TextButton(onPressed: () => Navigator.pop(c), child: const Text('Close'))],
        ));
        return;
      }
    }
    final ch = b.chapterOf(path);
    if (ch == null) return;
    final at = frag == null ? 0 : await _fragmentOr0(b, ch, frag);
    if (!_disposed && _book == b) _goTo(ch, at);
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
      context: host.context,
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
    await showReaderPanelFrame(host.context, title: 'Contents', children: (c, _) => [
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
    if (chosen == null || _disposed || _book != b) return;
    final ch = b.chapterOf(chosen.path);
    if (ch == null) return;
    host.hideControls(); // (the remote's focus back on the page, as any other way of hiding them)
    final hash = chosen.href.indexOf('#');
    final at = hash < 0 ? 0 : await _fragmentOr0(b, ch, chosen.href.substring(hash + 1));
    if (!_disposed && _book == b) _goTo(ch, at);
  }

  /// The Aa panel: the EPUB settings while reading; the page changes behind it as they're set.
  Future<void> _settingsPanel() async {
    // the comic reader's panel look: the page stays in view beside it (wide) or above it (narrow), changing live;
    // the controls stay up behind it, as with comics. This device's reading settings below the book's, as in the
    // comic reader's panel (user, 2026-10-06: the panels as the comics')
    await showReaderPanelFrame(host.context, title: 'Text and page', children: (c, s) => [
          ...epubSettingRows(c, s.epub, s.setEpub),
          SettingsGroup(title: 'This device', children: [
            ...brightnessRows(s, compact: true),
            ...nightRows(s),
            if (canRotate) rotationRow(s),
            screenOnRow(s),
          ]),
        ]);
  }

  // ---- the bars

  final _contentsNode = FocusNode(debugLabel: 'ctl-contents');
  final _settingsNode = FocusNode(debugLabel: 'ctl-settings');

  @override
  List<BarButton> bottomButtons(BuildContext context) => [
        BarButton(_contentsNode,
            barIcon(node: _contentsNode, icon: Icons.toc, label: 'Contents', onPressed: _contents)),
        BarButton(_settingsNode, barIcon(node: _settingsNode, icon: Icons.text_fields,
            label: 'Text and page settings', onPressed: _settingsPanel)),
      ];

  // ---- what's said

  /// The chapter's name from the contents (the last entry for its file), else "Chapter N of M".
  String _chapterNameOf(int chapter) {
    final b = _book!;
    final path = b.info.spine[chapter];
    final named = b.info.toc.where((t) => t.path == path && t.title.isNotEmpty);
    return named.isEmpty ? 'Chapter ${chapter + 1} of ${b.chapterCount}' : named.first.title;
  }

  /// Option F (user, 2026-10-06), on the shared row: the chapter's name on top, the book's page and % at the left,
  /// the chapter's page at the right.
  @override
  ({SpotText? left, SpotText? centre, SpotText? right}) spots(int place) {
    final b = _book!;
    final at = place.clamp(0, last);
    final (c, p) = b.chapterPage(at);
    final pct = (b.progression(b.positionOf(c, p)) * 100).round();
    return (
      left: SpotText('Book · Pg. ${at + 1}/${b.totalPages} · $pct%', 'book page'),
      centre: SpotText(_chapterNameOf(c), 'chapter'),
      // no chapter number: the book's file count, not the chapter's own ("Ch. 4" under "Chapter One" - user, 2026-10-07)
      right: SpotText('Ch. · Pg. ${p + 1}/${b.pageCount(c)}', 'chapter page'),
    );
  }

  @override
  String corner(int place) => '${place.clamp(0, last) + 1} / ${_book!.totalPages}';
  @override
  String placeLabel(int place) => 'Page ${place + 1}';

  double get _here => _book!.progression(_book!.positionOf(_chapter, _page));

  @override
  String get whereText => "You're ${(_here * 100).round()}% of the way through.";

  // ---- progress on Komga: a place in the book (Komga's progression, shared with its web reader)

  @override
  Future<Object?> Function() progressReader() {
    final p = _progress!;
    return p.place;
  }

  @override
  Future<Object?> Function() progressSaver(int place) {
    final p = _progress!, id = _record['id'] as String;
    if (place > last) {
      // the end card: the book is read
      return () async {
        await api.markRead(id);
        return p.place();
      };
    }
    final b = _book!;
    final (c, pg) = b.chapterPage(place);
    final at = b.positionOf(c, pg);
    final length = b.lengthOf(c);
    final path = b.info.spine[c], progression = length == 0 ? 0.0 : at.position / length, total = b.progression(at);
    return () async {
      await p.save(path, progression, total);
      try {
        return await p.place(); // read back: Komga may change the read state with it
      } catch (_) {
        return EpubKomgaPlace(path, progression, total, finished: false);
      }
    };
  }

  @override
  bool sameProgress(Object? a, Object? b) =>
      a is EpubKomgaPlace && b is EpubKomgaPlace ? a.sameAs(b) : identical(a, b) || a == b;

  @override
  bool finishedAt(int place) => place > last;

  @override
  ElsewhereText elsewhereText(Object? moved, int here) {
    final m = moved as EpubKomgaPlace;
    final b = _book!;
    final at = (_here * 100).round();
    final chapter = m.path == null ? null : b.chapterOf(m.path!);
    final there = m.total == null ? null : (m.total! * 100).round();
    final (title, text, go) = m.finished
        ? ('Finished on another device', 'This book was read to the end on another device.', 'Go to the end')
        : m.path == null || chapter == null
            ? ('Started over on another device', 'This book was marked unread on another device.', 'Go to the start')
            : ('Read on another device',
                there == null ? 'This book was read further on another device.' : 'On another device this book is at $there%.',
                there == null ? 'Go there' : 'Go to $there%');
    return (title: title, text: text, stay: 'Stay at $at%', go: go);
  }

  @override
  int acceptElsewhere(Object? moved) {
    final m = moved as EpubKomgaPlace;
    final b = _book!;
    if (m.finished) {
      _record = {..._record, 'readProgress': {...?(_record['readProgress'] as Map?), 'completed': true}};
      return last + 1; // the end card
    }
    final chapter = m.path == null ? null : b.chapterOf(m.path!);
    if (chapter == null) return 0;
    return b.bookPage(chapter, b.pageAt(chapter, (m.progression * b.lengthOf(chapter)).round()))!;
  }

  // ---- drawing

  /// The book being counted in this layout: a spinner, how far it has got, and Close (Back works too). The page area
  /// is measured here too - the layout it's counted in.
  @override
  Widget waiting(BuildContext context) => LayoutBuilder(builder: (context, box) {
        _layout(box.biggest);
        final b = _book!;
        final n = b.chapterCount, done = b.countedChapters;
        final ink = _theme.text;
        return ColoredBox(
          color: _theme.background,
          child: Center(child: Column(mainAxisSize: MainAxisSize.min, children: [
            const SizedBox(width: 36, height: 36, child: CircularProgressIndicator(strokeWidth: 3)),
            const SizedBox(height: 20),
            Text('Laying out the book', style: TextStyle(color: ink.withValues(alpha: 0.8), fontSize: 16)),
            const SizedBox(height: 6),
            Text('Chapter ${math.min(done + 1, n)} of $n', key: const ValueKey('epub-counting'),
                style: TextStyle(color: ink.withValues(alpha: 0.55), fontSize: 13,
                    fontFeatures: const [FontFeature.tabularFigures()])),
            const SizedBox(height: 14),
            SizedBox(width: 220, child: LinearProgressIndicator(value: n == 0 ? null : done / n, minHeight: 3,
                backgroundColor: ink.withValues(alpha: 0.12))),
            const SizedBox(height: 22),
            TextButton(onPressed: () => Navigator.of(context).maybePop(),
                child: Text('Close', style: TextStyle(color: ink.withValues(alpha: 0.8)))),
          ])),
        );
      });

  @override
  List<Widget> buildPages(BuildContext context) => [
        Positioned.fill(child: LayoutBuilder(builder: (context, box) {
          final size = box.biggest;
          _layout(size);
          final b = _book!;
          if (!_ready) return ColoredBox(color: _theme.background); // laid out again: the spinner next frame
          final pages = b.pagesNow(_chapter) ?? const <EpubPage>[];
          final shown = _end || pages.isEmpty ? null : pages[_page.clamp(0, pages.length - 1)];
          return Stack(children: [
            PageView.builder(
              controller: _pc,
              itemCount: b.totalPages! + 1, // + the end card
              onPageChanged: _onPageChanged,
              // the pages either side built ahead, as the comic reader's are: a tap's turn no longer builds the
              // incoming page in its first frame (most tap turns missed one refresh there - measured on the
              // tablet, build 76; swipes and comics didn't)
              allowImplicitScrolling: true,
              // each page drawn once and kept as a picture: sliding moves it, rather than drawing every line
              // of both pages again each frame
              itemBuilder: (_, i) => RepaintBoundary(child: _pageAt(i, size)),
            ),
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
              onSecondaryTap: host.toggleControls, // right-click, as with comics
            )),
          ]);
        })),
      ];

  Widget _pageAt(int i, Size size) {
    final b = _book!;
    final theme = _theme;
    if (i >= b.totalPages!) return host.endCard();
    final (c, p) = b.chapterPage(i);
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
  Widget _chapterError(EpubBook b, int chapter, EpubTheme theme) => ColoredBox(
        color: theme.background,
        child: Center(child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            ErrorText(couldnt('show this chapter', b.errorOf(chapter)!, thing: 'book'), b.errorOf(chapter)!,
                centre: true),
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed: () {
                b.retry(chapter);
                unawaited(b.pages(chapter).then<void>((_) {}, onError: (Object _) {}));
              },
              icon: const Icon(Icons.refresh),
              label: const Text('Retry'),
            ),
          ]),
        )),
      );
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
