import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';

import '../api.dart';
import '../epub/book.dart';
import '../epub/hyphenator.dart';
import '../epub/layout.dart';
import '../epub/progress.dart';
import '../epub/source.dart';
import '../epub/xhtml.dart';
import '../errors.dart';
import '../offline/connection.dart';
import '../offline/downloads.dart';
import '../reader_keys.dart';
import '../screen.dart';
import '../settings.dart';
import '../widgets/error_text.dart';

/// The EPUB reader (plan: reports\epub-plan-2026-10-06.md): the book laid out by the app itself (lib/epub/), page by
/// page. Taps: left third back, right third forward, the middle shows the controls; swipes turn; the remote and the
/// volume keys as in the comic reader. The slider and "page X of Y" cover the whole book once every chapter has
/// been counted (in the background after the first page shows); until then they go by chapter.
class EpubReaderScreen extends StatefulWidget {
  const EpubReaderScreen({super.key, required this.api, required this.book, this.source});
  final Komga api;
  final Map<String, dynamic> book;

  /// Where the book's files come from (default: Komga) - the downloaded file offline.
  final EpubSource? source;

  @override
  State<EpubReaderScreen> createState() => _EpubReaderScreenState();
}

class _EpubReaderScreenState extends State<EpubReaderScreen> {
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
  Timer? _awakeTimer;
  bool _screenHeld = false;

  String get _title => (widget.book['metadata']?['title'] ?? widget.book['name'] ?? '') as String;

  EpubTheme get _theme => const EpubTheme(); // the EPUB settings come with step 5 of the plan

  @override
  void initState() {
    super.initState();
    Connection.instance.readerOpened();
    Downloads.instance.readerOpened();
    AppSettings.instance.readerOpened();
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    _awake();
    _open();
  }

  @override
  void dispose() {
    Connection.instance.readerClosed();
    AppSettings.instance.readerClosed();
    Downloads.instance.readerClosed();
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    _awakeTimer?.cancel();
    if (_screenHeld) keepScreenOn(false);
    _saveNow(); // closing: the place goes now, not after the settle time
    _book?.removeListener(_onBook);
    _book?.dispose();
    _pc.dispose();
    _focus.dispose();
    super.dispose();
  }

  /// Keep the screen on for the chosen minutes after the last turn (Settings > Reader, shared with comics).
  void _awake() {
    final minutes = AppSettings.instance.display.screenOn;
    _awakeTimer?.cancel();
    final hold = minutes != 0;
    if (hold != _screenHeld) {
      _screenHeld = hold;
      keepScreenOn(hold);
    }
    if (minutes > 0) {
      _awakeTimer = Timer(Duration(minutes: minutes), () {
        _screenHeld = false;
        keepScreenOn(false);
      });
    }
  }

  Future<void> _open() async {
    try {
      final hy = _hyphenators ??= await Hyphenators.load(rootBundle.loadString);
      final source = widget.source ?? KomgaEpubSource(widget.api, widget.book['id'] as String);
      final info = await source.info();
      if (info.spine.isEmpty) throw StateError('This book has no chapters');
      // where reading stopped (Komga's progression, shared with its web reader); a book not started: the start
      if (_online) {
        try {
          final at = await _progress.load(widget.book);
          final i = at == null ? -1 : info.spine.indexOf(at.path);
          if (i >= 0) {
            _chapter = i;
            _startFraction = at!.progression;
          }
        } catch (_) {
          // Komga can't say: the start
        }
      }
      if (!mounted) return;
      setState(() => _book = EpubBook(source, info, hy)..addListener(_onBook));
    } catch (e) {
      if (mounted) setState(() => _error = e);
    }
  }

  // ---- progress (Komga's progression; plan step 4)

  late final EpubProgress _progress = EpubProgress(widget.api, widget.book['id'] as String);
  bool get _online => widget.source == null && !Connection.instance.offline;
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

  void _saveNow() {
    _saveTimer?.cancel();
    final b = _book;
    if (b == null || !_online || _end || !_moved) return;
    final at = b.positionOf(_chapter, _page);
    if (at == _saved) return;
    final length = b.lengthOf(_chapter);
    if (length == 0) return;
    _saved = at;
    // a failed save is left: the next turn saves the newer place anyway (as with comics)
    unawaited(_progress
        .save(b.info.spine[_chapter], at.position / length, b.progression(at))
        .catchError((Object _) {}));
  }

