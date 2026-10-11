import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

import '../epub/layout.dart';

/// The page on screen as one [Selectable] under the renderer's [SelectionArea] (user, 2026-10-08: select, a pane of
/// actions, Copy first): Flutter supplies the gestures, the handles, the menu, Select all and Ctrl+C; the page
/// answers what's at a point and what's selected from its laid-out text ([PageText]). The page stays drawn as it
/// always was ([child]); the selection is drawn over it in [colour].
///
/// [registrar]: the selection area's - given only to the page on screen (the pages either side, built ahead, take no
/// part: Select all is this page's text). It's handed down past the page view, which is kept out of the selection
/// (a scrolling view under a selection area scrolls when a selection is dragged to its edge - it would turn pages).
class SelectablePage extends SingleChildRenderObjectWidget {
  const SelectablePage({super.key, required this.page, required this.registrar, required this.colour,
      required Widget super.child});
  final EpubPage page;
  final SelectionRegistrar? registrar;
  final Color colour;

  @override
  RenderSelectablePage createRenderObject(BuildContext context) =>
      RenderSelectablePage(page, colour)..registrar = registrar;

  @override
  void updateRenderObject(BuildContext context, RenderSelectablePage renderObject) {
    renderObject
      ..page = page
      ..colour = colour
      ..registrar = registrar;
  }
}

class RenderSelectablePage extends RenderProxyBox with Selectable, SelectionRegistrant {
  RenderSelectablePage(this._page, this._colour) {
    _geometry.addListener(markNeedsPaint);
  }

  static const _nothing = SelectionGeometry(status: SelectionStatus.none, hasContent: true);
  final _geometry = ValueNotifier<SelectionGeometry>(_nothing);

  EpubPage get page => _page;
  EpubPage _page;
  set page(EpubPage v) {
    if (identical(v, _page)) return;
    _page = v;
    _start = _end = _word = null;
    _update();
  }

  Color _colour;
  set colour(Color v) {
    if (v == _colour) return;
    _colour = v;
    markNeedsPaint();
  }

  @override
  set registrar(SelectionRegistrar? value) {
    if (value == null && registrar != null) {
      _start = _end = _word = null; // off screen: nothing selected on it
      _update();
    }
    super.registrar = value;
  }

  TextSpot? _start, _end; // the selection's edges, as made (start after end: selected backwards)
  (TextSpot, TextSpot)? _word; // the word a long press picked: a drag from it keeps it whole
  List<Rect> _rects = const [];

  @override
  void addListener(VoidCallback listener) => _geometry.addListener(listener);
  @override
  void removeListener(VoidCallback listener) => _geometry.removeListener(listener);
  @override
  SelectionGeometry get value => _geometry.value;

  @override
  List<Rect> get boundingBoxes => [Offset.zero & size];

  bool get _uncollapsed => _start != null && _end != null && _start != _end;

  void _update() {
    final s = _start, e = _end;
    if (s == null || e == null || _page.text.isEmpty) {
      _rects = const [];
      _geometry.value = _nothing;
      return;
    }
    final text = _page.text;
    if (s == e) {
      _rects = const [];
      final (at, h) = text.caret(s, end: false);
      final p = SelectionPoint(localPosition: at, lineHeight: h, handleType: TextSelectionHandleType.collapsed);
      _geometry.value = SelectionGeometry(status: SelectionStatus.collapsed, hasContent: true,
          startSelectionPoint: p, endSelectionPoint: p);
      return;
    }
    final back = s > e;
    final (sAt, sH) = text.caret(s, end: back);
    final (eAt, eH) = text.caret(e, end: !back);
    _rects = text.boxes(s, e);
    _geometry.value = SelectionGeometry(
      status: SelectionStatus.uncollapsed,
      hasContent: true,
      startSelectionPoint: SelectionPoint(localPosition: sAt, lineHeight: sH,
          handleType: back ? TextSelectionHandleType.right : TextSelectionHandleType.left),
      endSelectionPoint: SelectionPoint(localPosition: eAt, lineHeight: eH,
          handleType: back ? TextSelectionHandleType.left : TextSelectionHandleType.right),
      selectionRects: _rects,
    );
  }

