/// EPUB chapter -> blocks (paragraphs of styled runs, images) -> pages. Pages are lists of pieces painted on a Canvas,
/// so the reader can show them as widgets or turn them into pictures (the page curl).
library;

import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/widgets.dart';

import 'css.dart';
import 'hyphenator.dart';
import 'xhtml.dart';

class EpubTheme {
  const EpubTheme({
    this.background = const Color(0xFF1B1B1D),
    this.text = const Color(0xFFE4E0D8),
    this.fontFamily,
    this.fontSize = 19,
    this.lineHeight = 1.45,
    this.margins = const EdgeInsets.fromLTRB(36, 40, 36, 40),
    this.bookFormatting = true,
    this.hyphenate = true,
  });
  final Color background, text;
  final String? fontFamily;
  final double fontSize, lineHeight;
  final EdgeInsets margins;

  /// The publisher's alignment, indents and paragraph spacing (on), or the reader's own for every book (off):
  /// justified, the first line of each paragraph indented except after a heading or break, no gap between them
  /// (user, 2026-10-06: "a switch: book's look / mine").
  final bool bookFormatting;
  final bool hyphenate;
}

// ---- blocks

class TextRun {
  TextRun(this.text, this.style);
  final String text;
  final InlineStyle style;
}

class InlineStyle {
  const InlineStyle({this.size = 1, this.italic = false, this.bold = false, this.smallCaps = false, this.sup = false,
      this.link});
  final double size; // x the theme's font size
  final bool italic, bold, smallCaps, sup;
  final String? link; // inside <a href>: where it goes (a path in the book, #fragment kept)
  InlineStyle copy({double? size, bool? italic, bool? bold, bool? smallCaps, bool? sup, String? link}) => InlineStyle(
      size: size ?? this.size, italic: italic ?? this.italic, bold: bold ?? this.bold,
      smallCaps: smallCaps ?? this.smallCaps, sup: sup ?? this.sup, link: link ?? this.link);
}

/// A link on a page (footnote markers among them): where it is, where it goes, its text.
class EpubLink {
  EpubLink(this.rect, this.href, this.text);
  final Rect rect;
  final String href;
  final String text;
}

/// Superscript digits as their own characters (Flutter can't raise a baseline): footnote numbers, "1st".
String superscript(String s) => s.replaceAllMapped(RegExp('[0-9]'), (m) => '⁰¹²³⁴⁵⁶⁷⁸⁹'[int.parse(m[0]!)]);

sealed class Block {
  double marginTop = 0, marginBottom = 0;
  bool breakBefore = false;
  int? box; // inside a bordered element: blocks with the same number share its border

  /// Where the block starts in the chapter's text (characters, as written - no soft hyphens): a reading position.
  int start = 0;
}

class TextBlock extends Block {
  final List<TextRun> runs = [];
  bool paragraph = false; // a <p>: the reader's own formatting restyles these (not headings, quotes, centred lines)

  int get length => runs.fold(0, (n, r) => n + r.text.length);
  TextAlign align = TextAlign.start;
  double indent = 0; // em
  double left = 0, right = 0; // em
  TextRun? drop; // a drop cap / floated chapter number, set beside the first lines
  bool dropBoxed = false;
  ImageBlock? floatImage; // a picture floated left, the first lines beside it

  bool get isEmpty => runs.every((r) => r.text.trim().isEmpty);
}

class ImageBlock extends Block {
  ImageBlock(this.src);
  final String src; // path inside the book, resolved
  ui.Image? image;
}

/// A table: rows of cells, each cell its text runs (paragraphs inside a cell become lines).
class TableBlock extends Block {
  final List<List<List<TextRun>>> rows = [];
  bool bordered = false;

  int get length => rows.fold(0, (n, r) => n + r.fold(0, (m, c) => m + c.fold(0, (k, t) => k + t.text.length)));
}

const _blockTags = {
  'p', 'div', 'h1', 'h2', 'h3', 'h4', 'h5', 'h6', 'blockquote', 'li', 'ul', 'ol', 'section', 'article', 'body',
  'figure', 'figcaption', 'header', 'footer', 'hr', 'pre', 'table', 'tr', 'dl', 'dt', 'dd', 'aside', 'nav', 'center',
};
const _headSizes = {'h1': 1.6, 'h2': 1.4, 'h3': 1.2, 'h4': 1.1, 'h5': 1.0, 'h6': 0.9};

