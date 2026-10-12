part of 'layout.dart';

// A page's text for selecting and copying (user, 2026-10-08: "text select ... and the first action: copy").
//
// Characters are found from a point WITHOUT TextPainter.getPositionForOffset (or anything built on it - Text,
// RichText, RenderParagraph): that call trips a bounds check in Flutter's engine and the release build dies (see
// _Laid.lines). The line comes from the y and the laid-out line metrics; the character from the x, by a binary search
// over the line's caret positions, each measured with getBoxesForSelection (the call link areas have always used).
// Word boundaries are worked out here from the text, not asked of the engine.

/// A place in a page's text: its [seg]ment (the lines of one laid-out paragraph shown on the page; in reading order)
/// and a character offset in that paragraph's laid-out text.
@immutable
class TextSpot implements Comparable<TextSpot> {
  const TextSpot(this.seg, this.offset);
  final int seg, offset;

  @override
  int compareTo(TextSpot other) => seg != other.seg ? seg - other.seg : offset - other.offset;
  bool operator <(TextSpot o) => compareTo(o) < 0;
  bool operator >(TextSpot o) => compareTo(o) > 0;
  @override
  bool operator ==(Object other) => other is TextSpot && other.seg == seg && other.offset == offset;
  @override
  int get hashCode => Object.hash(seg, offset);
  @override
  String toString() => 'TextSpot($seg, $offset)';
}

/// The lines [first]..[last] of a text piece - what of its paragraph this page shows.
class _Seg {
  _Seg(this.piece, this.first, this.last);
  final _TextPiece piece;
  final int first, last;
  _Laid get laid => piece.laid;
  int get start => laid.lines[first].start;
  int get end => laid.lines[last].end;
  double get top => piece.at.dy;
  double get bottom => piece.at.dy + piece.to - piece.from;
  double get left => piece.at.dx;
  double get right => piece.at.dx + laid.tp.width;
  Object get block => laid.block ?? laid;

  /// Page y to the painter's y.
  double py(double y) => y - piece.at.dy + piece.from;

  /// Painter coordinates to the page's.
  Offset toPage(Offset p) => Offset(p.dx + piece.at.dx, p.dy + piece.at.dy - piece.from);
}

/// The text on one page, in reading order: what's at a point, words, the selection's boxes and its plain text.
/// Pictures, borders and drop caps aren't in it (a drop cap's letter is copied with its paragraph).
class PageText {
  PageText._(EpubPage page) {
    for (final p in page.pieces) {
      if (p is! _TextPiece) continue;
      final l = p.laid;
      if (l.metrics.isEmpty) continue;
      final first = l.lineAt(p.from + 0.5), last = l.lineAt(math.max(p.from + 0.5, p.to - 0.5));
      if (l.lines[last].end <= l.lines[first].start) continue;
      _segs.add(_Seg(p, first, last));
    }
  }

  final List<_Seg> _segs = [];

  bool get isEmpty => _segs.isEmpty;
  TextSpot get first => TextSpot(0, _segs.first.start);
  TextSpot get last => TextSpot(_segs.length - 1, _segs.last.end);

  /// The characters on the page (laid-out text: soft hyphens counted).
  int get length => _segs.fold(0, (n, s) => n + s.end - s.start);

  /// [s] counted in characters from the page's first.
  int indexOf(TextSpot s) {
    var n = 0;
    for (var i = 0; i < s.seg; i++) {
      n += _segs[i].end - _segs[i].start;
    }
    return n + s.offset - _segs[s.seg].start;
  }

  // ---- points to characters

  /// [k] moved off the middle of a surrogate pair (an emoji, a rare CJK character): the engine is never asked about
  /// half a character - an out-of-range answer there is the kind of bounds check that stopped release builds.
  static int _whole(String t, int k) =>
      k > 0 && k < t.length && _isHigh(t.codeUnitAt(k - 1)) && _isLow(t.codeUnitAt(k)) ? k + 1 : k;
  static bool _isHigh(int u) => u >= 0xD800 && u <= 0xDBFF;
  static bool _isLow(int u) => u >= 0xDC00 && u <= 0xDFFF;

