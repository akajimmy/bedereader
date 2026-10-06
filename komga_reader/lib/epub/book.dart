/// A whole EPUB laid out for one page size and theme: every chapter's page count and page starts (so "page X of Y"
/// and a slider over the whole book work), the full pages kept only for the chapters near the one being read.
library;

import 'dart:async';
import 'dart:convert';
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
        final content = c.content ??= await loader.load(info.spine[i]);
        c.length = content.length;
        sampled.add(content.blocks);
      } catch (_) {
        // can't be read: not counted (it shows its error when reached)
      }
    }
    textSize = bookTextSize(sampled);
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
    final content = c.content ??= await loader.load(info.spine[i]);
    c.length = content.length;
    if (gen != _generation) return const [];
    final p = Paginator(_theme, _size, _theme.hyphenate ? hyphenators.forLang(content.lang) : null,
        baseSize: textSize);
    final pages = p.run(content.blocks);
    if (gen != _generation) {
      p.dispose(); // never shown
      return const [];
    }
    EpubTrace.instance.log('chapter $i laid out: ${pages.length} pages');
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
  Future<void> countAll({required int Function() current}) async {
    final gen = _generation;
    for (var i = 0; i < _chapters.length; i++) {
      if (gen != _generation) return;
      if (_chapters[i].starts != null) continue;
      try {
        await pages(i);
      } catch (_) {
        // a chapter that can't be read: counted as one page (it shows the error when reached)
        _chapters[i].starts ??= [0];
      }
      if (gen != _generation) return;
      final cur = current();
      if ((i - cur).abs() > around) keepAround(cur);
      await Future<void>.delayed(Duration.zero); // let the reader breathe between chapters
    }
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
    final lengths = [for (final c in _chapters) c.length];
    if (lengths.any((l) => l == 0)) {
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

  /// How far through the book [p] is, 0..1: chapters count by their length once known, else equally.
  double progression(EpubPosition p) {
    final lengths = [for (final c in _chapters) c.length];
    if (lengths.any((l) => l == 0)) {
      final within = _chapters[p.chapter].length == 0 ? 0.0 : p.position / _chapters[p.chapter].length;
      return ((p.chapter + within) / _chapters.length).clamp(0.0, 1.0);
    }
    final total = lengths.fold(0, (a, b) => a + b);
    final before = lengths.take(p.chapter).fold(0, (a, b) => a + b);
    return total == 0 ? 0 : ((before + p.position) / total).clamp(0.0, 1.0);
  }

  /// The chapter a book path is in (a table-of-contents entry, a link); null if it isn't one of the chapters.
  int? chapterOf(String path) {
    final p = path.split('#').first;
    final i = info.spine.indexOf(p);
    return i < 0 ? null : i;
  }

  /// The chapter position of the element with id [fragment] in chapter [i] (0 if not found) - for links into a
  /// chapter. Approximate: the start of the block holding it.
  Future<int> positionOfFragment(int i, String fragment) async {
    final bytes = await source.resource(info.spine[i]);
    return fragmentPosition(bytes, fragment);
  }

  /// A file of the book (pictures for the footnote pop-up, the footnote's own chapter).
  Future<Uint8List> resource(String path) => source.resource(path);

  @override
  void dispose() {
    _generation++; // the background counting stops (it checks between chapters)
    for (final c in _chapters) {
      c.paginator?.dispose();
      c.content?.dispose();
    }
    super.dispose();
  }
}

/// The text position of the element with [id] in a chapter's XHTML: the characters of text before it.
int fragmentPosition(Uint8List xhtml, String id) {
  final s = utf8.decode(xhtml, allowMalformed: true);
  final at = RegExp('\\sid\\s*=\\s*["\']${RegExp.escape(id)}["\']').firstMatch(s)?.start;
  if (at == null) return 0;
  final body = s.indexOf(RegExp('<body', caseSensitive: false));
  final before = s.substring(body < 0 ? 0 : body, at);
  final text = before.replaceAll(RegExp(r'<[^>]*>'), '').replaceAll(RegExp(r'&[^;]+;'), 'x');
  return text.replaceAll(RegExp(r'\s+'), ' ').trim().length;
}
