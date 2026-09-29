import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../api.dart';
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

class _ReaderScreenState extends State<ReaderScreen> {
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
  bool _fullscreen = false; // desktop: F11 / the full-screen button
  double _wheelAcc = 0; // mouse wheel travel towards the next page turn
  DateTime _lastWheelTurn = DateTime(0);
  int _fingers = 0; // two or more on the page = a pinch: page swiping pauses at once so it can't steal the gesture
  Timer? _saveTimer;
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
    // Follow the sensor (the whole app does, via the manifest), hide the system bars, keep the screen on.
    SystemChrome.setPreferredOrientations(DeviceOrientation.values);
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    keepScreenOn(true);
    _settings.addListener(_onSettings);
    _open(_book);
  }

  @override
  void dispose() {
    _saveTimer?.cancel();
    _saveNow();
    _settings.removeListener(_onSettings);
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    keepScreenOn(false);
    if (_fullscreen) setFullscreen(false); // leaving the reader leaves full screen
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
  }

  /// Opening a book and closing it without turning a page leaves no trace. Turning pages in a finished book starts
  /// it over (Komga's own behaviour).
  void _saveNow() {
    if (!_turned || _pages.isEmpty || _index > _last) return;
    final done = _index >= _last;
    api.setProgress(_book['id'], _index + 1, completed: done).catchError((_) {});
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

  /// One page on or back, in the chosen style: slide (Swipe) or cut straight to it (Straight flip).
  void _turnPage({required bool next}) {
    final target = next ? _index + 1 : _index - 1;
    if (target < 0 || target > _pages.length) return;
    if (_settings.display.pageTurn == PageTurn.flip) {
      _pc!.jumpToPage(target);
    } else {
      _pc!.animateToPage(target, duration: _turn, curve: Curves.easeOut);
    }
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

  Future<void> _toggleFullscreen() async {
    final now = await setFullscreen(!_fullscreen);
    if (mounted) setState(() => _fullscreen = now);
  }

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
    if (isDesktop && k == LogicalKeyboardKey.f11 && e is KeyDownEvent) {
      _toggleFullscreen();
      return KeyEventResult.handled;
    }
    if (!_menu) {
      if (_isFwd(k) || (k == LogicalKeyboardKey.space && !HardwareKeyboard.instance.isShiftPressed)) {
        _forward();
        return KeyEventResult.handled;
      }
      if (_isBack(k) || k == LogicalKeyboardKey.space) { _back(); return KeyEventResult.handled; }
      if (_isOk(k) && e is KeyDownEvent) { _showControls(); return KeyEventResult.handled; }
      if (k == LogicalKeyboardKey.escape && e is KeyDownEvent) { // nothing showing: Esc closes the book (and full screen)
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
                      onTapUp: (d) {
                        final x = d.localPosition.dx / box.maxWidth;
                        // tap zones follow the reading direction: the side you read towards goes forward
                        if (x < 0.33) { _rtl ? _forward() : _back(); }
                        else if (x > 0.67) { _rtl ? _back() : _forward(); }
                        else { _showControls(); }
                      },
                      child: PageView.builder(
                        controller: _pc,
                        reverse: _rtl, // right to left: page 1 on the right, swipe left-to-right goes forward
                        physics: _zoomed || _fingers > 1 ? const NeverScrollableScrollPhysics() : null,
                        itemCount: _pages.length + 1,
                        onPageChanged: _onPage,
                        itemBuilder: (context, i) => i == _pages.length ? _endCard() : _page(i),
                      ),
                    ));
                  }),
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
          onStepper: (step) => step == null ? _steppers.remove(i) : _steppers[i] = step,
          rtl: _rtl,
          onStartedAtEnd: () => _startAtEnd = null,
        );
      },
    );
  }

  Widget _endCard() {
    return Center(
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        const Text('End of book', style: TextStyle(color: Colors.white70, fontSize: 18)),
        const SizedBox(height: 16),
        Text('${_rtl ? '←' : '→'} : next book in ${widget.readListId != null ? 'this read list' : 'the series'}',
            style: const TextStyle(color: Colors.white38)),
      ]),
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
              _pc?.jumpToPage(v.round());
              setState(() => _scrub = null);
            },
          ),
        ),
      ),
    );
  }
}