  /// Where a caret at painter offset [k] on line [i] stands across [l] (painter x).
  static double _caretX(_Laid l, int i, int k) {
    final s = l.lines[i].start;
    final at = math.min(_whole(l.tp.plainText, k), l.lines[i].end);
    if (at <= s) return l.metrics[i].left;
    final boxes = l.tp.getBoxesForSelection(TextSelection(baseOffset: s, extentOffset: at));
    if (boxes.isEmpty) return l.metrics[i].left;
    return boxes.fold<double>(double.negativeInfinity, (m, b) => math.max(m, b.right));
  }

  /// On line [i] of [l] at painter x [x]: the character there and the caret position nearest (a binary search over the
  /// line's caret positions - left to right, so in order).
  static (int, int) _onLine(_Laid l, int i, double x) {
    final s = l.lines[i].start, e = l.lines[i].end;
    var lo = s, hi = e;
    while (lo < hi) {
      final mid = (lo + hi + 1) >> 1;
      if (_caretX(l, i, mid) <= x) {
        lo = mid;
      } else {
        hi = mid - 1;
      }
    }
    final t = l.tp.plainText;
    var char = math.max(s, math.min(lo, e - 1));
    if (char > s && _isLow(t.codeUnitAt(char)) && _isHigh(t.codeUnitAt(char - 1))) char--; // a pair's first half
    var caret = lo;
    if (lo < e && x - _caretX(l, i, lo) > _caretX(l, i, lo + 1) - x) caret = lo + 1;
    return (char, math.min(_whole(t, caret), e)); // a selection's edge never splits a pair either
  }

  /// The segment whose lines run across page height [p].dy - the one under [p], else the nearest sideways (table
  /// cells, text beside a float); null: no text at that height.
  int? _segAt(Offset p) {
    int? best;
    var bestD = double.infinity;
    for (var i = 0; i < _segs.length; i++) {
      final s = _segs[i];
      if (p.dy < s.top || p.dy >= s.bottom) continue;
      final d = p.dx < s.left ? s.left - p.dx : (p.dx > s.right ? p.dx - s.right : 0.0);
      if (d < bestD) {
        best = i;
        bestD = d;
      }
    }
    return best;
  }

  int _lineOf(_Seg s, double y) => s.laid.lineAt(s.py(y)).clamp(s.first, s.last);

  /// The caret position nearest page point [p], for a selection's edge: in the text there, else the end of the text
  /// above it (a gap between paragraphs, a picture, the margin below), else the page's start.
  TextSpot spotAt(Offset p) {
    final i = _segAt(p);
    if (i == null) {
      int? above;
      for (var j = 0; j < _segs.length; j++) {
        if (_segs[j].bottom <= p.dy) above = j;
      }
      return above == null ? first : TextSpot(above, _segs[above].end);
    }
    final s = _segs[i];
    return TextSpot(i, _onLine(s.laid, _lineOf(s, p.dy), p.dx - s.left).$2);
  }

  /// The word at page point [p] (or the character, if it's not in a word); null: no text there. [near]: a point off
  /// the text takes the nearest place in it.
  (TextSpot, TextSpot)? wordAt(Offset p, {bool near = false}) {
    final i = _segAt(p);
    if (i == null) {
      if (!near) return null;
      final at = spotAt(p);
      return (at, at);
    }
    final s = _segs[i];
    if (!near && (p.dx < s.left - 24 || p.dx > s.right + 24)) return null;
    final (c, _) = _onLine(s.laid, _lineOf(s, p.dy), p.dx - s.left);
    final (a, b) = wordAround(s.laid.tp.plainText, c, s.start, s.end);
    return (TextSpot(i, a), TextSpot(i, b));
  }

  /// The paragraph at page point [p] as shown on this page (all its pieces); null: no text there.
  (TextSpot, TextSpot)? paragraphAt(Offset p) {
    final i = _segAt(p);
    if (i == null) return null;
    var a = i, b = i;
    while (a > 0 && identical(_segs[a - 1].block, _segs[i].block)) {
      a--;
    }
    while (b + 1 < _segs.length && identical(_segs[b + 1].block, _segs[i].block)) {
      b++;
    }
    return (TextSpot(a, _segs[a].start), TextSpot(b, _segs[b].end));
  }

  /// Where [s] first shows on the page (its boxes, page coordinates); empty if it doesn't (tests).
  @visibleForTesting
  List<Rect> boxesOf(String s) {
    for (var i = 0; i < _segs.length; i++) {
      final seg = _segs[i];
      final k = seg.laid.tp.plainText.indexOf(s, seg.start);
      if (k >= 0 && k + s.length <= seg.end) return boxes(TextSpot(i, k), TextSpot(i, k + s.length));
    }
    return const [];
  }

