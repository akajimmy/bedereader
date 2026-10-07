/// A whole EPUB laid out for one page size and theme: every chapter's page count and page starts (so "page X of Y"
/// and a slider over the whole book work), the full pages kept only for the chapters near the one being read.
library;

import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';

import 'chapter.dart';
import 'hyphenator.dart';
import 'layout.dart';
import 'source.dart';
import 'trace.dart';

class _Chapter {
  LoadedChapter? content;
  Paginator? paginator;
  List<EpubPage>? pages; // laid out: kept near the reading position only
  List<int>? starts; // every page's start, once counted (kept)
  int length = 0; // characters
  Future<List<EpubPage>>? laying;
  Future<LoadedChapter>? loading; // its text on the way (one load shared by everyone waiting for it)
  Object? error; // the last try failed (shown with Retry; the next try loads it afresh)
}

/// Where the reader is: a chapter and a position (characters) in it.
@immutable
class EpubPosition {
  const EpubPosition(this.chapter, this.position);
  final int chapter;
  final int position;
  @override
  bool operator ==(Object other) => other is EpubPosition && other.chapter == chapter && other.position == position;
  @override
  int get hashCode => Object.hash(chapter, position);
  @override
  String toString() => 'EpubPosition($chapter, $position)';
}

class EpubBook extends ChangeNotifier {
  EpubBook(this.source, this.info, this.hyphenators)
      : loader = ChapterLoader(source),
        _chapters = List.generate(info.spine.length, (_) => _Chapter());

  final EpubSource source;
  final EpubInfo info;
  final Hyphenators hyphenators;
  final ChapterLoader loader;
  final List<_Chapter> _chapters;

  EpubTheme _theme = const EpubTheme();
  Size _size = Size.zero;
  int _generation = 0; // a new theme or size: everything laid out before is out of date

  /// How many chapters stay laid out either side of the one being read (2: a page being turned away from, or one
  /// the page view still holds, is never let go of - see [_retire]).
  static const around = 2;

  /// Lets go of a chapter's laid-out text and pictures two frames from now, not at once: a page still on screen (or
  /// in the frame being drawn) must not be drawn from freed text or pictures. A crash in Flutter's engine on the PC
  /// after turning back and forth (build 66, "illegal instruction" in flutter_windows.dll) was most likely that.
  void _retire(Paginator? p, LoadedChapter? content) {
    if (p == null && content == null) return;
    void free() {
      p?.dispose();
      content?.dispose();
    }
    final binding = SchedulerBinding.instance;
    binding.addPostFrameCallback((_) => binding.addPostFrameCallback((_) => free()));
    binding.scheduleFrame();
  }

  /// The book's own text size ([bookTextSize]), found by [measureTextSize] before the first layout: shown at the
  /// reader's size, the book's other sizes in proportion.
  double textSize = 1;

  /// Whether the book's text is bold all through ([bookTextBold]), found with [textSize].
  bool textBold = false;

  /// Finds [textSize] from up to [samples] chapters spread through the book (the front and back matter left out where
  /// there's room) - loaded here, kept for laying out. A chapter that can't be loaded is skipped.
  Future<void> measureTextSize({int samples = 5}) async {
    final n = _chapters.length;
    final picks = n <= samples
        ? [for (var i = 0; i < n; i++) i]
        : {for (var k = 0; k < samples; k++) (n * (0.2 + 0.6 * k / (samples - 1))).floor().clamp(0, n - 1)}.toList();
    final sampled = <List<Block>>[];
    for (final i in picks) {
      try {
        final c = _chapters[i];
        final content = await _content(i);
        c.length = content.length;
        sampled.add(content.blocks);
      } catch (_) {
        // can't be read: not counted (it shows its error when reached)
      }
    }
    textSize = bookTextSize(sampled);
    textBold = bookTextBold(sampled);
    EpubTrace.instance.log('book text size $textSize (from chapters $picks)');
  }

  int get chapterCount => _chapters.length;
  EpubTheme get theme => _theme;
  Size get size => _size;