/// Reads a chapter into blocks. [resolve] turns an href in the chapter into a path inside the book.
class ChapterReader {
  ChapterReader(this.sheet, this.resolve);
  final StyleSheet sheet;
  final String Function(String href) resolve;
  final List<Block> blocks = [];
  final List<ImageBlock> images = []; // every picture, floated ones included (to be decoded)
  TextBlock? _cur;
  TextRun? _pendingDrop;
  bool _pendingDropBoxed = false;

  /// The chapter's language (lang / xml:lang on `html` or `body`), for hyphenation; null if it doesn't say.
  String? lang;

  /// The chapter's length in characters (block [Block.start]s count up to it).
  int length = 0;

  List<Block> read(XElement root) {
    final html = root.find('html');
    final body = root.find('body') ?? root;
    lang = body.attr('lang') ?? html?.attr('lang');
    _walk(body, const InlineStyle(), TextAlign.start, 0);
    _flush();
    return blocks;
  }

  TextBlock _para(TextAlign align, double indent) => _cur ??= (TextBlock()
    ..align = align
    ..indent = indent);

  void _flush() {
    final c = _cur;
    _cur = null;
    if (c == null || c.isEmpty) return;
    _add(c);
  }

  void _add(Block b) {
    b.start = length;
    length += switch (b) { TextBlock() => b.length, TableBlock() => b.length, ImageBlock() => 1 };
    blocks.add(b);
  }

  int _boxes = 0;

  /// A table's rows and cells (thead / tbody / tfoot looked through); a cell's paragraphs become lines.
  TableBlock _table(XElement t, InlineStyle st) {
    final tb = TableBlock()
      ..bordered = (t.attr('border') ?? '0') != '0' || t.classes.any((c) => c.contains('border')) ||
          sheet.declsFor(t).keys.any((k) => k.startsWith('border'));
    void rows(XElement e) {
      for (final c in e.elements) {
        if (c.name == 'tr') {
          tb.rows.add([
            for (final cell in c.elements.where((x) => x.name == 'td' || x.name == 'th'))
              _cellRuns(cell, cell.name == 'th' ? st.copy(bold: true) : st),
          ]);
        } else if (const {'thead', 'tbody', 'tfoot'}.contains(c.name)) {
          rows(c);
        }
      }
    }
    rows(t);
    tb.rows.removeWhere((r) => r.isEmpty);
    return tb;
  }

  List<TextRun> _cellRuns(XElement cell, InlineStyle st) {
    final sub = ChapterReader(sheet, resolve);
    sub._walk(cell, st, TextAlign.start, 0);
    sub._flush();
    final out = <TextRun>[];
    for (final b in sub.blocks.whereType<TextBlock>()) {
      if (out.isNotEmpty) out.add(TextRun('\n', st));
      out.addAll(b.runs);
    }
    return out;
  }

  void _walk(XElement e, InlineStyle inh, TextAlign align, double indent) {
    for (final n in e.children) {
      switch (n) {
        case XText(:final text):
          var t = text.replaceAll(RegExp(r'[\s ]+'), ' ');
          if (t.trim().isEmpty && _cur == null) break; // whitespace between blocks
          var style = inh;
          if (inh.sup) {
            // digits as superscript characters; anything else (the "st" of 1st) just smaller
            t = superscript(t);
            if (RegExp('[^⁰¹²³⁴⁵⁶⁷⁸⁹*†‡§ ]').hasMatch(t)) style = inh.copy(size: inh.size * 0.7);
          }
          _para(align, indent).runs.add(TextRun(t, style));
        case XElement():
          _element(n, inh, align, indent);
      }
    }
  }