  // ---- moving an edge (the keyboard's Shift + arrows)

  /// [s] moved a character, a word or to its paragraph's end / the page's end, [forward] or back.
  TextSpot step(TextSpot s, {required bool forward, required TextGranularity by}) {
    final seg = _segs[s.seg];
    switch (by) {
      case TextGranularity.character:
        if (forward) {
          if (s.offset < seg.end) return TextSpot(s.seg, s.offset + 1);
          return s.seg + 1 < _segs.length ? TextSpot(s.seg + 1, _segs[s.seg + 1].start) : s;
        }
        if (s.offset > seg.start) return TextSpot(s.seg, s.offset - 1);
        return s.seg > 0 ? TextSpot(s.seg - 1, _segs[s.seg - 1].end) : s;
      case TextGranularity.word:
        final t = seg.laid.tp.plainText;
        var k = s.offset;
        if (forward) {
          while (k < seg.end && !_inWord(t, k, seg.start, seg.end)) {
            k++;
          }
          while (k < seg.end && _inWord(t, k, seg.start, seg.end)) {
            k++;
          }
        } else {
          while (k > seg.start && !_inWord(t, k - 1, seg.start, seg.end)) {
            k--;
          }
          while (k > seg.start && _inWord(t, k - 1, seg.start, seg.end)) {
            k--;
          }
        }
        if (k == s.offset) return step(s, forward: forward, by: TextGranularity.character);
        return TextSpot(s.seg, k);
      case TextGranularity.line:
      case TextGranularity.paragraph:
        if (forward) return s.offset < seg.end ? TextSpot(s.seg, seg.end) : step(s, forward: true, by: TextGranularity.character);
        return s.offset > seg.start ? TextSpot(s.seg, seg.start) : step(s, forward: false, by: TextGranularity.character);
      case TextGranularity.document:
        return forward ? last : first;
    }
  }

  /// [s] moved to the line above or below, at page x [x].
  TextSpot lineStep(TextSpot s, {required bool down, required double x}) {
    final (bottom, h) = caret(s, end: false);
    final y = down ? bottom.dy + h / 2 : bottom.dy - h * 1.5;
    if (y < _segs.first.top) return first;
    if (y >= _segs.last.bottom) return last;
    return spotAt(Offset(x, y));
  }

  // ---- what's selected

  /// Where a caret at [spot] stands on the page - the bottom of its line at its x - and the line's height. [end]: a
  /// spot at a line's start that is also the end of the line before goes on that line (the end of a selection).
  (Offset, double) caret(TextSpot spot, {required bool end}) {
    final s = _segs[spot.seg], l = s.laid;
    var i = s.first;
    while (i < s.last && spot.offset >= l.lines[i + 1].start) {
      i++;
    }
    if (end && i > s.first && spot.offset <= l.lines[i].start) i--;
    final x = _caretX(l, i, spot.offset);
    return (s.toPage(Offset(x, l.tops[i] + l.metrics[i].height)), l.metrics[i].height);
  }

  /// The selection's boxes from [a] to [b] (either way round), page coordinates.
  List<Rect> boxes(TextSpot a, TextSpot b) {
    if (b < a) (a, b) = (b, a);
    final out = <Rect>[];
    for (var i = a.seg; i <= b.seg; i++) {
      final s = _segs[i];
      final from = i == a.seg ? a.offset : s.start, to = i == b.seg ? b.offset : s.end;
      if (to <= from) continue;
      // (raised text - superscript - boxed where it's drawn, its line where it sits)
      for (final (box, lift) in s.laid.boxesLifted(from, to)) {
        final r = box.toRect();
        final mid = r.center.dy;
        if (mid < s.piece.from || mid >= s.piece.to) continue; // (a line on another page)
        out.add(r.shift(Offset(s.piece.at.dx, s.piece.at.dy - s.piece.from - lift)));
      }
    }
    return out;
  }