  @override
  SelectionResult dispatchSelectionEvent(SelectionEvent event) {
    final text = _page.text;
    var result = SelectionResult.none;
    if (text.isEmpty) {
      return event is SelectionEdgeUpdateEvent ? SelectionResult.end : SelectionResult.none;
    }
    switch (event) {
      case SelectionEdgeUpdateEvent():
        result = SelectionResult.end;
        final p = globalToLocal(event.globalPosition);
        final isEnd = event.type == SelectionEventType.endEdgeUpdate;
        var at = text.spotAt(p);
        final word = _word;
        if (event.granularity == TextGranularity.word) {
          // a long press dragged on: word by word, the word it started on kept whole
          final w = text.wordAt(p, near: true)!;
          final anchor = word ?? (isEnd ? (_start, _start) : (_end, _end));
          final from = anchor.$1;
          if (from == null) {
            at = w.$1;
          } else if (isEnd) {
            final forward = !(w.$1 < from);
            at = forward ? w.$2 : w.$1;
            if (word != null) _start = forward ? word.$1 : word.$2;
          } else {
            at = w.$1 < (anchor.$2 ?? from) ? w.$1 : w.$2;
          }
        }
        if (isEnd) {
          _end = at;
          _start ??= at;
        } else {
          _start = at;
          _end ??= at;
        }
      case ClearSelectionEvent():
        _start = _end = _word = null;
      case SelectAllSelectionEvent():
        _word = null;
        _start = text.first;
        _end = text.last;
      case SelectWordSelectionEvent():
        final w = text.wordAt(globalToLocal(event.globalPosition));
        _word = w;
        if (w != null) {
          _start = w.$1;
          _end = w.$2;
          result = SelectionResult.end;
        }
      case SelectParagraphSelectionEvent():
        final w = text.paragraphAt(globalToLocal(event.globalPosition));
        _word = null;
        if (w != null) {
          _start = w.$1;
          _end = w.$2;
          result = SelectionResult.end;
        }
      case GranularlyExtendSelectionEvent():
        result = SelectionResult.end;
        _start ??= event.forward ? text.first : text.last;
        _end ??= _start;
        if (event.isEnd) {
          _end = text.step(_end!, forward: event.forward, by: event.granularity);
        } else {
          _start = text.step(_start!, forward: event.forward, by: event.granularity);
        }
      case DirectionallyExtendSelectionEvent():
        result = SelectionResult.end;
        final forward = event.direction == SelectionExtendDirection.nextLine ||
            event.direction == SelectionExtendDirection.forward;
        _start ??= forward ? text.first : text.last;
        _end ??= _start;
        final x = globalToLocal(Offset(event.dx, 0)).dx;
        TextSpot move(TextSpot s) => switch (event.direction) {
              SelectionExtendDirection.previousLine => text.lineStep(s, down: false, x: x),
              SelectionExtendDirection.nextLine => text.lineStep(s, down: true, x: x),
              SelectionExtendDirection.forward ||
              SelectionExtendDirection.backward => text.spotAt(Offset(x, text.caret(s, end: false).$1.dy - 1)),
            };
        if (event.isEnd) {
          _end = move(_end!);
        } else {
          _start = move(_start!);
        }
      default:
        break;
    }
    _update();
    return result;
  }

  @override
  SelectedContent? getSelectedContent() =>
      _uncollapsed ? SelectedContent(plainText: _page.text.textOf(_start!, _end!)) : null;

  /// The selection as chapter positions (start, end) - what a highlight keeps; null with nothing selected.
  (int, int)? get selectedPositions {
    if (!_uncollapsed) return null;
    var a = _start!, b = _end!;
    if (b < a) (a, b) = (b, a);
    return (_page.text.chapterPosition(a), _page.text.chapterPosition(b));
  }

  @override
  SelectedContentRange? getSelection() {
    final s = _start, e = _end;
    if (s == null || e == null) return null;
    final text = _page.text;
    return SelectedContentRange(startOffset: text.indexOf(s), endOffset: text.indexOf(e));
  }

  @override
  int get contentLength => _page.text.isEmpty ? 0 : _page.text.length;

  LayerLink? _startHandle, _endHandle;

  @override
  void pushHandleLayers(LayerLink? startHandle, LayerLink? endHandle) {
    if (_startHandle == startHandle && _endHandle == endHandle) return;
    _startHandle = startHandle;
    _endHandle = endHandle;
    if (!_disposed) markNeedsPaint(); // (the area lets go of its handles while it's taken down too)
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    super.paint(context, offset);
    final g = _geometry.value;
    if (!g.hasSelection) return;
    if (_rects.isNotEmpty) {
      final paint = Paint()..color = _colour;
      for (final r in _rects) {
        context.canvas.drawRect(r.shift(offset), paint);
      }
    }
    void handle(LayerLink? link, SelectionPoint? at) {
      if (link == null || at == null) return;
      context.pushLayer(LeaderLayer(link: link, offset: offset + at.localPosition), (_, __) {}, Offset.zero);
    }
    handle(_startHandle, g.startSelectionPoint);
    handle(_endHandle, g.endSelectionPoint);
  }

  bool _disposed = false;

  @override
  void dispose() {
    _disposed = true;
    super.dispose(); // (out of the registrar first: it stops listening)
    _geometry.dispose();
  }
}
