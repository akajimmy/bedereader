import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart' show defaultTargetPlatform, listEquals;
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show SelectWordSelectionEvent, SelectionRegistrar;
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
import '../highlights.dart';
import '../offline/downloads.dart';
import '../offline/offline_komga.dart';
import '../page_curl.dart';
import '../screen.dart';
import '../settings.dart';
import '../widgets/define_sheet.dart';
import '../widgets/note_sheet.dart';
import '../widgets/display_panel.dart';
import '../widgets/epub_settings.dart';
import '../widgets/error_text.dart';
import 'curl_turns.dart';
import 'epub_selection.dart';
import 'position_row.dart';
import 'reader_bars.dart';
import 'renderer.dart';
import 'spreads.dart';

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

  @override
  BookKind get kind => BookKind.ebooks;

  /// Where the first book's files come from (tests: from memory); others: Komga, or the downloaded file offline.
  final EpubSource? source;

  /// Progress is loaded and saved (tests showing a book from memory: not).
  final bool saves;

  static Hyphenators? _hyphenators; // loaded once (the value, not the future: a future is tied to where it began)

  /// The page's left / right margin at [width]: the setting's share of the width ([EpubMargins.share]), or more on a
  /// wide screen, where lines stop at the setting's length ([EpubMargins.lineEms]) and the rest goes to the margins.
  /// Margins: Book's - none here: each chapter's own page margin is used ([EpubTheme.bookMargins]).
  static double sideMargin(EpubPrefs e, double width) => e.margins == EpubMargins.book
      ? 0
      : math.max(width * e.margins.share, (width - e.size * e.margins.lineEms) / 2);

  /// Inset page ([InsetPage]): the page drawn as a sheet on a surround ([surround]). Its edges follow the text, not
  /// the screen (user, 2026-10-16): [textGap] out from [textArea] all round - left of where every line starts, above
  /// the first line, right of where lines end, below the last - wherever the margins put the text on the [page] (the
  /// screen, or half of it two pages up): a style that ignores the margins. Never: none; Wide screen: on a screen
  /// wider than tall ([area]); Always: always. Kept on the page: a margin under [textGap] leaves that edge at the
  /// page's. Null: no sheet.
  /// [gap]: how far out at the sides, [ends] above and below (DisplayPrefs.insetGap / insetGapEnds - for now the
  /// panel's sliders, to dial them in); [ends] unset: [gap].
  static Rect? sheetRect(Rect? textArea, Size page, InsetPage inset, Size area, {double gap = textGap, double? ends}) {
    if (textArea == null || inset == InsetPage.never) return null;
    if (inset == InsetPage.wideScreen && area.width <= area.height) return null;
    final v = ends ?? gap;
    return Rect.fromLTRB(textArea.left - gap, textArea.top - v, textArea.right + gap, textArea.bottom + v)
        .intersect(Offset.zero & page);
  }

  /// How far the sheet's edges sit out from the text by default (user, 2026-10-16: 20 px; "too close" - being dialled in).
  static const textGap = 20.0;

  /// The colour round the sheet: the page's own, a shade darker (a white page on light grey); the dark grey page on
  /// black (user, 2026-10-16: "full black"); black, a shade lighter (user, 2026-10-11: derived, no setting).
  static Color surround(Color page) {
    final l = page.computeLuminance();
    if (l < 0.005) return Color.lerp(page, const Color(0xFFFFFFFF), 0.07)!;
    if (l < 0.3) return const Color(0xFF000000);
    return Color.lerp(page, const Color(0xFF000000), 0.1)!;
  }

  /// Where book [id]'s files come from: a downloaded EPUB's file - offline (its progress kept on the device, sent to
  /// Komga later) and online too (user, 2026-10-12: the downloaded copy, if there is one; progress and highlights
  /// still go to Komga as before); else Komga.
  static EpubSource sourceFor(Komga api, String id) {
    final file = api is OfflineKomga ? api.epubFile(id) : Downloads.instance.epubFileOf(api.baseUrl, id);
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
    // (Inset page doesn't move the text: its sheet sits round the text where the margins put it - sheetRect)
    final side = sideMargin(e, _size.width);
    final context = host.context;
    return EpubTheme(
      background: e.colours.background,
      text: e.colours.text,
      fontFamily: family,
      fontSize: e.size,
      lineHeight: e.lineSpacing,
      margins: EdgeInsets.fromLTRB(side, EpubMargins.topBottom, side, EpubMargins.topBottom),
      // the book's alignment and paragraphs, or the reader's (user, 2026-10-07: three settings, from one)
      ownAlign: switch (e.align) {
        EpubAlign.book => null,
        EpubAlign.justified => TextAlign.justify,
        EpubAlign.left => TextAlign.left,
      },
      // the gaps between paragraphs are Paragraph spacing's: Book's leaves the book's, a step replaces them
      ownParagraphs: e.paragraphGap != EpubParagraphGap.book,
      hyphenate: e.hyphenate,
      paragraphGap: e.paragraphGap.ems ?? 0,
      bookMargins: e.margins == EpubMargins.book,
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
    PageCurl.program().ignore(); // the curl's shader, ahead of the first turn
    _highlights?.removeListener(_changed);
    _highlights?.dispose();
    _highlights = BookHighlights(api, id)..addListener(_changed);
    unawaited(_highlights!.load());
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
    // measured once per build of the app and file of the book, then kept with its page counts (user, 2026-10-11: it
    // loaded five chapters on every open)
    final version = '${_appVersion ??= await getAppVersion() ?? ''}|'
        '${book['fileLastModified'] ?? ''}/${book['sizeBytes'] ?? ''}';
    final kept = await EpubCountStore.instance.loadTextSize(id, version).catchError((Object _) => null);
    if (kept != null) {
      b
        ..textSize = kept.$1
        ..textBold = kept.$2;
    } else {
      // kept only when every sampled chapter was read (one that failed - the network - is measured again next time)
      if (await b.measureTextSize()) {
        unawaited(EpubCountStore.instance.saveTextSize(id, version, b.textSize, b.textBold));
      }
    }
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
    _settle?.cancel();
    _curlMade?.dispose();
    _previewWait?.cancel();
    _previewLaid.dispose();
    _highlights?.removeListener(_changed);
    _highlights?.dispose();
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
    _selectionFocus.dispose();
    _selected.dispose();
    _firstTapTimer?.cancel();
    _pressed.dispose();
    _selectionMoved.dispose();
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

  void _layout(Size area) {
    final b = _book!;
    // no room at all (a minimised window): nothing to lay out - it lost the place, and opened at the chapter's
    // start afterwards (EPUB review R12)
    if (area.isEmpty) return;
    _area = area;
    // Dual page mode (user, 2026-10-16): two pages side by side, each laid out at half the width
    final dual = twoPagesAllowed && AppSettings.instance.epub.twoPages.on(area);
    _laidDual = dual;
    final size = dual ? Size(area.width / 2, area.height) : area;
    _size = size;
    final theme = _theme;
    if (b.size == size && b.theme == theme) {
      _settle?.cancel(); // changed and changed back before it was due
      _settle = null;
      // laid out as these settings would be: their sheet
      _laidInset = AppSettings.instance.display.insetPage;
      // the same pages, set out the other way (a half-width page and a narrow window's are the same page): two up or
      // one, after this frame
      if (_ready && dual != _dual) WidgetsBinding.instance.addPostFrameCallback((_) => _arrange(dual));
      return;
    }
    // only the settings changed (the same page, laid out before): laid out once they stop changing - the size up five
    // steps is one layout and one count, not five (user, 2026-10-07). The page shows as it was meanwhile ([_drawn]).
    if (b.size == size && !_settled) {
      _settle?.cancel();
      _settle = Timer(settleDelay, () {
        _settle = null;
        if (_disposed) return;
        _settled = true;
        _changed();
      });
      return;
    }
    _settled = false;
    _settle?.cancel();
    _settle = null;
    if (_selected.value) WidgetsBinding.instance.addPostFrameCallback((_) => _clearSelection()); // other pages now
    // the place being read: the anchor from the layout before, if nothing has moved since - not the start of the page
    // now on screen, which is earlier than the place, so each new size or setting walked back a little more
    // (Windows, build 79: two resizes and back, a page back). Still opening (the saved place not shown yet): the
    // saved place again ([_startFraction]) - the system bars hiding right after opening change the size before it's
    // shown (found on the tablet). Laid out again before the last layout was counted: its anchor still stands.
    if (_ready && !_end) _anchor ??= b.positionOf(_chapter, _page);
    b.setLayout(theme, size);
    _laidInset = AppSettings.instance.display.insetPage;
    _ready = false;
    WidgetsBinding.instance.addPostFrameCallback((_) => _count());
  }

  /// How long the settings must stay put before the book is laid out again for them.
  @visibleForTesting
  static Duration settleDelay = const Duration(milliseconds: 600);
  Timer? _settle; // a layout for new settings, due once they stop changing
  bool _settled = false; // that time has come: lay out at the next build

  /// The look the book is laid out in: what the page is drawn with until a layout for new settings is due.
  EpubTheme get _drawn {
    final b = _book;
    return b == null || b.size == Size.zero ? _theme : b.theme;
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
    _dual = _laidDual; // one page or two, as laid out ([_layout]): the spreads of this count
    _pairBook();
    _setPlace(to);
    final old = _pc;
    _pc = PageController(initialPage: _viewOf(to));
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
      '${t.ownAlign}/${t.ownParagraphs}/${t.hyphenate}/${b.textSize}/${b.textBold}/${t.bookMargins}',
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
      _pairBook(); // (two pages up: the spreads move with the pages)
      final at = b.bookPage(_chapter, _page);
      if (at != null && _pc.hasClients && (_pc.page ?? 0).round() != _viewOf(at)) _jumpView(_viewOf(at));
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

  void _pageChanged(int view) {
    _clearSelection(); // a selection is the page's: turned (any way), it goes
    if (!_ownJump) _anchor = null; // a turn: the page shown is the place now
    final i = _placeOf(view);
    EpubTrace.instance.log('page $i${_ownJump ? ' by the reader' : ''}');
    _setPlace(i);
    if (!_end) _prefetchAround();
    _changed();
    if (_ownJump) return; // the renderer moved the page itself (a layout, a count change): not a turn
    // a curl moves the page view as it starts (and back, let go early): it counts once it completes ([CurlTurns.done])
    // - counted at once, a curl let go on the last page marked the book read (audit, 2026-10-11)
    host.pageChanged(i, curling: _curlMade?.active ?? false);
  }

  bool _ownJump = false;

  /// The renderer's own move of the page view to item [view] (laid out again, a count change): not a turn.
  void _jumpView(int view) {
    _queued = 0; // a turn waiting on a slide is dropped: the reader went elsewhere
    _ownJump = true;
    _pc.jumpToPage(view);
    _ownJump = false;
  }

  @override
  void jumpTo(int place) {
    _queued = 0;
    _anchor = null;
    if (_pc.hasClients) _pc.jumpToPage(_viewOf(place));
  }

  // ---- Dual page mode (user, 2026-10-16): the page view goes by spread - two pages, each chapter starting on the
  // right (lib/reader/spreads.dart pairChapters) - and the place is the earlier page shown; one page each otherwise

  /// Two pages side by side now (the spreads of this count).
  bool _dual = false;
  bool _laidDual = false; // the last layout's: two up (it takes effect once counted)
  Size _area = Size.zero; // the whole page area (both pages; [_size] is a page's)
  List<Spread> _spreads = const [];
  List<int> _spreadOf = const [];

  /// The spreads of this count (none, one page up).
  void _pairBook() {
    final b = _book;
    if (!_dual || b == null || !b.counted) {
      _spreads = const [];
      _spreadOf = const [];
      return;
    }
    _spreads = pairChapters([for (var c = 0; c < b.chapterCount; c++) b.pageCount(c)!]);
    _spreadOf = spreadIndex(_spreads, b.totalPages!);
  }

  /// The page view's item showing page [place] (past the last: the end card).
  int _viewOf(int place) => !_dual ? place : place > last ? _spreads.length : _spreadOf[place];

  /// The place at page view item [view]: two up, the earlier page shown (the end card: past the last page).
  int _placeOf(int view) => !_dual ? view : view >= _spreads.length ? last + 1 : _spreads[view].first;

  /// The page view's items before the end card.
  int get _views => _dual ? _spreads.length : _book!.totalPages!;

  /// One page or two now, the same layout (the window's shape changed, not the page's): the page view again, on the
  /// same page.
  void _arrange(bool dual) {
    if (_disposed || !_ready || dual == _dual) return;
    final keep = place;
    _dual = dual;
    _pairBook();
    _clearSelection();
    final old = _pc;
    _pc = PageController(initialPage: _viewOf(keep));
    WidgetsBinding.instance.addPostFrameCallback((_) => old.dispose());
    _changed();
  }

  // A turn's slide: 320 ms, easing in and out. The old 220 ms ease-out moved the page ~150 px a frame at the start -
  // sharp text moving that far a frame reads as judder even at a full 60 fps (user, build 75: "not smooth in the way
  // that comics are"); this one peaks near 100 px.
  Duration get _turnTime => AppSettings.instance.epub.turn == EpubTurn.slide
      ? const Duration(milliseconds: 320)
      : Duration.zero; // none - or curl, when it couldn't be drawn: at once

  /// 3D page curl (user, 2026-10-11: as the comics'): the page turns over from a snapshot (lib/reader/curl_turns.dart).
  bool get _curlMode => AppSettings.instance.epub.turn == EpubTurn.curl && CurlTurns.available;
  CurlTurns? _curlMade;
  CurlTurns get _curl => _curlMade ??= CurlTurns(
    vsync: host.vsync,
    current: () => _pc.hasClients ? (_pc.page ?? 0).round() : 0,
    jump: (v) {
      if (_pc.hasClients) _pc.jumpToPage(v);
    },
    // two pages up: the right-hand page turns, over onto the left, attached at the spine (as comics')
    pageRect: () => _dual ? _sideRect(later: true) : _sheet ?? Offset.zero & _size,
    spine: () => _dual,
    held: () => _dual ? Rect.fromLTWH(0, 0, _size.width, _area.height) : null,
    // (the sheets round the text: apart by the margins between the texts, less the gap round each)
    gap: () => _dual && _sheet != null ? AppSettings.instance.display.insetBetween : 0,
    done: ({required turned}) {
      if (turned && _pc.hasClients) host.turned(_placeOf((_pc.page ?? 0).round()));
    },
    pixelRatio: () => MediaQuery.devicePixelRatioOf(host.context),
    paper: () => _drawn.background, // the back of the page in the page's own colour (user, 2026-10-11)
  );
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
    if (target < 0 || target > _views) return;
    if (_curlMode && _curl.turn(next: by > 0, target: target)) return;
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

  void _tap(TapUpDetails d, Size size) {
    // text selected: a tap lets go of it - and does nothing else (no turn, no controls)
    if (_selected.value) {
      _clearSelection();
      return;
    }
    // the page under the finger, and where on it (two pages up: the one on that side)
    final (page, at) = _pageUnder(d.localPosition);
    // a highlight tapped: what to do with it (not a turn)
    final hit = page == null ? null : _highlightAt(page, at);
    if (hit != null) {
      unawaited(_highlightMenu(hit, d.globalPosition));
      return;
    }
    // a link under the finger first (footnotes)
    for (final l in page?.links ?? const <EpubLink>[]) {
      if (l.rect.inflate(10).contains(at)) {
        unawaited(_openLink(l));
        return;
      }
    }
    final x = d.localPosition.dx / size.width;
    // a big picture tapped in the middle of the screen: full screen over the book (the sides still turn the page -
    // a picture can fill the page)
    if (!host.controlsUp && x >= 1 / 3 && x <= 2 / 3) {
      for (final (rect, image) in page?.pictures ?? const <(Rect, ui.Image)>[]) {
        if (rect.contains(at)) {
          unawaited(_showPicture(image));
          return;
        }
      }
    }
    // the middle (the controls' third - the sides turn pages at once, as always): a double click selects the word
    // (user, 2026-10-12) - so one click there shows the controls once a double click is ruled out. The mouse only: on
    // a touch screen a word is a long press, and a tap there opens the controls at once (user, build 107: "the
    // single-word shortcut on touch should be tap and hold")
    if (!host.controlsUp && x >= 0.33 && x <= 0.67 && d.kind == PointerDeviceKind.mouse) {
      final first = _firstTap;
      _firstTapTimer?.cancel();
      _firstTap = null;
      if (first != null && (first - d.globalPosition).distance < kDoubleTapSlop) {
        _selectWordAt(d.globalPosition);
        // no word there (between lines, a margin): the controls after all - a second click made in doubt cancelled
        // them (user, build 107)
        if (!_selected.value) host.tap(x);
        return;
      }
      if (doubleTapWait > Duration.zero) {
        _firstTap = d.globalPosition;
        _firstTapTimer = Timer(doubleTapWait, () {
          _firstTap = null;
          if (!_disposed) host.tap(x);
        });
        return;
      }
    }
    host.tap(x);
  }

  Offset? _firstTap; // a tap in the middle, waiting to see whether a second makes it a double tap
  Timer? _firstTapTimer;

  // a mouse click, told by hand (see buildPages): where the button went down, and whether text was selected then
  Offset? _mouseDown;
  bool _rightDown = false; // the right mouse button is down on the page (a right-click on its way)
  bool _mouseDownSelected = false;
  static const _clickSlop = 5.0; // logical px a mouse may move while clicking (Flutter's gestures allow it 1-2)

  /// A mouse click on the page: as a tap - except that one made with text selected lets go of it and does nothing
  /// else (the selection area has let go of it already, as the button went down), and a selection made by the click's
  /// own wobble (a letter or two dragged over) is let go of first.
  void _mouseClick(TapUpDetails d, Size size) {
    if (_mouseDownSelected) {
      _clearSelection();
      return;
    }
    _clearSelection();
    _tap(d, size);
  }

  /// The page at [local] (on the page area) and the point there in its own terms - two pages up, the one on that
  /// side, shifted as it's drawn ([_sideShift]); null over a blank side, the end card, a page not laid out.
  (EpubPage?, Offset) _pageUnder(Offset local) {
    final b = _book!;
    if (_end) return (null, local);
    final v = _viewOf(place), later = local.dx >= _size.width;
    if (_dual && v >= _spreads.length) return (null, local);
    final int? page = !_dual ? place : later ? _spreads[v].later : _spreads[v].earlier;
    final at = !_dual ? local : local - Offset((later ? _size.width : 0) + _sideShift(later: later), 0);
    if (page == null) return (null, at);
    final (c, p) = b.chapterPage(page);
    final pages = b.pagesNow(c);
    return (pages == null || pages.isEmpty ? null : pages[p.clamp(0, pages.length - 1)], at);
  }

  /// How long a tap in the middle waits for a second (a double tap selects the word); zero: no double tap, the
  /// controls at once (tests that aren't about it).
  @visibleForTesting
  static Duration doubleTapWait = kDoubleTapTimeout;

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
        await showNote(ctx, l.text, note); // a sheet, as Define's (user, 2026-10-11)
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
      // an empty anchor before the note (calibre's <a id="filepos..."></a><p>the note</p>, every note in one div -
      // Hogfather showed all its notes for any marker - tablet test, 2026-10-11): the note is the paragraph after it
      if (text0(el).trim().isEmpty && el.parent != null) {
        final sibs = el.parent!.elements.toList();
        el = sibs.skip(sibs.indexOf(el) + 1).firstWhere((s) => text0(s).trim().isNotEmpty, orElse: () => el!);
      }
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
    Highlight? pickedMark;
    final marks = inReadingOrder(_highlights?.items ?? const [], b.info.spine);
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
          // the book's highlights, in reading order: one opens its page
          if (marks.isNotEmpty) ...[
            const Padding(
              padding: EdgeInsets.fromLTRB(4, 18, 4, 4),
              child: Text('Highlights', key: ValueKey('contents.highlights'),
                  style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
            ),
            for (final m in marks)
              ListTile(
                dense: true,
                contentPadding: const EdgeInsets.symmetric(horizontal: 4),
                title: Text(m.text, maxLines: 2, overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 14, fontStyle: FontStyle.italic)),
                onTap: () {
                  pickedMark = m;
                  Navigator.of(c).pop();
                },
              ),
          ],
        ]);
    final mark = pickedMark;
    if (mark != null && !_disposed && _book == b) {
      final ch = b.info.spine.indexOf(mark.chapter);
      if (ch >= 0) {
        host.hideControls();
        _goTo(ch, mark.start);
      }
      return;
    }
    final chosen = picked;
    if (chosen == null || _disposed || _book != b) return;
    final ch = b.chapterOf(chosen.path);
    if (ch == null) return;
    host.hideControls(); // (the remote's focus back on the page, as any other way of hiding them)
    final hash = chosen.href.indexOf('#');
    final at = hash < 0 ? 0 : await _fragmentOr0(b, ch, chosen.href.substring(hash + 1));
    if (!_disposed && _book == b) _goTo(ch, at);
  }

  /// The Aa panel, "eBook settings": what's changed while reading ([epubPanelRows]); the page changes behind it as
  /// they're set.
  Future<void> _settingsPanel() async {
    // the comic reader's panel look: the page stays in view beside it (wide) or above it (narrow), changing live;
    // the controls stay up behind it, as with comics (user, 2026-10-06: the panels as the comics')
    await showReaderPanelFrame(host.context, title: 'eBook settings', children: epubPanelRows);
  }

  // ---- the bars

  final _contentsNode = FocusNode(debugLabel: 'ctl-contents');
  final _settingsNode = FocusNode(debugLabel: 'ctl-settings');

  @override
  List<BarButton> bottomButtons(BuildContext context) => [
        BarButton(_contentsNode,
            barIcon(node: _contentsNode, icon: Icons.toc, label: 'Contents', onPressed: _contents)),
        BarButton(_settingsNode, barIcon(node: _settingsNode, icon: Icons.text_fields,
            label: 'eBook settings', onPressed: _settingsPanel)),
      ];

  // ---- the slider's page pictures (user, 2026-10-11: as the comics' have)

  final _previewLaid = ValueNotifier<int>(0); // a chapter the preview waited for has been laid out
  Timer? _previewWait;
  int? _previewChapter; // the chapter the thumb rests on, to lay out

  /// While a page is being picked on the slider: a small drawing of it (the sheet on a wide screen), its page and
  /// chapter under it. A chapter not laid out yet is laid out once the thumb rests on it a moment (scrubbing across
  /// a dozen chapters doesn't lay them all out); a spinner meanwhile.
  @override
  Widget preview(BuildContext context, int shown, double x) {
    final b = _book!;
    final at = shown.clamp(0, last);
    final (c, p) = b.chapterPage(at);
    final area = _sheet ?? Offset.zero & _size;
    const w = 132.0;
    final h = area.isEmpty ? 196.0 : (w * area.height / area.width).clamp(120.0, 240.0);
    // asked for again once done: a chapter laid out for a preview and let go since (read on elsewhere) is laid out
    // again, and one that failed shows that - it span for ever (audit, 2026-10-11)
    if (b.pagesNow(c) == null && b.errorOf(c) == null && _previewChapter != c) {
      _previewChapter = c;
      _previewWait?.cancel();
      _previewWait = Timer(const Duration(milliseconds: 180), () {
        if (_disposed || _book != b) return;
        b.keepAround(_chapter); // the chapters laid out for earlier previews let go (they were kept)
        unawaited(b.pages(c).then<void>((_) {}, onError: (Object _) {}).whenComplete(() {
          if (_disposed) return;
          if (_previewChapter == c) _previewChapter = null;
          _previewLaid.value++;
        }));
      });
    }
    return Positioned(
      left: x - w / 2,
      top: -h - 60,
      width: w,
      child: IgnorePointer(
        child: Container(
          key: const ValueKey('page-preview'),
          padding: const EdgeInsets.all(4),
          decoration: BoxDecoration(color: const Color(0xF0101012), borderRadius: BorderRadius.circular(8),
              border: Border.all(color: Colors.white24)),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            SizedBox(
              width: w - 8,
              height: h,
              child: ValueListenableBuilder<int>(
                valueListenable: _previewLaid,
                builder: (_, __, ___) {
                  final pages = b.pagesNow(c);
                  if (b.errorOf(c) != null) {
                    return const Center(key: ValueKey('preview-error'),
                        child: Icon(Icons.error_outline, color: Colors.white38));
                  }
                  if (pages == null || pages.isEmpty || area.isEmpty) {
                    return const Center(key: ValueKey('preview-loading'),
                        child: SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2)));
                  }
                  final page = pages[p.clamp(0, pages.length - 1)];
                  return ClipRect(child: FittedBox(
                    fit: BoxFit.contain,
                    // the whole page drawn at the screen's size, shifted so the sheet's part shows: drawn in the
                    // sheet's box it was the sheet's size, its ground covering only part of it (audit, 2026-10-11)
                    child: SizedBox.fromSize(
                      size: area.size,
                      child: OverflowBox(
                        alignment: Alignment.topLeft,
                        minWidth: _size.width,
                        maxWidth: _size.width,
                        minHeight: _size.height,
                        maxHeight: _size.height,
                        child: Transform.translate(
                          offset: -area.topLeft,
                          child: CustomPaint(size: _size, painter: _PagePainter(page, _drawn.background, null)),
                        ),
                      ),
                    ),
                  ));
                },
              ),
            ),
            const SizedBox(height: 4),
            Text('Page ${at + 1}', style: const TextStyle(color: Colors.white, fontSize: 13)),
            Text(_chapterNameOf(c), maxLines: 1, overflow: TextOverflow.ellipsis,
                style: const TextStyle(color: Colors.white70, fontSize: 11)),
          ]),
        ),
      ),
    );
  }

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
      left: SpotText('Book · Pg. ${_pagesText(at)}/${b.totalPages} · $pct%', 'book page'),
      centre: SpotText(_chapterNameOf(c), 'chapter'),
      // no chapter number: the book's file count, not the chapter's own ("Ch. 4" under "Chapter One" - user, 2026-10-07)
      right: SpotText('Ch. · Pg. ${p + 1}/${b.pageCount(c)}', 'chapter page'),
    );
  }

  /// The page number at [place] - two pages up, both of the spread shown there: "4-5".
  String _pagesText(int place) {
    if (!_dual || place > last || _spreadOf.isEmpty) return '${place + 1}';
    final s = _spreads[_spreadOf[place]];
    return s.pages.length == 1 ? '${s.first + 1}' : '${s.first + 1}-${s.last + 1}';
  }

  @override
  String corner(int place) => '${_pagesText(place.clamp(0, last))} / ${_book!.totalPages}';
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
    Future<Object?> markRead() async {
      await api.markRead(id);
      return p.place();
    }
    final b = _book!;
    // the place to save: [place], a page of this layout - or, while the book is being laid out again (a new size or
    // setting: on the tablet, Search's keyboard coming back up as Back closed the book), the place kept through it.
    // [place] reads 0 then: closing saved the book's start over the page reached (tablet, build 99), or failed.
    final EpubPosition at;
    if (_ready) {
      if (place > last) return markRead; // the end card: the book is read
      final (c, pg) = b.chapterPage(place);
      at = b.positionOf(c, pg);
    } else if (_end) {
      return markRead;
    } else if (_anchor != null) {
      at = _anchor!;
    } else {
      return p.place; // still opening: nothing of this reader's to save - Komga's place read back, nothing written
    }
    final c = at.chapter;
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
        final ink = _drawn.text;
        return _paper(_drawn.background, surround: true,
          child: Center(child: Column(mainAxisSize: MainAxisSize.min, children: [
            const SizedBox(width: 36, height: 36, child: CircularProgressIndicator(strokeWidth: 3)),
            const SizedBox(height: 20),
            // the first time in these settings and this page size, and again after a change (user, 2026-10-08)
            Text('Adjusting and storing layout', style: TextStyle(color: ink.withValues(alpha: 0.8), fontSize: 16)),
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
          if (!_ready) return _paper(_drawn.background, surround: true); // laid out again: the spinner next frame
          final here = _end ? -1 : _viewOf(place);
          // text selection (user, 2026-10-08): the page on screen is selectable; Flutter's selection area gives the
          // long press / mouse drag, the handles, the menu (Copy only, for now), Select all and Ctrl+C
          return SelectionArea(
            key: _selectionArea,
            focusNode: _selectionFocus,
            // the selection's pane is the page's own ([_selectionPane]), the same everywhere - Flutter's menu was a
            // right-click menu on Windows (user, 2026-10-12: "make it more like the tablet version")
            contextMenuBuilder: (_, __) => const SizedBox.shrink(),
            onSelectionChanged: (c) {
              _selectedText = c?.plainText ?? '';
              _selected.value = _selectedText.isNotEmpty;
              _selectionMoved.value++;
            },
            child: Builder(builder: (context) {
              final registrar = SelectionContainer.maybeOf(context);
              // fingers and mouse buttons down: the pane waits for them to let go (a selection being made)
              // - and a mouse click is told here, as the button down and up within a few pixels: in the gestures
              // a mouse moved a pixel or two while pressed is a drag, and the selection's drag took it - clicks went
              // missing (user, build 107: "having to click a couple times to get page controls up")
              return Listener(
                onPointerDown: (e) {
                  _pressed.value++;
                  if (e.kind == PointerDeviceKind.mouse && e.buttons == kPrimaryMouseButton) {
                    _mouseDown = e.position;
                    _mouseDownSelected = _selected.value;
                  }
                  _rightDown = e.buttons == kSecondaryButton; // (a mouse, or a pen's side button)
                },
                onPointerUp: (e) {
                  _pressed.value = math.max(0, _pressed.value - 1);
                  // a right-click: the controls, however far the mouse moved meanwhile - a right drag means nothing
                  // here, and past Flutter's 18 px the click was lost (user, build 108: "right clicks get missed if
                  // the mouse moves"). With text selected it's the selection's (its pane is up).
                  if (_rightDown) {
                    _rightDown = false;
                    if (!_selected.value) host.toggleControls();
                    return;
                  }
                  final from = _mouseDown;
                  _mouseDown = null;
                  if (e.kind == PointerDeviceKind.mouse && from != null && (e.position - from).distance < _clickSlop) {
                    _mouseClick(TapUpDetails(kind: PointerDeviceKind.mouse, globalPosition: e.position,
                        localPosition: e.localPosition), size);
                  }
                },
                onPointerCancel: (_) {
                  _pressed.value = math.max(0, _pressed.value - 1);
                  _mouseDown = null;
                  _rightDown = false;
                },
                child: Stack(key: _pageStack, children: [
            // on a wide screen the surround, still under the sliding sheets (user, 2026-10-11)
            if (_sheet != null) Positioned.fill(child: ColoredBox(color: surround(_drawn.background))),
            // the page view kept out of the selection (see SelectablePage): only the page on screen takes part
            SelectionContainer.disabled(child: RepaintBoundary(key: _curl.boundary, child: PageView.builder(
              controller: _pc,
              // Curl: a drag curls the page instead of sliding it (below)
              physics: _curlMode ? const NeverScrollableScrollPhysics() : null,
              itemCount: _views + 1, // + the end card
              onPageChanged: _onPageChanged,
              // the pages either side built ahead, as the comic reader's are: a tap's turn no longer builds the
              // incoming page in its first frame (most tap turns missed one refresh there - measured on the
              // tablet, build 76; swipes and comics didn't)
              allowImplicitScrolling: true,
              // each page drawn once and kept as a picture: sliding moves it, rather than drawing every line
              // of both pages again each frame
              itemBuilder: (_, v) => RepaintBoundary(child: _dual
                  ? _spreadAt(v, v == here ? registrar : null)
                  : _pageAt(v, size, v == here ? registrar : null)),
            ))),
            // the page turning over (Curl)
            if (_curlMode) Positioned.fill(child: _curl.overlay()),
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
            ValueListenableBuilder<bool>(
              valueListenable: _selected,
              // the page's taps win every tap over the selection area's (they're first in the arena), so a tap
              // never starts a double tap that selects - quick taps turn pages as before
              builder: (_, selected, __) => Positioned.fill(child: GestureDetector(
                behavior: HitTestBehavior.translucent,
                // (a mouse's clicks are told by the Listener above)
                onTapUp: (d) => d.kind == PointerDeviceKind.mouse ? null : _tap(d, size),
                onHorizontalDragStart: _curlMode && !selected ? (d) => _curl.dragStart(d, pages: _views + 1) : null,
                onHorizontalDragUpdate: _curlMode && !selected ? (d) => _curl.dragUpdate(d, size) : null,
                onHorizontalDragEnd: _curlMode && !selected ? _curl.dragEnd : null,
                // right-click: the controls, told by the Listener above (any distance); claimed here only so the
                // selection area doesn't take it to select a word - with text selected it's the selection's
                onSecondaryTap: selected ? null : () {},
              )),
            ),
          ]));
            }),
          );
        })),
        // the selection's pane, over the page - outside the selection area and the presses counted on the page: a
        // click on one of its buttons hid it (a press on the page hides it) and, on Windows, let go of the selection,
        // so the button never got its click (user, build 106: "whether i click highlight or define, nothing
        // happens"); inside the area its labels were text too, and the area, seeing them come, set the selection's
        // ends again letter by letter
        Positioned.fill(child: ListenableBuilder(
          listenable: Listenable.merge([_selected, _pressed, _selectionMoved]),
          builder: (context, _) => _selectionPane(context),
        )),
      ];

  // ---- selecting text

  final _selectionArea = GlobalKey<SelectionAreaState>();
  final _selected = ValueNotifier<bool>(false); // text is selected on the page
  String _selectedText = '';

  /// The selection area's focus: Esc lets go of the selection first (then it closes the book, as before).
  late final _selectionFocus = FocusNode(debugLabel: 'epub-selection', onKeyEvent: (_, e) {
    if (e is KeyDownEvent && e.logicalKey == LogicalKeyboardKey.escape && _selected.value) {
      _clearSelection();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  });

  /// Lets go of the selection (and its handles and menu).
  void _clearSelection() {
    if (!_selected.value) return;
    _selected.value = false;
    _selectionArea.currentState?.selectableRegion.clearSelection();
  }

  final _pageStack = GlobalKey(debugLabel: 'epub-page-stack');
  final _pressed = ValueNotifier<int>(0); // fingers / mouse buttons down on the page
  final _selectionMoved = ValueNotifier<int>(0); // the selection changed (its pane goes with it)

  /// The selection's pane of actions, over it once the finger or the mouse button lets go - the tablet's look on every
  /// device (user, 2026-10-12: on Windows it took a right-click, and looked "ugly"): Copy (2026-10-08), Highlight, or
  /// Remove highlight where the selection covers one (2026-10-12: there was no way to it from a selection), and
  /// Define for a word or a short phrase (2026-10-11: the offline English dictionary).
  Widget _selectionPane(BuildContext context) {
    if (!_selected.value || _pressed.value > 0) return const SizedBox.shrink();
    final stack = _pageStack.currentContext?.findRenderObject();
    final range = _selectedRange;
    if (stack is! RenderBox || range == null) return const SizedBox.shrink();
    // the selection's boxes on the page area (two pages up: on either page, or both)
    Rect? box;
    for (final r in _shownRenders) {
      for (final rect in r.value.selectionRects) {
        final onStack = Rect.fromPoints(r.localToGlobal(rect.topLeft, ancestor: stack),
            r.localToGlobal(rect.bottomRight, ancestor: stack));
        box = box == null ? onStack : box.expandToInclude(onStack);
      }
    }
    if (box == null) return const SizedBox.shrink();
    final topLeft = box.topLeft, bottomRight = box.bottomRight;
    final selected = _selectedText;
    final covered = _highlights?.within(_chapterFile(_chapter), range.$1, range.$2) ?? const <Highlight>[];
    final whole = covered.any((h) => h.start <= range.$1 && h.end >= range.$2); // all of it highlighted already
    final items = <(String, VoidCallback)>[
      ('Copy', () {
        unawaited(Clipboard.setData(ClipboardData(text: selected)));
        _clearSelection();
      }),
      if (!whole) ('Highlight', _highlightSelection),
      if (covered.isNotEmpty)
        ('Remove highlight', () {
          for (final h in covered) {
            unawaited(_highlights?.remove(h));
          }
          _clearSelection();
        }),
      if (definable(selected))
        ('Define', () {
          _clearSelection();
          unawaited(showDefinition(context, selected));
        }),
    ];
    final mid = (topLeft.dx + bottomRight.dx) / 2;
    return TextSelectionToolbar(
      key: const ValueKey('epub-selection-pane'),
      anchorAbove: Offset(mid, topLeft.dy - 6),
      anchorBelow: Offset(mid, bottomRight.dy + 30), // below the handles
      children: [
        for (final (i, (label, act)) in items.indexed)
          TextSelectionToolbarTextButton(
            padding: TextSelectionToolbarTextButton.getPadding(i, items.length),
            onPressed: act,
            child: Text(label),
          ),
      ],
    );
  }

  /// The word at [global] (screen coordinates) selected - a double tap or double click (user, 2026-10-12).
  void _selectWordAt(Offset global) {
    // the page under the pointer (two pages up, either)
    RenderSelectablePage? render;
    for (final r in _shownRenders) {
      if ((Offset.zero & r.size).contains(r.globalToLocal(global))) render = r;
    }
    if (render == null) return;
    render.dispatchSelectionEvent(SelectWordSelectionEvent(globalPosition: global));
    _selectedText = render.getSelectedContent()?.plainText ?? '';
    _selected.value = _selectedText.isNotEmpty;
    _selectionMoved.value++;
    if (_selected.value) _selectionFocus.requestFocus(); // (Esc lets go of it)
  }

  @override
  void controlsShown() => _clearSelection();

  // ---- highlights (user, 2026-10-11: one colour, synced through Komga, no notes)

  BookHighlights? _highlights;
  final _shownPage = GlobalKey(debugLabel: 'epub-page-on-screen'); // (two pages up: the earlier, left one)
  final _shownLater = GlobalKey(debugLabel: 'epub-later-page-on-screen'); // two pages up: the later, right one

  /// The pages on screen that take part in the selection (two pages up, both).
  List<RenderSelectablePage> get _shownRenders => [
        for (final k in [_shownPage, if (_dual) _shownLater])
          if (k.currentContext?.findRenderObject() case final RenderSelectablePage r when r.attached) r,
      ];

  /// What's selected, in the chapter's characters - across both pages, two pages up (a spread is one chapter).
  (int, int)? get _selectedRange {
    (int, int)? range;
    for (final r in _shownRenders) {
      final p = r.selectedPositions;
      if (p == null) continue;
      range = range == null ? p : (math.min(range.$1, p.$1), math.max(range.$2, p.$2));
    }
    return range;
  }

  /// The chapter file [chapter] is, in the book (what a highlight is kept against).
  String _chapterFile(int chapter) => _book!.info.spine[chapter];

  /// The highlights on [page] of [chapter], as boxes to draw.
  List<Rect> _marksOn(EpubPage page, int chapter) {
    final h = _highlights;
    if (h == null || h.items.isEmpty) return const [];
    final file = _chapterFile(chapter);
    return [
      for (final m in h.items)
        if (m.chapter == file) ...page.text.boxesOfPositions(m.start, m.end),
    ];
  }

  /// The one highlight colour: the app's accent (user, 2026-10-12: it was a fixed marker yellow), stronger on a light
  /// page than on a dark one.
  static Color _markColour(Color accent, Color page) =>
      accent.withValues(alpha: page.computeLuminance() > 0.3 ? 0.45 : 0.3);

  /// The highlight under [at] on [page] (on screen), if any.
  Highlight? _highlightAt(EpubPage page, Offset at) {
    final h = _highlights;
    if (h == null || h.items.isEmpty) return null;
    final file = _chapterFile(_chapter);
    for (final m in h.items) {
      if (m.chapter != file) continue;
      if (page.text.boxesOfPositions(m.start, m.end).any((r) => r.inflate(4).contains(at))) return m;
    }
    return null;
  }

  /// The selection, highlighted (one taken in with any it overlaps); the selection let go of.
  void _highlightSelection() {
    final range = _selectedRange;
    if (range != null && _highlights != null) {
      unawaited(_highlights!.add(Highlight(_chapterFile(_chapter), range.$1, range.$2, _selectedText.trim())));
    }
    _clearSelection();
  }

  /// A tapped highlight's menu: Copy its words, or Remove it.
  Future<void> _highlightMenu(Highlight h, Offset at) async {
    final context = host.context;
    final choice = await showMenu<String>(
      context: context,
      position: RelativeRect.fromLTRB(at.dx, at.dy, at.dx, at.dy),
      items: const [
        PopupMenuItem(value: 'copy', child: Text('Copy')),
        PopupMenuItem(value: 'remove', child: Text('Remove highlight')),
      ],
    );
    if (_disposed) return;
    if (choice == 'copy') await Clipboard.setData(ClipboardData(text: h.text));
    if (choice == 'remove') await _highlights?.remove(h);
  }

  /// The page's sheet now (null: the page fills the screen).
  // the sheet of the settings the book is laid out in: while new ones settle ([settleDelay]) the page is drawn as it
  // was, and the sheet with it (it took the new margins at once, the text running over its edge - audit, 2026-10-11)
  // Inset page never on this device (Settings > eBooks > Screen): none - the page's colour across the screen, the lines
  // as long and as placed (user, 2026-10-11); always: the card the text was laid out in, likewise once laid out
  Rect? get _sheet => _sheetFor();

  /// [page]'s sheet - round its own text (Margins: Book's: its chapter's sides); no page: round the text of a page of
  /// this layout (the margins it's laid out in: while new ones settle, the page is drawn as it was, sheet and all).
  Rect? _sheetFor([EpubPage? page]) {
    final b = _book;
    if (b == null || b.size == Size.zero) return null;
    final m = b.theme.margins;
    final text = page?.textArea ?? Rect.fromLTRB(m.left, m.top, b.size.width - m.right, b.size.height - m.bottom);
    final d = AppSettings.instance.display;
    return sheetRect(text, b.size, _laidInset ?? d.insetPage, _area, gap: d.insetGap, ends: d.insetGapEnds);
  }
  InsetPage? _laidInset;

  /// A page's paper with [child] on it: the whole area, or the sheet - with the surround round it when [surround] (a
  /// page in the page view leaves that to the one still surround under them all).
  Widget _paper(Color background, {Widget? child, bool surround = false}) => Stack(fit: StackFit.expand, children: [
        if (surround && _sheet != null) ColoredBox(color: EpubRenderer.surround(background)),
        CustomPaint(painter: _PagePainter(null, background, _sheet)),
        if (child != null) child,
      ]);

  Widget _pageAt(int i, Size size, [SelectionRegistrar? registrar, GlobalKey? key]) {
    final b = _book!;
    final theme = _drawn;
    if (i >= b.totalPages!) return host.endCard();
    final (c, p) = b.chapterPage(i);
    final pages = b.pagesNow(c);
    if (pages == null) {
      if (b.errorOf(c) != null) return _chapterError(b, c, theme);
      // the page on screen: laid out now (a failure shows here, with Retry); a neighbour built ahead (implicit
      // scrolling): after the usual pause, so its layout doesn't land in the next turn
      final onScreen = !_pc.hasClients || _pc.page == null || _pc.page!.round() == _viewOf(i);
      if (onScreen) {
        unawaited(b.pages(c).then<void>((_) {}, onError: (Object _) {}));
      } else {
        _prefetch(c);
      }
      return _paper(theme.background, child: const Center(child: CircularProgressIndicator()));
    }
    final page = pages[p.clamp(0, pages.length - 1)];
    return SelectablePage(
      key: registrar != null ? key ?? _shownPage : null,
      page: page,
      registrar: registrar,
      colour: theme.accent.withValues(alpha: 0.35),
      child: CustomPaint(size: size, painter: _PagePainter(page, theme.background, _sheetFor(page),
          marks: _marksOn(page, c), markColour: _markColour(theme.accent, theme.background))),
    );
  }

  /// Two pages up: spread [v] - the earlier page on the left, the later on the right, each a page wide; a side with
  /// no page (a chapter starts on the right, ends where it ends) blank paper. With sheets (Inset page) two apart, each
  /// round its text; without, the pages touch, a shade down the gutter.
  Widget _spreadAt(int v, SelectionRegistrar? registrar) {
    if (v >= _spreads.length) return host.endCard();
    final s = _spreads[v];
    Widget side(int? page, {required bool later}) => SizedBox.fromSize(
          size: _size,
          child: Transform.translate(
            offset: Offset(_sideShift(later: later), 0),
            child: page == null
                ? _paper(_drawn.background)
                : _pageAt(page, _size, registrar, later ? _shownLater : _shownPage),
          ),
        );
    return Stack(children: [
      // (the window just narrowed, one page up from the next frame ([_layout]): the pair clipped till then)
      ClipRect(child: OverflowBox(
        alignment: Alignment.topLeft,
        maxWidth: 2 * _size.width,
        child: Row(children: [side(s.earlier, later: false), side(s.later, later: true)]),
      )),
      // the pages touching (no Inset page): a shade down the gutter; as sheets they're apart (below)
      if (_sheet == null) Positioned(
        left: _size.width - 14,
        width: 28,
        top: 0,
        bottom: 0,
        child: IgnorePointer(child: DecoratedBox(decoration: BoxDecoration(gradient: LinearGradient(colors: [
          const Color(0x00000000),
          Color.fromRGBO(0, 0, 0, _drawn.background.computeLuminance() > 0.3 ? 0.10 : 0.22),
          const Color(0x00000000),
        ])))),
      ),
    ]);
  }

  /// Two pages up: side [later]'s page (its sheet, or the whole page) on the page area. With Inset page the two are
  /// apart (user, 2026-10-16: "two discrete pages, with a gap between"), each round its own text.
  Rect _sideRect({required bool later}) =>
      (_sheet ?? Offset.zero & _size).shift(Offset((later ? _size.width : 0) + _sideShift(later: later), 0));

  /// Two pages up with Inset page: how far side [later] (else the earlier, left) slides, sheet and text together, so
  /// the two sheets are [DisplayPrefs.insetBetween] apart (user, 2026-10-16: "a fixed distance" - each keeps the same
  /// gap round its text); 0 with no sheet (the pages touch).
  double _sideShift({required bool later}) {
    final s = _sheet;
    if (s == null) return 0;
    final half = AppSettings.instance.display.insetBetween / 2;
    return later ? half - s.left : _size.width - half - s.right;
  }

  /// A chapter that couldn't be loaded or laid out: why, and Retry (never a spinner for good).
  Widget _chapterError(EpubBook b, int chapter, EpubTheme theme) => _paper(
        theme.background,
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

/// The picture over the book: fitted to 95% of the screen (enlarged if small), pinch or wheel to zoom; a tap, Back,
/// Esc or OK closes it. A button in each top corner of the screen turns it a quarter - left: counterclockwise,
/// right: clockwise (user, 2026-10-08; buttons only, no key, not kept). The remote reaches them with Left / Right.
class _PictureView extends StatefulWidget {
  const _PictureView({required this.image});
  final ui.Image image; // its own handle: let go of with the view

  /// The share of the screen the picture's area takes (user: "instead of going full screen, go like 95%").
  static const share = 0.95;

  @override
  State<_PictureView> createState() => _PictureViewState();
}

class _PictureViewState extends State<_PictureView> {
  int _turns = 0; // quarter turns clockwise, 0..3
  final _ccw = FocusNode(), _cw = FocusNode(); // the remote: Left / Right go to them, OK presses the one focused

  void _turn(int by) => setState(() => _turns = (_turns + by) % 4);

  @override
  void dispose() {
    _ccw.dispose();
    _cw.dispose();
    widget.image.dispose();
    super.dispose();
  }

  /// The picture at [area], turned: fitted in it, centred.
  Widget _picture(Size area) {
    final w = widget.image.width.toDouble(), h = widget.image.height.toDouble();
    final (iw, ih) = _turns.isOdd ? (h, w) : (w, h);
    final scale = math.min(area.width / iw, area.height / ih);
    final shown = Size(iw * scale, ih * scale);
    return SizedBox.fromSize(
      size: area,
      child: InteractiveViewer(
        maxScale: 6,
        child: Center(
          child: SizedBox.fromSize(
            size: shown,
            child: RotatedBox(
              key: const ValueKey('picture.turned'),
              quarterTurns: _turns,
              child: RawImage(image: widget.image, fit: BoxFit.fill, filterQuality: FilterQuality.medium),
            ),
          ),
        ),
      ),
    );
  }

  /// A rotate button: in a top corner of the screen, where it stays as the picture turns (user, 2026-10-08: on the
  /// picture's corners they moved with it, "which makes it annoying").
  Widget _button(String key, FocusNode node, IconData icon, String tip, int by) => Material(
        key: ValueKey(key),
        color: Colors.black.withValues(alpha: 0.55),
        shape: const CircleBorder(),
        child: IconButton(focusNode: node, tooltip: tip, color: Colors.white, icon: Icon(icon),
            onPressed: () => _turn(by)),
      );

  @override
  Widget build(BuildContext context) => Focus(
        autofocus: true,
        onKeyEvent: (_, e) {
          if (e is! KeyDownEvent) return KeyEventResult.ignored;
          final k = e.logicalKey;
          if (k == LogicalKeyboardKey.arrowLeft || k == LogicalKeyboardKey.arrowRight) {
            (k == LogicalKeyboardKey.arrowLeft ? _ccw : _cw).requestFocus();
            return KeyEventResult.handled;
          }
          final ok = k == LogicalKeyboardKey.enter || k == LogicalKeyboardKey.select ||
              k == LogicalKeyboardKey.numpadEnter;
          if (ok && (_ccw.hasFocus || _cw.hasFocus)) {
            _turn(_ccw.hasFocus ? 3 : 1); // OK on a rotate button presses it
            return KeyEventResult.handled;
          }
          if (ok || k == LogicalKeyboardKey.escape) {
            Navigator.of(context).pop();
            return KeyEventResult.handled;
          }
          return KeyEventResult.ignored;
        },
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () => Navigator.of(context).pop(),
          child: SafeArea(
            child: Stack(children: [
              Positioned.fill(child: LayoutBuilder(builder: (context, box) => Center(child: _picture(
                  Size(box.maxWidth * _PictureView.share, box.maxHeight * _PictureView.share))))),
              Positioned(left: 12, top: 12,
                  child: _button('picture.rotate.ccw', _ccw, Icons.rotate_90_degrees_ccw, 'Rotate left', 3)),
              Positioned(right: 12, top: 12,
                  child: _button('picture.rotate.cw', _cw, Icons.rotate_90_degrees_cw, 'Rotate right', 1)),
            ]),
          ),
        ),
      );
}

/// A page: its paper - the whole area, or a [sheet] with a soft shadow each side (the surround behind is the reader's,
/// still while sheets slide over it) - and its text and pictures ([page]; none: paper only, under a spinner or such).
class _PagePainter extends CustomPainter {
  _PagePainter(this.page, this.background, this.sheet, {this.marks = const [], this.markColour});
  final EpubPage? page;
  final Color background;
  final Rect? sheet;

  /// Highlights on the page: drawn under the text, like a marker's ink.
  final List<Rect> marks;
  final Color? markColour;
  @override
  void paint(Canvas c, Size size) {
    final s = sheet;
    if (s == null) {
      c.drawRect(Offset.zero & size, Paint()..color = background);
    } else {
      final light = background.computeLuminance() > 0.3;
      c.drawRect(s.inflate(2), Paint()
        ..color = Color.fromRGBO(0, 0, 0, light ? 0.22 : 0.5)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 10));
      c.drawRect(s, Paint()..color = background);
    }
    if (marks.isNotEmpty && markColour != null) {
      final ink = Paint()..color = markColour!;
      for (final r in marks) {
        c.drawRect(r, ink);
      }
    }
    final pieces = page?.pieces;
    if (pieces != null) {
      for (final p in pieces) {
        p.paint(c);
      }
    }
  }

  @override
  bool shouldRepaint(_PagePainter old) => old.page != page || old.background != background || old.sheet != sheet ||
      !listEquals(old.marks, marks) || old.markColour != markColour;
}