  /// [s] as a place in the chapter - the position pages and reading progress count in (soft hyphens and the
  /// indent's placeholder not counted), the same whatever the layout: what a highlight is kept as.
  int chapterPosition(TextSpot s) {
    final l = _segs[s.seg].laid, plain = l.tp.plainText;
    var n = 0;
    for (var i = 0; i < s.offset && i < plain.length; i++) {
      final c = plain.codeUnitAt(i);
      if (c == 0xAD || c == 0xFFFC) n++;
    }
    return l.base + s.offset - n;
  }

  /// The chapter positions [from]..[to] as boxes on this page (none if they're not on it) - a highlight, drawn.
  List<Rect> boxesOfPositions(int from, int to) {
    if (to <= from || _segs.isEmpty) return const [];
    TextSpot? a, b;
    for (var i = 0; i < _segs.length; i++) {
      final s = _segs[i];
      final first = chapterPosition(TextSpot(i, s.start)), last = chapterPosition(TextSpot(i, s.end));
      if (last <= from || first >= to) continue;
      a ??= TextSpot(i, from <= first ? s.start : _offsetOf(s, from));
      b = TextSpot(i, to >= last ? s.end : _offsetOf(s, to));
    }
    return a == null || b == null ? const [] : boxes(a, b);
  }

  /// The painter offset of chapter position [position] in [s]'s paragraph.
  int _offsetOf(_Seg s, int position) {
    final plain = s.laid.tp.plainText;
    var counted = s.laid.base, i = 0;
    for (; i < plain.length && counted < position; i++) {
      final c = plain.codeUnitAt(i);
      if (c != 0xAD && c != 0xFFFC) counted++;
    }
    return i;
  }

  /// The plain text from [a] to [b] (either way round): soft hyphens and the indent's placeholder taken out (a word
  /// broken over two lines is one word again), a drop cap's letter put back, paragraphs a line each.
  String textOf(TextSpot a, TextSpot b) {
    if (b < a) (a, b) = (b, a);
    var out = '';
    Object? block;
    for (var i = a.seg; i <= b.seg; i++) {
      final s = _segs[i], plain = s.laid.tp.plainText;
      final from = i == a.seg ? a.offset : s.start, to = i == b.seg ? b.offset : s.end;
      if (block != null && !identical(block, s.block)) out = '${out.trimRight()}\n';
      block = s.block;
      if (to <= from) continue;
      var t = plain.substring(from, to).replaceAll('\u00AD', '').replaceAll('\uFFFC', '');
      final lead = s.laid.lead;
      if (lead != null && from == 0) t = lead + t;
      out += t;
    }
    return out;
  }
}

final _letter = RegExp(r'[\p{L}\p{N}\p{M}]', unicode: true);
const _joiners = {0x27, 0x2019, 0x2D, 0x2010, 0x2011}; // ' ’ - and the Unicode hyphens: inside a word only

bool _isLetter(int u) =>
    u == 0xAD || (u >= 0xD800 && u <= 0xDFFF) || _letter.hasMatch(String.fromCharCode(u)); // (a surrogate: a letter)

/// Character [i] of [t] is part of a word (within [lo]..[hi]): a letter or digit, a soft hyphen, or an apostrophe or
/// hyphen with a letter each side.
bool _inWord(String t, int i, int lo, int hi) {
  bool letter(int j) => j >= lo && j < hi && _isLetter(t.codeUnitAt(j));
  if (letter(i)) return true;
  return i >= lo && i < hi && _joiners.contains(t.codeUnitAt(i)) && letter(i - 1) && letter(i + 1);
}

/// The word around character [c] of [t], kept within [lo]..[hi]: letters and digits, with apostrophes and hyphens
/// inside it ("don't", "well-known") and soft hyphens. On a space: the word before it (else after); on anything else
/// (a dash, a quote mark): that character.
@visibleForTesting
(int, int) wordAround(String t, int c, [int lo = 0, int? hi]) {
  final end = hi ?? t.length;
  if (c < lo || c >= end) return (c, c);
  var at = c;
  if (!_inWord(t, at, lo, end)) {
    if (t[at].trim().isNotEmpty) return (at, at + 1);
    if (_inWord(t, at - 1, lo, end)) {
      at--;
    } else if (_inWord(t, at + 1, lo, end)) {
      at++;
    } else {
      return (at, at + 1);
    }
  }
  var a = at, b = at + 1;
  while (_inWord(t, a - 1, lo, end)) {
    a--;
  }
  while (_inWord(t, b, lo, end)) {
    b++;
  }
  return (a, b);
}