  void _element(XElement e, InlineStyle inh, TextAlign align, double indent) {
    final d = sheet.declsFor(e);
    if (d['display'] == 'none' || const {'head', 'script', 'style', 'title'}.contains(e.name)) return;
    var st = inh;
    final em = inh.size;
    final fs = d['font-size'];
    if (fs != null) {
      final px = cssLength(fs, em: em * 16, percentOf: em * 16);
      st = st.copy(size: px != null ? px / 16 : switch (fs) {
        'small' => 0.85, 'x-small' => 0.7, 'large' => 1.2, 'x-large' => 1.5, 'smaller' => em * 0.85,
        'larger' => em * 1.2, _ => em,
      });
    } else if (_headSizes.containsKey(e.name)) {
      st = st.copy(size: _headSizes[e.name]);
    }
    if (const {'em', 'i', 'cite', 'dfn', 'var'}.contains(e.name) || d['font-style'] == 'italic' ||
        d['font-style'] == 'oblique') {
      st = st.copy(italic: !(inh.italic && const {'em', 'i'}.contains(e.name)) || d['font-style'] != null);
    }
    if (d['font-style'] == 'normal') st = st.copy(italic: false);
    final fw = d['font-weight'];
    if (const {'b', 'strong', 'h1', 'h2', 'h3', 'h4', 'h5', 'h6', 'th'}.contains(e.name) || fw == 'bold' ||
        fw == 'bolder' || (int.tryParse(fw ?? '') ?? 0) >= 600) {
      st = st.copy(bold: true);
    }
    if (fw == 'normal' || (int.tryParse(fw ?? '') ?? 1000) < 600) st = st.copy(bold: false);
    if ((d['font-variant'] ?? '').contains('small-caps')) st = st.copy(smallCaps: true);
    if (e.name == 'sup' || d['vertical-align'] == 'super') st = st.copy(sup: true);
    if (e.name == 'sub' || d['vertical-align'] == 'sub') st = st.copy(size: st.size * 0.7);
    final href = e.name == 'a' ? e.attr('href') : null;
    if (href != null && href.isNotEmpty) {
      final hash = href.indexOf('#');
      final path = hash < 0 ? href : href.substring(0, hash);
      st = st.copy(link: href.contains('://') ? href : '${resolve(path)}${hash < 0 ? '' : href.substring(hash)}');
    }

    var al = align;
    switch (d['text-align']) {
      case 'center': al = TextAlign.center;
      case 'right': al = TextAlign.right;
      case 'left': al = TextAlign.left;
      case 'justify': al = TextAlign.justify;
    }
    var ind = indent;
    final ti = d['text-indent'];
    if (ti != null) ind = (cssLength(ti, em: 1, percentOf: 30) ?? 0) / (ti.endsWith('px') ? 16 : 1);

    // images (also SVG <image> covers)
    if (e.name == 'img' || e.name == 'image') {
      final src = e.attr('src') ?? e.attr('href');
      if (src == null) return;
      final img = ImageBlock(resolve(src));
      images.add(img);
      if (d['float'] == 'left' || d['float'] == 'right') {
        // beside the paragraph it's in (the text wraps round it)
        _para(al, ind).floatImage ??= img;
        return;
      }
      _flush();
      _add(img);
      return;
    }
    if (e.name == 'br') {
      _para(al, ind).runs.add(TextRun('\n', st));
      return;
    }
    if (e.name == 'table') {
      _flush();
      final t = _table(e, st);
      if (t.rows.isNotEmpty) _add(t..marginTop = 0.5..marginBottom = 0.5);
      return;
    }

    // a short floated element (the chapter number "1" in a box, a drop cap): beside the next paragraph's lines
    final fl = d['float'];
    if ((fl == 'left' || fl == 'right') && e.find('img') == null) {
      final t = _textOf(e).trim();
      if (t.isNotEmpty && t.length <= 3) {
        _flush();
        _pendingDrop = TextRun(t, st.copy(bold: st.bold));
        _pendingDropBoxed = d.keys.any((k) => k.startsWith('border')) || d.containsKey('background-color');
        return;
      }
    }

    final isBlock = _blockTags.contains(e.name) || d['display'] == 'block' || d['display'] == 'list-item';
    if (!isBlock) {
      _walk(e, st, al, ind);
      return;
    }
    _flush();
    // a browser's defaults when the book says nothing (many books rely on them: a gap between paragraphs)
    final uaGap = switch (e.name) {
      'p' || 'blockquote' || 'ul' || 'ol' || 'dl' || 'figure' || 'pre' => 1.0,
      'h1' => 0.67, 'h2' => 0.83, 'h3' => 1.0, 'h4' => 1.33, 'h5' => 1.67, 'h6' => 2.33,
      _ => 0.0,
    };
    final mt = cssLength(d['margin-top'], em: st.size, percentOf: 30) ?? uaGap * st.size;
    final mb = cssLength(d['margin-bottom'], em: st.size, percentOf: 30) ?? uaGap * st.size;
    final ml = cssLength(d['margin-left'], em: st.size, percentOf: 30) ?? (e.name == 'blockquote' ? 1.5 : 0);
    final mr = cssLength(d['margin-right'], em: st.size, percentOf: 30) ?? (e.name == 'blockquote' ? 1.5 : 0);
    final brk = RegExp(r'always|page|left|right').hasMatch(d['page-break-before'] ?? d['break-before'] ?? '');
    final startAt = blocks.length;
    final para = _para(al, ind)
      ..left = ml
      ..right = mr
      ..paragraph = e.name == 'p';
    // ::first-letter rules that float the letter: a drop cap
    final fl1 = sheet.declsFor(e, pseudo: 'first-letter');
    final dropLetter = fl1['float'] == 'left' || (fl1['font-size'] != null && fl1['font-size'] != '1em');
    if (_pendingDrop != null) {
      para.drop = _pendingDrop;
      para.dropBoxed = _pendingDropBoxed;
      _pendingDrop = null;
    }
    _walk(e, st, al, ind);
    if (dropLetter && para.drop == null && para.runs.isNotEmpty) {
      final first = para.runs.first;
      final t = first.text.trimLeft();
      if (t.isNotEmpty) {
        para.drop = TextRun(t[0], first.style);
        para.runs[0] = TextRun(t.substring(1), first.style);
      }
    }
    _flush();
    // a bordered element (a letter, a notice, a sidebar): its blocks share the border
    final bordered = d.entries.any((x) => x.key.startsWith('border') && !RegExp(r'\bnone\b|^0').hasMatch(x.value));
    if (bordered && blocks.length > startAt) {
      final id = ++_boxes;
      for (var i = startAt; i < blocks.length; i++) {
        blocks[i].box ??= id;
      }
    }
    // margins: on the first and last block this element produced (in em of the theme size)
    if (blocks.length > startAt) {
      blocks[startAt]
        ..marginTop = math.max(blocks[startAt].marginTop, mt)
        ..breakBefore = blocks[startAt].breakBefore || brk;
      blocks.last.marginBottom = math.max(blocks.last.marginBottom, mb);
    }
  }

