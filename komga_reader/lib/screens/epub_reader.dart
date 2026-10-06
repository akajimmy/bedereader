import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart' show defaultTargetPlatform;
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
import '../offline/downloads.dart';
import '../reader_keys.dart';
import '../screen.dart';
import '../settings.dart';
import '../widgets/display_panel.dart';
import '../widgets/epub_settings.dart';
import '../widgets/error_text.dart';
import '../widgets/focus_style.dart';
import '../widgets/reader_clock.dart';
import '../widgets/setting_rows.dart';
import 'open_book.dart';

/// The EPUB reader (plan: reports\epub-plan-2026-10-06.md): the book laid out by the app itself (lib/epub/), page by
/// page. Taps: left third back, right third forward, the middle shows the controls; swipes turn; the remote and the
/// volume keys as in the comic reader. The slider and "page X of Y" cover the whole book once every chapter has
/// been counted (in the background after the first page shows); until then they go by chapter.
class EpubReaderScreen extends StatefulWidget {
  const EpubReaderScreen({super.key, required this.api, required this.book, this.source, this.saveProgress = true});

  /// Opens at, and saves, the reading place through [api] (Komga online; the device offline, sent later). Off: neither
  /// (a book shown from memory in tests).
  final bool saveProgress;
  final Komga api;
  final Map<String, dynamic> book;

  /// Where the book's files come from (default: Komga) - the downloaded file offline.
  final EpubSource? source;

  @override
  State<EpubReaderScreen> createState() => _EpubReaderScreenState();
}