  /// Lays the book out for [theme] at [size] from now on (what was laid out before is let go of).
  void setLayout(EpubTheme theme, Size size) {
    if (theme == _theme && size == _size) return;
    EpubTrace.instance.log('layout ${size.width.round()}x${size.height.round()} font ${theme.fontFamily} '
        '${theme.fontSize} (was ${_size.width.round()}x${_size.height.round()})');
    _theme = theme;
    _size = size;
    _generation++;
    for (final c in _chapters) {
      _retire(c.paginator, null);
      c
        ..paginator = null
        ..pages = null
        ..starts = null
        ..laying = null;
    }
    notifyListeners();
  }

  /// The pages of chapter [i], laid out if they aren't (null if the layout changed meanwhile).
  Future<List<EpubPage>?> pages(int i) async {
    final c = _chapters[i];
    if (c.pages != null) return c.pages;
    final gen = _generation;
    try {
      final laying = c.laying ??= _lay(i, gen);
      final pages = await laying;
      // the try is over: forgotten here, not inside _lay - laid out at once (its text already loaded, after a new
      // layout) _lay finished before ??= stored its future, which then stayed: the chapter, let go of later, was
      // "laid out" from it again - freed pages, the reader on a spinner for good (user, build 69)
      if (identical(c.laying, laying)) c.laying = null;
      return gen == _generation ? pages : null;
    } catch (e) {
      // a failed try isn't kept: the chapter stuck on a spinner for good when it was (user, build 65 on the PC,
      // turning quickly) - the error is shown with Retry, and the next try loads it afresh
      EpubTrace.instance.log('chapter $i failed: $e');
      c
        ..laying = null
        ..error = e;
      notifyListeners();
      rethrow;
    }
  }

  /// Why chapter [i] couldn't be shown the last time it was tried (null: it's fine, or not tried).
  Object? errorOf(int i) => _chapters[i].error;

  /// Forget chapter [i]'s failure (Retry): the next [pages] loads it afresh.
  void retry(int i) {
    _chapters[i].error = null;
    notifyListeners();
  }

  /// Chapter [i]'s pages if they're laid out now (no waiting).
  List<EpubPage>? pagesNow(int i) => _chapters[i].pages;

  Future<List<EpubPage>> _lay(int i, int gen) async {
    final c = _chapters[i];
    final clock = Stopwatch()..start();
    final loaded = c.content == null;
    final content = await _content(i);
    final readMs = clock.elapsedMilliseconds;
    c.length = content.length;
    if (gen != _generation) return const [];
    // the layout runs in one go on the UI thread: as long as it takes, frames wait (timed for the trace: a page turn
    // that stutters at a chapter's start shows here - user, 2026-10-06, "not smooth in the way that comics are")
    final laying = Stopwatch()..start();
    final p = Paginator(_theme, _size, _theme.hyphenate ? hyphenators.forLang(content.lang) : null,
        baseSize: textSize, baseBold: textBold);
    final pages = p.run(content.blocks);
    if (gen != _generation) {
      p.dispose(); // never shown
      return const [];
    }
    EpubTrace.instance.log('chapter $i laid out: ${pages.length} pages in ${laying.elapsedMilliseconds} ms'
        '${loaded ? ' (read in $readMs ms)' : ''}');
    // counted before with another number of pages (it failed while counting, say): the book's page numbers after
    // it move - the reader goes back to the same page (EPUB review R5)
    if (c.starts != null && c.starts!.length != pages.length) countChanges++;
    c
      ..paginator = p
      ..pages = pages
      ..starts = [for (final pg in pages) pg.start]
      ..error = null;
    notifyListeners();
    return pages;
  }

  /// Keeps the pages of the chapters around [current] and lets go of the rest (their counts stay).
  void keepAround(int current) {
    final gone = <int>[];
    for (var i = 0; i < _chapters.length; i++) {
      if ((i - current).abs() <= around) continue;
      final c = _chapters[i];
      if (c.pages == null) continue;
      _retire(c.paginator, c.content);
      c
        ..paginator = null
        ..pages = null
        ..content = null
        ..laying = null; // (a finished try: never the way back to these pages)
      gone.add(i);
    }
    if (gone.isNotEmpty) EpubTrace.instance.log('around chapter $current: let go of $gone');
  }