  static String _textOf(XElement e) =>
      e.children.map((n) => n is XText ? n.text : _textOf(n as XElement)).join();
}

// ---- pages

sealed class Piece {
  void paint(Canvas c);
}

/// A laid-out paragraph and where its line-end hyphens go: Flutter breaks lines at soft hyphens but doesn't draw
/// the hyphen (found on the tablet, 2026-10-06), so they're drawn here - hanging just past the line's end, into the
/// margin, as fine typesetting does.
class _Laid {
  _Laid(this.tp, this.hyphen, this.base);
  final TextPainter tp;
  final TextPainter hyphen;
  final List<Offset> marks = []; // painter coordinates: the hyphen's top-left
  final int base; // the chapter position of the painter's first character
  final List<(Rect, String, String)> links = []; // painter coordinates, where to, the link's text

  /// The chapter position of the line at painter height [y] (soft hyphens and the indent placeholder don't count).
  int positionAt(double y) {
    final pos = tp.getPositionForOffset(Offset(0, y + 1)).offset;
    final plain = tp.plainText;
    var extra = 0;
    for (var i = 0; i < pos && i < plain.length; i++) {
      final c = plain.codeUnitAt(i);
      if (c == 0xAD || c == 0xFFFC) extra++;
    }
    return base + pos - extra;
  }
}

class _TextPiece extends Piece {
  _TextPiece(this.laid, this.at, this.from, this.to);
  final _Laid laid;
  final Offset at; // where the painter's line [from] goes
  final double from, to; // the painter's own y range shown here
  @override
  void paint(Canvas c) {
    final tp = laid.tp;
    c.save();
    c.clipRect(Rect.fromLTWH(at.dx - 2, at.dy, tp.width + laid.hyphen.width + 4, to - from));
    tp.paint(c, Offset(at.dx, at.dy - from));
    for (final m in laid.marks) {
      if (m.dy + 1 >= from && m.dy < to) laid.hyphen.paint(c, Offset(at.dx + m.dx, at.dy - from + m.dy));
    }
    c.restore();
  }
}