  /// The end card: the book is read.
  void _reachedEnd() {
    if (_markedRead || !_online) return;
    _markedRead = true;
    unawaited(widget.api.markRead(widget.book['id'] as String).catchError((Object _) {}));
  }

  // ---- layout

  bool _counting = false;

  void _layout(Size size) {
    final b = _book!;
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
    final keep = _book!.size == Size.zero ? null : b.positionOf(_chapter, _page);
    b.setLayout(_theme, size);
    _bookWide = false;
    _counting = false;
    // the same text stays in view: back to its chapter, its page found once laid out again (the first layout: the
    // opening shows the saved place itself - a "start of the chapter" here overrode it, found on the tablet)
    if (keep != null) WidgetsBinding.instance.addPostFrameCallback((_) => _show(keep.chapter, keep.position));
  }

  void _onBook() {
    final b = _book;
    if (b == null || !mounted) return;
    if (SchedulerBinding.instance.schedulerPhase == SchedulerPhase.persistentCallbacks) {
      // told mid-build (a new layout is set while laying the screen out): after this frame
      WidgetsBinding.instance.addPostFrameCallback((_) => _onBook());
      return;
    }
    if (!_bookWide && b.counted && !_end) {
      // every chapter counted: the page view goes over the whole book, on the same page
      final at = b.bookPage(_chapter, _page)!;
      final old = _pc;
      setState(() {
        _bookWide = true;
        _pc = PageController(initialPage: at);
      });
      WidgetsBinding.instance.addPostFrameCallback((_) => old.dispose());
    } else {
      setState(() {});
    }
  }

  /// Shows chapter [chapter] at [position] (laying it out first).
  /// The reader moved somewhere (contents, a link, the slider): shown, and saved once it settles.
  Future<void> _jump(int chapter, int position) async {
    _moved = true;
    await _show(chapter, position);
    _settled();
  }