  /// Counts every chapter's pages (in the background after the book opens): lays each out and lets it go again
  /// unless it's near [current]. Stops if the layout changes; [progress] after each chapter.
  /// [busy]: the reader is in the middle of turning pages - counting waits (laying a chapter out holds the screen
  /// up for a moment, and turns stuttered while a big book was being counted - user, 2026-10-06).
  Future<void> countAll({required int Function() current, bool Function()? busy}) async {
    final gen = _generation;
    for (var i = 0; i < _chapters.length; i++) {
      if (gen != _generation) return;
      if (_chapters[i].starts != null) continue;
      try {
        await pages(i);
      } catch (_) {
        // a chapter that can't be read: counted as one page (it shows the error when reached) - in this layout only
        // (one from a layout before landed in the new one's count), and told (it could be the last one counted)
        if (gen == _generation && _chapters[i].starts == null) {
          _chapters[i].starts = [0];
          notifyListeners();
        }
      }
      if (gen != _generation) return;
      final cur = current();
      if ((i - cur).abs() > around) keepAround(cur);
      // a breath between chapters, and none at all while pages are being turned
      await _rest(const Duration(milliseconds: 16));
      for (var waits = 0; busy != null && busy() && waits < 50; waits++) {
        await _rest(const Duration(milliseconds: 100));
        if (gen != _generation) return;
      }
    }
  }

  // counting's pause: cancelled when the book closes (the counting then just stops where it was)
  Timer? _pause;
  Future<void> _rest(Duration d) {
    final done = Completer<void>();
    _pause = Timer(d, done.complete);
    return done.future;
  }

  /// Every chapter counted: the whole book's page numbers are known.
  bool get counted => _chapters.every((c) => c.starts != null);

  int? pageCount(int chapter) => _chapters[chapter].starts?.length;

  /// Chapter [chapter]'s length in characters (0 until it has been loaded).
  int lengthOf(int chapter) => _chapters[chapter].length;

  /// The whole book's page count (null until counted).
  int? get totalPages => counted ? _chapters.fold<int>(0, (n, c) => n + c.starts!.length) : null;

  /// The book-wide page index of [chapter]'s page [page] (null until the chapters before it are counted).
  int? bookPage(int chapter, int page) {
    var n = 0;
    for (var i = 0; i < chapter; i++) {
      final s = _chapters[i].starts;
      if (s == null) return null;
      n += s.length;
    }
    return n + page;
  }

  /// The chapter and page of the book-wide page [index] (all counted).
  (int, int) chapterPage(int index) {
    var n = index;
    for (var i = 0; i < _chapters.length; i++) {
      final len = _chapters[i].starts!.length;
      if (n < len) return (i, n);
      n -= len;
    }
    return (_chapters.length - 1, _chapters.last.starts!.length - 1);
  }

  /// The page of [chapter] at [position] (from its counted starts; 0 if not counted yet).
  int pageAt(int chapter, int position) {
    final s = _chapters[chapter].starts;
    if (s == null) return 0;
    var i = 0;
    while (i + 1 < s.length && s[i + 1] <= position) {
      i++;
    }
    return i;
  }

  /// Where page [page] of [chapter] starts.
  EpubPosition positionOf(int chapter, int page) {
    final s = _chapters[chapter].starts;
    return EpubPosition(chapter, s == null || s.isEmpty ? 0 : s[page.clamp(0, s.length - 1)]);
  }

  /// The chapter [fraction] (0..1) of the way through the book falls in, and how far through that chapter (0..1) -
  /// [progression] the other way round.
  (int, double) chapterAtFraction(double fraction) {
    final n = _chapters.length;
    final f = fraction.clamp(0.0, 1.0);
    final lengths = _weights;
    if (lengths == null) {
      final at = f * n;
      final i = at.floor().clamp(0, n - 1);
      return (i, (at - i).clamp(0.0, 1.0));
    }
    final total = lengths.fold(0, (a, b) => a + b);
    var before = 0;
    for (var i = 0; i < n; i++) {
      if (f * total < before + lengths[i] || i == n - 1) {
        return (i, ((f * total - before) / lengths[i]).clamp(0.0, 1.0));
      }
      before += lengths[i];
    }
    return (n - 1, 1);
  }