class _DropPiece extends Piece {
  _DropPiece(this.tp, this.box, this.boxed, this.colour);
  final TextPainter tp;
  final Rect box;
  final bool boxed;
  final Color colour;
  @override
  void paint(Canvas c) {
    if (boxed) {
      c.drawRect(box.deflate(1), Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.2
        ..color = colour.withValues(alpha: 0.6));
    }
    tp.paint(c, Offset(box.center.dx - tp.width / 2, box.center.dy - tp.height / 2));
  }
}

/// A border: a bordered passage's (on each page it reaches), or a table cell's.
class _RectPiece extends Piece {
  _RectPiece(this.rect, this.colour);
  final Rect rect;
  final Color colour;
  @override
  void paint(Canvas c) => c.drawRect(rect, Paint()
    ..style = PaintingStyle.stroke
    ..strokeWidth = 1
    ..color = colour.withValues(alpha: 0.5));
}

class _ImagePiece extends Piece {
  _ImagePiece(this.image, this.rect);
  final ui.Image image;
  final Rect rect;
  @override
  void paint(Canvas c) => c.drawImageRect(image,
      Rect.fromLTWH(0, 0, image.width.toDouble(), image.height.toDouble()), rect, Paint()..filterQuality = FilterQuality.medium);
}

class EpubPage {
  final List<Piece> pieces = [];
  final List<EpubLink> links = []; // page coordinates (footnote markers among them)

  /// The chapter position (characters) the page starts at: progress is saved and restored by it.
  int start = 0;
  bool _started = false;

  void _at(int position) {
    if (_started) return;
    _started = true;
    start = position;
  }
}

/// The page showing chapter position [position] (the last page starting at or before it).
int pageFor(List<EpubPage> pages, int position) {
  var i = 0;
  while (i + 1 < pages.length && pages[i + 1].start <= position) {
    i++;
  }
  return i;
}

class Paginator {
  Paginator(this.theme, this.size, this.hyphenator);
  final EpubTheme theme;
  final Size size;
  final Hyphenator? hyphenator;

  final List<EpubPage> pages = [EpubPage()];
  late double _y = theme.margins.top;
  double get _bottom => size.height - theme.margins.bottom;
  double get _width => size.width - theme.margins.horizontal;
  double _pendingGap = 0;
  // a float still beside the text (CSS: following paragraphs wrap round it too, until past its bottom)
  double _floatBottom = -1, _floatW = 0;

  void _newPage() {
    pages.add(EpubPage());
    _y = theme.margins.top;
    _pendingGap = 0;
    _floatBottom = -1;
  }

  bool get _pageEmpty => pages.last.pieces.isEmpty;

  // the current text block's alignment and indent, after the formatting switch
  TextAlign _align = TextAlign.left;
  double _indent = 0;

  List<EpubPage> run(List<Block> blocks) {
    Block? prev;
    for (final b in blocks) {
      if (b.breakBefore && !_pageEmpty) _newPage();
      var mt = b.marginTop, mb = b.marginBottom;
      if (b is TextBlock) {
        _align = b.align == TextAlign.start ? TextAlign.left : b.align; // a browser's default: left
        _indent = b.indent;
        final plain = b.paragraph && const {TextAlign.start, TextAlign.left, TextAlign.justify}.contains(b.align);
        if (!theme.bookFormatting && plain) {
          // the reader's own: justified, indented after another paragraph, no gaps between paragraphs
          _align = TextAlign.justify;
          _indent = prev is TextBlock && prev.paragraph && !b.breakBefore ? 1.5 : 0;
          mt = 0;
          mb = 0;
        }
      }
      final gap = math.max(_pendingGap, mt * theme.fontSize);
      if (!_pageEmpty) _y += gap;
      final p0 = pages.length - 1, y0 = _y;
      switch (b) {
        case TextBlock():
          _text(b);
        case ImageBlock():
          _image(b);
        case TableBlock():
          _tableBlock(b);
      }
      final box = b.box;
      if (box != null) _boxSpan(box, p0, y0);
      _pendingGap = mb * theme.fontSize;
      prev = b;
    }
    // bordered passages: one border per page they reach, round their blocks there
    _boxTops.forEach((key, top) {
      final (page, _) = key;
      final r = Rect.fromLTRB(theme.margins.left - 10, top - 8, size.width - theme.margins.right + 10,
          _boxBottoms[key]! + 8);
      if (page < pages.length) pages[page].pieces.add(_RectPiece(r, theme.text));
    });
    if (_pageEmpty && pages.length > 1) pages.removeLast();
    return pages;
  }