  /// Shows chapter [chapter] at [position] - or at [fraction] of the way through it (a saved place).
  Future<void> _show(int chapter, int position, {double? fraction}) async {
    final b = _book!;
    final pages = await b.pages(chapter);
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
      _pc.jumpToPage(target);
    } else {
      final old = _pc;
      setState(() => _pc = PageController(initialPage: target));
      WidgetsBinding.instance.addPostFrameCallback((_) => old.dispose());
    }
    if (!_counting) {
      _counting = true;
      unawaited(b.countAll(current: () => _chapter));
    }
    // the neighbours ready for turning into
    if (chapter + 1 < b.chapterCount) unawaited(b.pages(chapter + 1));
    if (chapter > 0) unawaited(b.pages(chapter - 1));
  }

  // ---- turning

  int get _itemCount {
    final b = _book!;
    if (_bookWide) return b.totalPages! + 1; // + the end card
    final n = b.pagesNow(_chapter)?.length ?? 1;
    return _chapter == b.chapterCount - 1 ? n + 1 : n;
  }

  void _onPageChanged(int i) {
    final b = _book!;
    _awake();
    if (_bookWide) {
      if (i >= b.totalPages!) {
        setState(() => _end = true);
        _reachedEnd();
        return;
      }
      final (c, p) = b.chapterPage(i);
      if (c != _chapter) b.keepAround(c);
      setState(() {
        _chapter = c;
        _page = p;
        _end = false;
      });
      if (c + 1 < b.chapterCount) unawaited(b.pages(c + 1));
      if (c > 0) unawaited(b.pages(c - 1));
    } else {
      final n = b.pagesNow(_chapter)?.length ?? 0;
      setState(() {
        _end = i >= n;
        _page = math.min(i, math.max(0, n - 1));
      });
    }
    _moved = true;
    if (_end) {
      _reachedEnd();
    } else {
      _settled();
    }
  }

  Duration get _turnTime => AppSettings.instance.display.pageTurn == PageTurn.flip
      ? Duration.zero
      : const Duration(milliseconds: 220);

  Future<void> _turn(int by) async {
    final b = _book;
    if (b == null || !_pc.hasClients) return;
    _awake();
    if (!_bookWide) {
      final n = b.pagesNow(_chapter)?.length ?? 0;
      final next = _page + by;
      if (by > 0 && next >= n && !(_chapter == b.chapterCount - 1)) {
        await _show(_chapter + 1, 0); // into the next chapter (by chapter until the book is counted)
        return;
      }
      if (by < 0 && next < 0) {
        if (_chapter > 0) await _show(_chapter - 1, 1 << 30); // the previous chapter's last page
        return;
      }
    }
    final target = (_pc.page ?? 0).round() + by;
    if (target < 0 || target >= _itemCount) return;
    if (_turnTime == Duration.zero) {
      _pc.jumpToPage(target);
    } else {
      await _pc.animateToPage(target, duration: _turnTime, curve: Curves.easeOut);
    }
  }

  void _tap(TapUpDetails d, Size size, EpubPage? page) {
    // a link under the finger first (footnotes)
    for (final l in page?.links ?? const <EpubLink>[]) {
      if (l.rect.inflate(10).contains(d.localPosition)) {
        _openLink(l);
        return;
      }
    }
    final x = d.localPosition.dx / size.width;
    if (_controls) {
      setState(() => _controls = false);
    } else if (x < 1 / 3) {
      _turn(-1);
    } else if (x > 2 / 3) {
      _turn(1);
    } else {
      setState(() => _controls = true);
    }
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent e) {
    if (e is! KeyDownEvent && e is! KeyRepeatEvent) return KeyEventResult.ignored;
    final k = e.logicalKey;
    if ((k == LogicalKeyboardKey.audioVolumeDown || k == LogicalKeyboardKey.audioVolumeUp) && hasVolumeKeys &&
        AppSettings.instance.display.volumeKeys) {
      if (e is KeyDownEvent) _turn(k == LogicalKeyboardKey.audioVolumeDown ? 1 : -1);
      return KeyEventResult.handled;
    }
    if (_controls && (k == LogicalKeyboardKey.escape || k == LogicalKeyboardKey.goBack)) {
      setState(() => _controls = false);
      return KeyEventResult.handled;
    }
    switch (ReaderKeys.instance.actionFor(k)) {
      case ReaderAction.next:
        _turn(1);
      case ReaderAction.previous:
        _turn(-1);
      case ReaderAction.controls:
        if (e is KeyDownEvent) setState(() => _controls = !_controls);
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
    await _jump(ch, frag == null ? 0 : await b.positionOfFragment(ch, frag));
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
    final picked = await showModalBottomSheet<TocEntry>(
      context: context,
      isScrollControlled: true,
      builder: (c) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.7,
        builder: (c, scroll) => toc.isEmpty
            ? const Center(child: Text('This book has no table of contents'))
            : ListView.builder(
                controller: scroll,
                itemCount: toc.length,
                itemBuilder: (c, i) {
                  final t = toc[i];
                  final here = b.chapterOf(t.path) == _chapter;
                  return ListTile(
                    contentPadding: EdgeInsets.only(left: 16 + 20.0 * t.depth, right: 16),
                    title: Text(t.title.isEmpty ? '(untitled)' : t.title,
                        style: TextStyle(fontWeight: here ? FontWeight.bold : FontWeight.normal)),
                    autofocus: here,
                    onTap: () => Navigator.pop(c, t),
                  );
                },
              ),
      ),
    );
    if (picked == null || !mounted) return;
    final ch = b.chapterOf(picked.path);
    if (ch == null) return;
    final hash = picked.href.indexOf('#');
    setState(() => _controls = false);
    await _jump(ch, hash < 0 ? 0 : await b.positionOfFragment(ch, picked.href.substring(hash + 1)));
  }

  // ---- what's shown

  String get _positionLabel {
    final b = _book!;
    final pct = (b.progression(b.positionOf(_chapter, _page)) * 100).round();
    final at = b.bookPage(_chapter, _page);
    final total = b.totalPages;
    if (at != null && total != null) return 'Page ${at + 1} of $total · $pct%';
    final n = b.pageCount(_chapter);
    return 'Chapter ${_chapter + 1} of ${b.chapterCount} · page ${_page + 1}${n == null ? '' : ' of $n'}';
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
      unawaited(b.pages(c));
      return ColoredBox(color: theme.background, child: const Center(child: CircularProgressIndicator()));
    }
    return CustomPaint(size: size, painter: _PagePainter(pages[p.clamp(0, pages.length - 1)], theme.background));
  }

  Widget _endCard(EpubTheme theme) => ColoredBox(
        color: theme.background,
        child: Center(child: Column(mainAxisSize: MainAxisSize.min, children: [
          Text('The end', style: TextStyle(color: theme.text, fontSize: 28)),
          const SizedBox(height: 8),
          Text(_title, style: TextStyle(color: theme.text.withValues(alpha: 0.7))),
          const SizedBox(height: 24),
          FilledButton.icon(
            onPressed: _nextBook,
            icon: const Icon(Icons.skip_next),
            label: const Text('Next book'),
          ),
          const SizedBox(height: 8),
          TextButton(onPressed: () => Navigator.of(context).maybePop(), child: const Text('Close')),
        ])),
      );

  Future<void> _nextBook() async {
    final id = widget.book['id'] as String;
    try {
      await widget.api.markRead(id);
      final next = await widget.api.nextBook(id);
      if (!mounted) return;
      if (next == null) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('That was the last book in the series')));
        return;
      }
      await Navigator.of(context).pushReplacement(MaterialPageRoute(
          builder: (_) => EpubReaderScreen(api: widget.api, book: next)));
    } catch (e, st) {
      if (mounted) showErrorSnack(context, couldnt('open the next book', e, thing: 'book'), e, st);
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
    return Focus(
      focusNode: _focus,
      autofocus: true,
      onKeyEvent: _onKey,
      child: Scaffold(
        backgroundColor: theme.background,
        body: LayoutBuilder(builder: (context, box) {
          final size = box.biggest;
          _layout(size);
          if (b.pagesNow(_chapter) == null) {
            unawaited(_show(_chapter, 0, fraction: _startFraction));
            return const Center(child: CircularProgressIndicator());
          }
          final pages = b.pagesNow(_chapter)!;
          final shown = _end || pages.isEmpty ? null : pages[_page.clamp(0, pages.length - 1)];
          return Stack(children: [
            PageView.builder(
              key: ValueKey(_bookWide),
              controller: _pc,
              itemCount: _itemCount,
              onPageChanged: _onPageChanged,
              itemBuilder: (_, i) => _pageAt(i, size),
            ),
            Positioned.fill(child: GestureDetector(
              behavior: HitTestBehavior.translucent,
              onTapUp: (d) => _tap(d, size, shown),
            )),
            if (_controls) ..._controlsOver(b, theme),
          ]);
        }),
      ),
    );
  }

  List<Widget> _controlsOver(EpubBook b, EpubTheme theme) {
    const bar = Color(0xE6161618);
    final total = b.totalPages;
    final at = b.bookPage(_chapter, _page);
    final chapterPages = b.pageCount(_chapter) ?? 1;
    final (value, max) = total != null && at != null
        ? (at.toDouble(), math.max(1, total - 1).toDouble())
        : (_page.toDouble(), math.max(1, chapterPages - 1).toDouble());
    return [
      Positioned(left: 0, right: 0, top: 0, child: Material(color: bar, child: SafeArea(bottom: false, child: Row(children: [
        IconButton(icon: const Icon(Icons.arrow_back), tooltip: 'Close', onPressed: () => Navigator.of(context).maybePop()),
        Expanded(child: Text(_title, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 16))),
        IconButton(icon: const Icon(Icons.toc), tooltip: 'Contents', onPressed: _contents),
      ])))),
      Positioned(left: 0, right: 0, bottom: 0, child: Material(color: bar, child: SafeArea(top: false, child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 4, 12, 8),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Slider(
            value: value.clamp(0, max),
            max: max,
            inactiveColor: Colors.white24,
            onChanged: (v) => setState(() {}),
            onChangeEnd: (v) {
              if (total != null) {
                final (c, p) = b.chapterPage(v.round());
                _jump(c, b.positionOf(c, p).position);
              } else {
                _jump(_chapter, b.positionOf(_chapter, v.round()).position);
              }
            },
          ),
          Text(_positionLabel, style: const TextStyle(fontSize: 13, color: Color(0xFFBDBDBD))),
        ]),
      )))),
    ];
  }
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