  /// How far through the book [p] is, 0..1: chapters count by their length once known, by [estimateFrom]'s shares
  /// till then, else equally.
  double progression(EpubPosition p) {
    final own = _chapters[p.chapter].length;
    final within = own == 0 ? 0.0 : (p.position / own).clamp(0.0, 1.0);
    final lengths = _weights;
    if (lengths == null) return ((p.chapter + within) / _chapters.length).clamp(0.0, 1.0);
    final total = lengths.fold(0, (a, b) => a + b);
    final before = lengths.take(p.chapter).fold(0, (a, b) => a + b);
    return total == 0 ? 0 : ((before + within * lengths[p.chapter]) / total).clamp(0.0, 1.0);
  }

  /// Each chapter's share of the book before they've all been read in (the counting does that): from Komga's
  /// positions, about one per 1,000 characters of a chapter's file. With every chapter counted as equal, a book with
  /// long and short chapters showed 24% that became 2% once counted (The Dispossessed, build 74).
  List<int>? _estimate;

  /// Sets the chapters' shares from the chapter path of each of Komga's positions (a chapter with none counts as one).
  void estimateFrom(Iterable<String> positionPaths) {
    final per = <String, int>{};
    for (final p in positionPaths) {
      per[p] = (per[p] ?? 0) + 1;
    }
    final est = [for (final s in info.spine) per[s] ?? 1];
    if (per.isEmpty) return;
    _estimate = est;
  }

  /// The chapters' lengths when all are known, else the estimate (null: none - equal shares).
  List<int>? get _weights {
    final lengths = [for (final c in _chapters) c.length];
    return lengths.every((l) => l > 0) ? lengths : _estimate;
  }

  /// The chapter a book path is in (a table-of-contents entry, a link); null if it isn't one of the chapters.
  int? chapterOf(String path) {
    final p = path.split('#').first;
    final i = info.spine.indexOf(p);
    return i < 0 ? null : i;
  }

  /// The chapter position of the element with id [fragment] in chapter [i] (0 if not found) - for links into a
  /// chapter: where the chapter's reader met it (EPUB review E16), from the chapter's one load (it is about to be
  /// shown anyway).
  Future<int> positionOfFragment(int i, String fragment) async => (await _content(i)).ids[fragment] ?? 0;

  /// A file of the book (pictures for the footnote pop-up, the footnote's own chapter).
  Future<Uint8List> resource(String path) => source.resource(path);

  @override
  void dispose() {
    _disposed = true;
    _generation++; // the background counting stops (it checks between chapters)
    _pause?.cancel();
    // two frames on, as when a chapter is let go of: the closing transition may still draw these pages (they were
    // freed at once - EPUB review R10)
    for (final c in _chapters) {
      _retire(c.paginator, c.content);
    }
    super.dispose();
  }

  bool _disposed = false;

  /// Book-wide page numbers moved: a counted chapter was laid out again with another number of pages.
  int countChanges = 0;

  @override
  void notifyListeners() {
    if (!_disposed) super.notifyListeners(); // (a load failing after closing)
  }

  /// Chapter [i]'s text, loaded once: everyone asking while it's on its way waits for the same load (two layouts at
  /// once each loaded it, and the one stored last left the other's pictures never freed - EPUB review R9). A load
  /// that lands after the book closed is freed, not kept.
  Future<LoadedChapter> _content(int i) {
    final c = _chapters[i];
    final have = c.content;
    if (have != null) return Future.value(have);
    return c.loading ??= loader.load(info.spine[i]).then((loaded) {
      c.loading = null;
      if (_disposed) {
        loaded.dispose();
        throw StateError('the book was closed');
      }
      return c.content = loaded;
    }, onError: (Object e) {
      c.loading = null;
      throw e;
    });
  }
}