  final Map<(int, int), double> _boxTops = {}, _boxBottoms = {}; // (page, box) -> y range

  /// A block of [box] laid out from page [p0] at [y0] to the current page and _y.
  void _boxSpan(int box, int p0, double y0) {
    final p1 = pages.length - 1;
    for (var p = p0; p <= p1; p++) {
      final top = p == p0 ? y0 : theme.margins.top;
      final bottom = p == p1 ? _y : _bottom;
      final key = (p, box);
      _boxTops[key] = math.min(_boxTops[key] ?? double.infinity, top);
      _boxBottoms[key] = math.max(_boxBottoms[key] ?? 0, bottom);
    }
  }

  /// A table: columns as wide as their longest line, shrunk in proportion when they don't fit; a row is kept whole
  /// on a page (unless taller than one).
  void _tableBlock(TableBlock t) {
    if (_y < _floatBottom) _y = _floatBottom;
    _align = TextAlign.left;
    _indent = 0;
    const gap = 14.0;
    final cols = t.rows.fold(0, (n, r) => math.max(n, r.length));
    final widths = List<double>.filled(cols, 0);
    for (final row in t.rows) {
      for (var c = 0; c < row.length; c++) {
        final tp = _painter(TextBlock()..runs.addAll(row[c]), row[c], double.infinity).tp;
        widths[c] = math.max(widths[c], tp.maxIntrinsicWidth.ceilToDouble());
      }
    }
    final avail = _width - gap * (cols - 1);
    final total = widths.fold(0.0, (a, b) => a + b);
    if (total > avail && total > 0) {
      for (var c = 0; c < cols; c++) {
        widths[c] = widths[c] * avail / total;
      }
    }
    var pos = t.start;
    for (final row in t.rows) {
      final laid = [
        for (var c = 0; c < row.length; c++)
          _painter(TextBlock()..runs.addAll(row[c]), row[c], math.max(1.0, widths[c]), base: pos),
      ];
      final h = laid.fold(0.0, (m, l) => math.max(m, l.tp.height));
      if (_y + h > _bottom && !_pageEmpty) _newPage();
      var x = theme.margins.left;
      for (var c = 0; c < laid.length; c++) {
        _place(laid[c], Offset(x, _y), 0, laid[c].tp.height);
        if (t.bordered) {
          pages.last.pieces.add(_RectPiece(Rect.fromLTWH(x - gap / 2, _y - 3, widths[c] + gap, h + 6), theme.text));
        }
        x += widths[c] + gap;
      }
      _y += h + (t.bordered ? 6 : 2);
      pos += row.fold(0, (n, cell) => n + cell.fold(0, (m, r) => m + r.text.length));
    }
  }

  TextStyle _style(InlineStyle s) => TextStyle(
        color: theme.text,
        fontFamily: theme.fontFamily,
        fontSize: theme.fontSize * s.size,
        height: theme.lineHeight,
        fontStyle: s.italic ? FontStyle.italic : FontStyle.normal,
        fontWeight: s.bold ? FontWeight.w700 : FontWeight.w400,
        // the bundled reading fonts are variable: their weight comes from the axis (device fonts ignore it)
        fontVariations: [FontVariation('wght', s.bold ? 700 : 400)],
        fontFeatures: [if (s.smallCaps) const FontFeature.enable('smcp')],
      );