/// The controls the remote walks (the comic reader's model): the top bar, then the bottom bar.
enum _Ctl { close, fullscreen, read, prevBook, slider, contents, settings, nextBook }

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
  final Map<_Ctl, FocusNode> _ctl = {for (final c in _Ctl.values) c: FocusNode(debugLabel: 'epub-${c.name}')};
  late Map<String, dynamic> _bookNow = widget.book; // refreshed after Mark read / unread
  Timer? _awakeTimer;
  bool _screenHeld = false;

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
    final side = math.max(e.margins.side, (_size.width - e.size * 34) / 2);
    return EpubTheme(
      background: e.colours.background,
      text: e.colours.text,
      fontFamily: family,
      fontSize: e.size,
      lineHeight: e.lineSpacing,
      margins: EdgeInsets.fromLTRB(side, e.margins.topBottom, side, e.margins.topBottom),
      bookFormatting: e.bookFormatting,
      accent: Theme.of(context).colorScheme.primary,
      pixelRatio: MediaQuery.devicePixelRatioOf(context),
    );
  }

  void _onSettings() {
    if (mounted) setState(() {}); // a new look: laid out again on the next build (same place kept)
  }

  @override
  void initState() {
    super.initState();
    Connection.instance.readerOpened();
    AppSettings.instance.addListener(_onSettings);
    fullscreen.addListener(_onSettings);
    Downloads.instance.readerOpened();
    AppSettings.instance.readerOpened();
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    _awake();
    _open();
  }

  @override
  void dispose() {
    EpubTrace.instance.log('closed');
    Connection.instance.readerClosed();
    AppSettings.instance.removeListener(_onSettings);
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
    for (final n in _ctl.values) {
      n.dispose();
    }
    fullscreen.removeListener(_onSettings);
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
  /// Chapter [i] laid out ahead (a neighbour, ready to turn into); a failure is the chapter's, shown when it's reached.
  void _prefetch(int i) => unawaited(_book!.pages(i).then<void>((_) {}, onError: (Object _) {}));

  /// The reader moved somewhere (contents, a link, the slider): shown, and saved once it settles.
  Future<void> _jump(int chapter, int position) async {
    _moved = true;
    await _show(chapter, position);
    _settled();
  }

  /// Shows chapter [chapter] at [position] - or at [fraction] of the way through it (a saved place).
  Future<void> _show(int chapter, int position, {double? fraction}) async {
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
      // the reader's own move (opening, laid out again, a jump): not a turn - it saves nothing by itself
      _ownJump = true;
      _pc.jumpToPage(target);
      _ownJump = false;
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
    final b = _book!;
    EpubTrace.instance.log('page $i (${_bookWide ? 'book' : 'chapter $_chapter'})${_ownJump ? ' by the reader' : ''}');
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
      if (c + 1 < b.chapterCount) _prefetch(c + 1);
      if (c > 0) _prefetch(c - 1);
    } else {
      final n = b.pagesNow(_chapter)?.length ?? 0;
      setState(() {
        _end = i >= n;
        _page = math.min(i, math.max(0, n - 1));
      });
    }
    if (_ownJump) return; // the reader moved the page itself: not the reader's turn (a jump saves via _jump)
    _moved = true;
    if (_end) {
      _reachedEnd();
    } else {
      _settled();
    }
  }

  bool _ownJump = false;

  Duration get _turnTime =>
      AppSettings.instance.epub.turn == EpubTurn.none ? Duration.zero : const Duration(milliseconds: 220);

  Future<void> _turn(int by) async {
    final b = _book;
    EpubTrace.instance.log('turn $by from chapter $_chapter page $_page');
    if (b == null || !_pc.hasClients) return;
    _awake();
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
        _scrubbing = false;
      });

  void _hideControls() {
    _sliderPointer = null; // a finger still on the slider: its scrub is let go of (the comic reader's rule)
    setState(() {
      _controls = false;
      _scrub = null;
      _scrubbing = false;
    });
    _focus.requestFocus();
  }

  // ---- the remote in the controls (the comic reader's model): Left / Right along a bar, Up / Down between the bars;
  // Up from the top bar or Down from the bottom one leaves them (OK then hides the controls); OK on a control presses it

  List<_Ctl> get _topBar => [_Ctl.close, if (isDesktop) _Ctl.fullscreen, _Ctl.read];
  List<_Ctl> get _bottomBar => [_Ctl.prevBook, _Ctl.slider, _Ctl.contents, _Ctl.settings, _Ctl.nextBook];

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
    target == null ? _focus.requestFocus() : _ctl[target]!.requestFocus();
    setState(() {});
  }

  static bool _isOk(LogicalKeyboardKey k) =>
      k == LogicalKeyboardKey.enter || k == LogicalKeyboardKey.select || k == LogicalKeyboardKey.numpadEnter;

  KeyEventResult _onKey(FocusNode node, KeyEvent e) {
    if (e is! KeyDownEvent && e is! KeyRepeatEvent) return KeyEventResult.ignored;
    final k = e.logicalKey;
    if (_controls) {
      if (k == LogicalKeyboardKey.escape || k == LogicalKeyboardKey.goBack) {
        _hideControls();
        return KeyEventResult.handled;
      }
      if (k == LogicalKeyboardKey.arrowRight) { _move(dx: 1); return KeyEventResult.handled; }
      if (k == LogicalKeyboardKey.arrowLeft) { _move(dx: -1); return KeyEventResult.handled; }
      if (k == LogicalKeyboardKey.arrowDown) { _move(dy: 1); return KeyEventResult.handled; }
      if (k == LogicalKeyboardKey.arrowUp) { _move(dy: -1); return KeyEventResult.handled; }
      if (_isOk(k) && _focus.hasPrimaryFocus) {
        if (e is KeyDownEvent) _hideControls(); // nothing selected: OK hides, like a tap
        return KeyEventResult.handled;
      }
      return KeyEventResult.ignored; // OK on a control reaches the control (= tapping it)
    }
    if ((k == LogicalKeyboardKey.audioVolumeDown || k == LogicalKeyboardKey.audioVolumeUp) && hasVolumeKeys &&
        AppSettings.instance.display.volumeKeys) {
      if (e is KeyDownEvent) _turn(k == LogicalKeyboardKey.audioVolumeDown ? 1 : -1);
      return KeyEventResult.handled;
    }
    // Shift+Space goes back, whatever Space is set to do (as in the comic reader)
    if (k == LogicalKeyboardKey.space && HardwareKeyboard.instance.isShiftPressed) {
      _turn(-1);
      return KeyEventResult.handled;
    }
    switch (ReaderKeys.instance.actionFor(k)) {
      case ReaderAction.next:
        _turn(1);
      case ReaderAction.previous:
        _turn(-1);
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
    await _jump(ch, frag == null ? 0 : await b.positionOfFragment(ch, frag));
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
    setState(() => _controls = false);
    await _jump(ch, hash < 0 ? 0 : await b.positionOfFragment(ch, picked.href.substring(hash + 1)));
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

  /// The position line, as Settings > Books > Position shows says (user: all three styles) - for the page shown, or
  /// the one picked on the slider.
  String _labelAt(int chapter, int page) {
    final b = _book!;
    final pct = (b.progression(b.positionOf(chapter, page)) * 100).round();
    final at = b.bookPage(chapter, page);
    final total = b.totalPages;
    final n = b.pageCount(chapter);
    final inChapter = '${_chapterNameOf(chapter)} · page ${page + 1}${n == null ? '' : ' of $n'}';
    return switch (AppSettings.instance.epub.position) {
      EpubPositionStyle.pageAndPercent =>
        at != null && total != null ? 'Page ${at + 1} of $total · $pct%' : inChapter,
      EpubPositionStyle.chapterPage => inChapter,
      EpubPositionStyle.percent => '$pct%',
    };
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
      unawaited(b.pages(c).then<void>((_) {}, onError: (Object _) {})); // a failure shows here, with Retry
      return ColoredBox(color: theme.background, child: const Center(child: CircularProgressIndicator()));
    }
    return CustomPaint(size: size, painter: _PagePainter(pages[p.clamp(0, pages.length - 1)], theme.background));
  }

  /// A chapter that couldn't be loaded or laid out: why, and Retry (never a spinner for good).
  Widget _chapterError(EpubBook b, int chapter, EpubTheme theme) {
    final e = b.errorOf(chapter)!;
    return ColoredBox(
      color: theme.background,
      child: Center(child: Padding(
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
      )),
    );
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

  /// Next book. From the end card the book is marked read; before it, as Settings > Reader says for comics ("Next
  /// book before the last page": ask, mark read, or keep it in progress). The next book opens in its own reader.
  Future<void> _nextBook() async {
    final id = widget.book['id'] as String;
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
        _moved = false; // read: closing doesn't save a place over it
        await widget.api.markRead(id);
      } else {
        _saveNow();
      }
      final next = await widget.api.nextBook(id);
      if (!mounted) return;
      if (next == null) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('That was the last book in the series')));
        return;
      }
      await Navigator.of(context).pushReplacement(MaterialPageRoute(builder: (_) => readerFor(widget.api, next)));
    } catch (e, st) {
      if (mounted) showErrorSnack(context, couldnt('open the next book', e, thing: 'book'), e, st);
    }
  }

  /// Previous book (nothing marked; this one's place kept), in its own reader.
  Future<void> _prevBook() async {
    _saveNow();
    try {
      final prev = await widget.api.previousBook(widget.book['id'] as String);
      if (!mounted) return;
      if (prev == null) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('This is the first book of the series')));
        return;
      }
      await Navigator.of(context).pushReplacement(MaterialPageRoute(builder: (_) => readerFor(widget.api, prev)));
    } catch (e, st) {
      if (mounted) showErrorSnack(context, couldnt('find the previous book', e, thing: 'book'), e, st);
    }
  }

  bool get _completed => _bookNow['readProgress']?['completed'] == true || _markedRead;

  /// The top bar's Mark read / Mark unread (as the comic reader's).
  Future<void> _toggleRead() async {
    final id = widget.book['id'] as String;
    final read = _completed;
    try {
      read ? await widget.api.markUnread(id) : await widget.api.markRead(id);
      _saveTimer?.cancel();
      _moved = false; // the mark stands: not undone by a save on closing
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
            if (b.pagesNow(_chapter) == null) {
              if (b.errorOf(_chapter) != null) return _chapterError(b, _chapter, theme);
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
                onSecondaryTap: () => _controls ? _hideControls() : _showControls(), // right-click, as with comics
              )),
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

  int? _scrub; // the page picked on the slider (a finger on it, or the remote scrubbing) - shown as it moves
  bool _scrubbing = false; // the remote is scrubbing (OK on the slider)
  int? _sliderPointer;
  static const _sliderInset = 20.0;

  /// The slider's pages: through the book once it's counted, else through the chapter.
  (int at, int last) get _sliderRange {
    final b = _book!;
    final total = b.totalPages;
    final at = b.bookPage(_chapter, _page);
    if (total != null && at != null) return (at, math.max(0, total - 1));
    return (_page, math.max(0, (b.pageCount(_chapter) ?? 1) - 1));
  }

  /// Slider page [i] as (chapter, page).
  (int, int) _sliderPage(int i) => _book!.totalPages != null ? _book!.chapterPage(i) : (_chapter, i);

  /// The page picked on the slider while the reader goes there: the slider and the counter stay on it - they showed
  /// the page left for a moment, then the new one, the slider jumping (user, build 70).
  int? _seeking;

  void _sliderJump(int i) {
    final (at, _) = _sliderRange;
    if (i == at) return;
    final (c, p) = _sliderPage(i);
    setState(() => _seeking = i);
    unawaited(_jump(c, _book!.positionOf(c, p).position).whenComplete(() {
      if (mounted && _seeking == i) setState(() => _seeking = null);
    }));
  }

  int _sliderAt(double x, double width, int last) =>
      (((x - _sliderInset) / (width - 2 * _sliderInset)).clamp(0.0, 1.0) * last).round();

  /// The slider under the remote: OK starts scrubbing, Left / Right then move a page, OK goes there.
  KeyEventResult _onSliderKey(FocusNode node, KeyEvent e) {
    if (e is! KeyDownEvent && e is! KeyRepeatEvent) return KeyEventResult.ignored;
    final k = e.logicalKey;
    final (at, last) = _sliderRange;
    if (_isOk(k)) {
      if (e is! KeyDownEvent) return KeyEventResult.handled;
      if (_scrubbing) {
        final target = _scrub ?? at;
        setState(() {
          _scrubbing = false;
          _scrub = null;
        });
        _sliderJump(target);
      } else {
        setState(() {
          _scrubbing = true;
          _scrub = at;
        });
      }
      return KeyEventResult.handled;
    }
    final fwd = k == LogicalKeyboardKey.arrowRight || k == LogicalKeyboardKey.pageDown;
    final back = k == LogicalKeyboardKey.arrowLeft || k == LogicalKeyboardKey.pageUp;
    if (_scrubbing && (fwd || back)) {
      setState(() => _scrub = ((_scrub ?? at) + (fwd ? 1 : -1)).clamp(0, last));
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored; // not scrubbing: arrows go on to the next control
  }

  Widget _slider() {
    final node = _ctl[_Ctl.slider]!;
    final accent = Theme.of(context).colorScheme.primary;
    final (at, last) = _sliderRange;
    final shown = _scrub ?? _seeking ?? at;
    return Focus(
      focusNode: node,
      onKeyEvent: _onSliderKey,
      onFocusChange: (_) => setState(() {
        if (!node.hasFocus) {
          _scrubbing = false;
          _scrub = null;
        }
      }),
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
            showValueIndicator: ShowValueIndicator.never, // the counter says where
            padding: const EdgeInsets.symmetric(horizontal: _sliderInset, vertical: 12),
          ),
          // touch followed here, not by the Slider's own drag (the comic reader's: a cancelled drag jumped with the
          // finger still down); the page shown follows the finger, the page changes when it lifts
          child: LayoutBuilder(builder: (context, box) => Listener(
                behavior: HitTestBehavior.opaque,
                onPointerDown: (e) {
                  if (_sliderPointer != null) return;
                  _sliderPointer = e.pointer;
                  setState(() => _scrub = _sliderAt(e.localPosition.dx, box.maxWidth, last));
                },
                onPointerMove: (e) {
                  if (e.pointer != _sliderPointer) return;
                  final p = _sliderAt(e.localPosition.dx, box.maxWidth, last);
                  if (p != _scrub) setState(() => _scrub = p);
                },
                onPointerUp: (e) {
                  if (e.pointer != _sliderPointer) return;
                  _sliderPointer = null;
                  _sliderJump(_sliderAt(e.localPosition.dx, box.maxWidth, last));
                  setState(() => _scrub = null);
                },
                onPointerCancel: (e) {
                  if (e.pointer != _sliderPointer) return;
                  _sliderPointer = null;
                  setState(() => _scrub = null);
                },
                child: IgnorePointer(
                  child: Slider(
                    min: 0,
                    max: math.max(1, last).toDouble(),
                    divisions: math.max(1, last),
                    value: shown.clamp(0, math.max(1, last)).toDouble(),
                    onChanged: (_) {}, // the enabled look; touch and keys are handled above
                  ),
                ),
              )),
        ),
      ),
    );
  }

  /// Icon-only control, white, its label the tooltip (the comic reader's).
  Widget _iconCtl(_Ctl c, IconData icon, String label, VoidCallback onPressed, {double size = 26}) =>
      IconButton(focusNode: _ctl[c], tooltip: label, icon: Icon(icon, color: Colors.white, size: size),
          onPressed: onPressed);

  List<Widget> _controlsOver(EpubBook b) {
    const bar = Color(0xE6101012); // the comic reader's bars
    final accent = Theme.of(context).colorScheme.primary;
    final showClock = AppSettings.instance.display.clock != ShowWhen.off;
    final clockInBar = MediaQuery.sizeOf(context).width >= 700;
    final (at, _) = _sliderRange;
    final picked = _scrub ?? _seeking;
    final (sc, sp) = _sliderPage(picked ?? at);
    final label = picked == null ? _labelAt(_chapter, _page) : _labelAt(sc, sp);
    final series = _bookNow['seriesTitle'] as String?;
    final number = _bookNow['metadata']?['number'];
    final completed = _completed;
    return [
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
                        if (series != null && series.isNotEmpty)
                          Text('$series${number == null ? '' : ' #$number'}', maxLines: 1,
                              overflow: TextOverflow.ellipsis, style: const TextStyle(color: Colors.white, fontSize: 17)),
                        Text(_title, maxLines: 1, overflow: TextOverflow.ellipsis,
                            style: series != null && series.isNotEmpty
                                ? const TextStyle(color: Colors.white60, fontSize: 13)
                                : const TextStyle(color: Colors.white, fontSize: 17)),
                      ]),
                    ),
                    if (showClock && clockInBar)
                      const Padding(padding: EdgeInsets.symmetric(horizontal: 8), child: ReaderClock()),
                    if (isDesktop)
                      _iconCtl(_Ctl.fullscreen, fullscreen.value ? Icons.fullscreen_exit : Icons.fullscreen,
                          fullscreen.value ? 'Leave full screen (F11)' : 'Full screen (F11)', toggleFullscreen),
                    _iconCtl(_Ctl.read, completed ? Icons.check_circle : Icons.check_circle_outline,
                        completed ? 'Mark unread' : 'Mark read', _toggleRead),
                  ]),
                ),
              ),
            ),
          ),
          // narrow screens: no room on the top bar - the clock just under it, at the right
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
        child: Material(
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
                  // where: as Settings > Books > Position shows says - the page picked while the slider moves
                  ConstrainedBox(
                    constraints: const BoxConstraints(minWidth: 92, maxWidth: 210),
                    child: Text(label, maxLines: 2, overflow: TextOverflow.ellipsis,
                        style: TextStyle(color: _scrub != null ? accent : Colors.white, fontSize: 14,
                            fontFeatures: const [FontFeature.tabularFigures()])),
                  ),
                  Expanded(child: _slider()),
                  _iconCtl(_Ctl.contents, Icons.toc, 'Contents', _contents),
                  _iconCtl(_Ctl.settings, Icons.text_fields, 'Text and page settings', _settingsPanel),
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