  /// [prepared]: the runs already carry their soft hyphens (a slice).
  /// [base]: the chapter position of [runs]' first character (default: the block's start).
  _Laid _painter(TextBlock b, List<TextRun> runs, double width,
      {bool indent = true, bool prepared = false, int? base}) {
    final spans = <InlineSpan>[];
    final ind = indent && _indent > 0 && _align != TextAlign.center;
    if (ind) {
      spans.add(const WidgetSpan(child: SizedBox.shrink(), alignment: PlaceholderAlignment.baseline,
          baseline: TextBaseline.alphabetic));
    }
    var lead = true;
    var at = ind ? 1 : 0; // painter offset (the indent's placeholder is one character)
    final linkRanges = <(int, int, String, String)>[];
    for (final r in runs) {
      var t = r.text;
      if (lead) {
        t = t.trimLeft();
        if (t.isEmpty) continue;
        lead = false;
      }
      if (!prepared && hyphenator != null && theme.hyphenate) t = hyphenator!.apply(t);
      spans.add(TextSpan(text: t, style: _style(r.style)));
      final link = r.style.link;
      if (link != null && t.trim().isNotEmpty) {
        linkRanges.add((at, at + t.length, link, t.replaceAll(Hyphenator.soft, '').trim()));
      }
      at += t.length;
    }
    final tp = TextPainter(
      text: TextSpan(children: spans, style: _style(const InlineStyle())),
      textAlign: _align,
      textDirection: TextDirection.ltr,
    );
    if (ind) {
      tp.setPlaceholderDimensions([
        PlaceholderDimensions(size: Size(_indent * theme.fontSize, 0), alignment: PlaceholderAlignment.baseline,
            baseline: TextBaseline.alphabetic, baselineOffset: 0),
      ]);
    }
    tp.layout(maxWidth: width);
    final hyphen = TextPainter(text: TextSpan(text: '-', style: _style(const InlineStyle())),
        textDirection: TextDirection.ltr)..layout();
    final laid = _Laid(tp, hyphen, base ?? b.start);
    for (final (s, e, href, text) in linkRanges) {
      // one tap area per line the link is on (justified lines give a box per word)
      final lines = <double, Rect>{};
      for (final box in tp.getBoxesForSelection(TextSelection(baseOffset: s, extentOffset: e))) {
        final r = box.toRect();
        final key = r.top.roundToDouble();
        lines[key] = lines[key]?.expandToInclude(r) ?? r;
      }
      for (final r in lines.values) {
        laid.links.add((r, href, text));
      }
    }
    // lines that end where a word was broken (at a soft hyphen): a hyphen after them
    final plain = tp.plainText;
    final hyAscent = hyphen.computeDistanceToActualBaseline(TextBaseline.alphabetic);
    for (final lm in tp.computeLineMetrics()) {
      final pos = tp.getPositionForOffset(Offset(lm.left + lm.width - 1, lm.baseline - lm.ascent / 2));
      final end = tp.getLineBoundary(pos).end;
      if (end > 0 && end <= plain.length && plain.codeUnitAt(end - 1) == 0xAD) {
        laid.marks.add(Offset(lm.left + lm.width, lm.baseline - hyAscent));
      }
    }
    return laid;
  }

  /// The painter's y range [from]..[to] on the current page at [at] - with the page's position and links.
  void _place(_Laid laid, Offset at, double from, double to) {
    final page = pages.last;
    page._at(laid.positionAt(from));
    page.pieces.add(_TextPiece(laid, at, from, to));
    for (final (rect, href, text) in laid.links) {
      final cy = rect.center.dy;
      if (cy >= from && cy < to) page.links.add(EpubLink(rect.shift(Offset(at.dx, at.dy - from)), href, text));
    }
  }

  /// Puts lines [from]..end of [laid] on the pages, at x [x]; moves _y.
  void _lines(_Laid laid, double x, {int from = 0}) {
    final lines = laid.tp.computeLineMetrics();
    var top = 0.0;
    for (var i = 0; i < from; i++) {
      top += lines[i].height;
    }
    var i = from;
    while (i < lines.length) {
      // as many lines as fit on this page
      var end = top;
      var n = i;
      while (n < lines.length && _y + (end + lines[n].height - top) <= _bottom + 0.5) {
        end += lines[n].height;
        n++;
      }
      if (n == i) {
        if (_pageEmpty) {
          // a line taller than a page: put it anyway
          end += lines[n].height;
          n++;
        } else {
          _newPage();
          continue;
        }
      }
      _place(laid, Offset(x, _y), top, end);
      _y += end - top;
      top = end;
      i = n;
      if (i < lines.length) _newPage();
    }
  }

  void _text(TextBlock b) {
    final x = theme.margins.left + b.left * theme.fontSize;
    final width = _width - (b.left + b.right) * theme.fontSize;
    final drop = b.drop;
    final fimg = b.floatImage?.image;
    final carried = drop == null && fimg == null && _floatBottom > _y + 4; // an earlier float still alongside
    if (drop == null && fimg == null && !carried) {
      _lines(_painter(b, b.runs, width), x);
      return;
    }
    // a float: a drop cap / chapter number about three lines tall, or a picture; the first lines narrower beside it
    final lineH = theme.fontSize * theme.lineHeight;
    Piece? floatPiece;
    late final double boxW, boxH;
    if (carried) {
      boxW = _floatW;
      boxH = _floatBottom - _y - 8;
    } else if (fimg != null) {
      final s = math.min(1.0, math.min(width * 0.35 / fimg.width, (_bottom - theme.margins.top) * 0.45 / fimg.height));
      boxW = fimg.width * s;
      boxH = fimg.height * s;
      if (_y + boxH > _bottom && !_pageEmpty) _newPage();
      floatPiece = _ImagePiece(fimg, Rect.fromLTWH(x, _y + 4, boxW, boxH));
    } else {
      final dropTp = TextPainter(
        text: TextSpan(text: drop!.text, style: _style(drop.style).copyWith(fontSize: lineH * 2.6, height: 1)),
        textDirection: TextDirection.ltr,
      )..layout();
      boxW = math.max(dropTp.width + (b.dropBoxed ? 18 : 6), lineH * 1.6);
      boxH = lineH * 3;
      if (_y + boxH > _bottom && !_pageEmpty) _newPage();
      floatPiece = _DropPiece(dropTp, Rect.fromLTWH(x, _y + 2, boxW, boxH - 4), b.dropBoxed, theme.text);
    }
    final narrow = _painter(b, b.runs, width - boxW - 14, indent: false);
    final nLines = narrow.tp.computeLineMetrics();
    var k = 0;
    var h = 0.0;
    while (k < nLines.length && h < boxH + 4 - 1 && _y + h + nLines[k].height <= _bottom + 0.5) {
      h += nLines[k].height;
      k++;
    }
    pages.last._at(b.start);
    if (floatPiece != null) {
      pages.last.pieces.add(floatPiece);
      _floatBottom = _y + boxH + 8;
      _floatW = boxW;
    }
    _place(narrow, Offset(x + boxW + 14, _y), 0, h);
    _y += h;
    if (k >= nLines.length) return; // all of it beside the float: the next paragraph may wrap too
    if (_y < _floatBottom) _y = _floatBottom; // lines left but none fit beside it here: below it
    // the rest at full width, from the first character after line k
    final cut = narrow.tp.getLineBoundary(narrow.tp.getPositionForOffset(Offset(1, h - nLines[k - 1].height / 2))).end;
    final rest = _sliceRuns(b.runs, cut);
    final soft = narrow.tp.plainText.substring(0, math.min(cut, narrow.tp.plainText.length)).split('­').length - 1;
    _lines(_painter(b, rest, width, indent: false, prepared: true, base: b.start + cut - soft), x);
  }

  /// The runs from plain-text offset [start] on (offsets count the hyphenated text the painter saw).
  List<TextRun> _sliceRuns(List<TextRun> runs, int start) {
    final out = <TextRun>[];
    var pos = 0;
    var lead = true;
    for (final r in runs) {
      var t = r.text;
      if (lead) {
        t = t.trimLeft();
        if (t.isEmpty) continue;
        lead = false;
      }
      if (hyphenator != null && theme.hyphenate) t = hyphenator!.apply(t);
      final end = pos + t.length;
      if (end > start) out.add(TextRun(t.substring(math.max(0, start - pos)), r.style));
      pos = end;
    }
    return out;
  }

  void _image(ImageBlock b) {
    final img = b.image;
    if (img == null) return;
    if (_y < _floatBottom) _y = _floatBottom; // a picture of its own goes below a float
    final maxW = _width;
    var maxH = _bottom - _y;
    if (maxH < (size.height - theme.margins.vertical) * 0.4 && !_pageEmpty) {
      _newPage();
      maxH = _bottom - _y;
    }
    final scale = math.min(1.0, math.min(maxW / img.width, maxH / img.height));
    final w = img.width * scale, h = img.height * scale;
    pages.last._at(b.start);
    pages.last.pieces.add(_ImagePiece(img, Rect.fromLTWH(theme.margins.left + (maxW - w) / 2, _y, w, h)));
    _y += h;
  }
}
