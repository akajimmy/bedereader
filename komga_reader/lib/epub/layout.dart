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
    this.accent = const Color(0xFF3D8BE0),
    this.pixelRatio = 1,
    this.paragraphGap = 0,
  });
  final Color background, text;

  /// Note markers' colour: the app's accent colour (user, 2026-10-06: they follow the app's colouring).
  final Color accent;

  /// Screen pixels per layout pixel: pictures are drawn at their own size, one picture pixel to one screen pixel
  /// (user, 2026-10-06: "images ... at their native resolution").
  final double pixelRatio;

  /// Space added between one paragraph and the next, in ems of the reader's text (a setting).
  final double paragraphGap;
  final String? fontFamily;
  final double fontSize, lineHeight;
  final EdgeInsets margins;

  /// The publisher's alignment, indents and paragraph spacing (on), or the reader's own for every book (off):
  /// justified, the first line of each paragraph indented except after a heading or break, no gap between them
  /// (user, 2026-10-06: "a switch: book's look / mine").
  final bool bookFormatting;
  final bool hyphenate;

  // equal themes lay out the same: a book isn't laid out again for an equal one
  @override
  bool operator ==(Object other) => other is EpubTheme && other.background == background && other.text == text &&
      other.fontFamily == fontFamily && other.fontSize == fontSize && other.lineHeight == lineHeight &&
      other.margins == margins && other.bookFormatting == bookFormatting && other.hyphenate == hyphenate &&
      other.accent == accent && other.pixelRatio == pixelRatio && other.paragraphGap == paragraphGap;
  @override
  int get hashCode => Object.hash(background, text, fontFamily, fontSize, lineHeight, margins, bookFormatting, hyphenate,
      accent, pixelRatio, paragraphGap);
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
  double wrapTop = 0, wrapBottom = 0; // the part of those from wrappers round the block (kept by own formatting)
  double paraTop = 0, paraBottom = 0; // a paragraph's own (own formatting keeps them only if they're out of the usual)
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
  ImageBlock? _pendingDropImage; // a floated picture just before its paragraph

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
    ..indent = indent
    ..left = _insetL
    ..right = _insetR);

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

    // a floated picture with (next to) no text: a drop cap drawn as a picture (Homeland, the Hitchhiker's books:
    // <span class="dropcaps"><img/></span> starting the paragraph) or a small floated picture - beside the
    // paragraph's first lines, not a picture on its own line (user, 2026-10-06)
    final fl = d['float'];
    final floatImg = fl == 'left' || fl == 'right' ? (e.find('img') ?? e.find('image')) : null;
    if (floatImg != null && _textOf(e).trim().length <= 3) {
      final src = floatImg.attr('src') ?? floatImg.attr('href');
      if (src != null) {
        final img = ImageBlock(resolve(src));
        images.add(img);
        final cur = _cur;
        if (cur == null) {
          _pendingDropImage = img; // before its paragraph: the next one's
        } else {
          cur.floatImage ??= img;
        }
      }
      return;
    }
    // a short floated element (the chapter number "1" in a box, a drop cap): beside the next paragraph's lines
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
    final mt = _em(d['margin-top'], st) ?? uaGap * st.size;
    final mb = _em(d['margin-bottom'], st) ?? uaGap * st.size;
    final ml = _em(d['margin-left'], st) ?? (e.name == 'blockquote' ? 1.5 : 0);
    final mr = _em(d['margin-right'], st) ?? (e.name == 'blockquote' ? 1.5 : 0);
    final brk = RegExp(r'always|page|left|right').hasMatch(d['page-break-before'] ?? d['break-before'] ?? '');
    final startAt = blocks.length;
    // margins nest, as in a browser: an element's left / right margins carry down to everything inside it, added to
    // its parents' (an epigraph or a quotation wrapped round its paragraphs kept none of its indent - user, 2026-10-06,
    // Mistborn's epigraph)
    final outerL = _insetL, outerR = _insetR;
    _insetL += ml;
    _insetR += mr;
    final para = _para(al, ind)..paragraph = e.name == 'p';
    // ::first-letter rules that float the letter: a drop cap
    final fl1 = sheet.declsFor(e, pseudo: 'first-letter');
    final dropLetter = fl1['float'] == 'left' || (fl1['font-size'] != null && fl1['font-size'] != '1em');
    if (_pendingDrop != null) {
      para.drop = _pendingDrop;
      para.dropBoxed = _pendingDropBoxed;
      _pendingDrop = null;
    }
    if (_pendingDropImage != null) {
      para.floatImage ??= _pendingDropImage;
      _pendingDropImage = null;
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
    _insetL = outerL;
    _insetR = outerR;
    // a bordered element (a letter, a notice, a sidebar): its blocks share the border
    final bordered = d.entries.any((x) => x.key.startsWith('border') && !RegExp(r'\bnone\b|^0').hasMatch(x.value));
    if (bordered && blocks.length > startAt) {
      final id = ++_boxes;
      for (var i = startAt; i < blocks.length; i++) {
        blocks[i].box ??= id;
      }
    }
    // margins: on the first and last block this element produced (in em of the theme size). A wrapper's (anything
    // but a paragraph) are kept apart too: the reader's own formatting drops the gaps between paragraphs, not the
    // space a wrapper asks for round itself
    if (blocks.length > startAt) {
      blocks[startAt]
        ..marginTop = math.max(blocks[startAt].marginTop, mt)
        ..breakBefore = blocks[startAt].breakBefore || brk;
      blocks.last.marginBottom = math.max(blocks.last.marginBottom, mb);
      if (e.name != 'p') {
        blocks[startAt].wrapTop = math.max(blocks[startAt].wrapTop, mt);
        blocks.last.wrapBottom = math.max(blocks.last.wrapBottom, mb);
      } else {
        blocks[startAt].paraTop = mt; // the paragraph's own (compared with the chapter's usual)
        blocks.last.paraBottom = mb;
      }
    }
  }

  double _insetL = 0, _insetR = 0; // the left / right margins of the elements we're inside (em), added up

  /// A margin in the reader's em (16 px of the book's): px and pt scaled down - "30px" is about 2 em, not 30 (Homeland's
  /// "also by" page was squeezed into a sliver - user, 2026-10-06); % of a text column taken as 30 em wide.
  static double? _em(String? v, InlineStyle st) {
    final px = cssLength(v, em: st.size * 16, percentOf: 30 * 16);
    return px == null ? null : px / 16;
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

  /// The lines, in order: their measures, and the text each holds. The ranges come from the engine's line boundaries,
  /// never from asking which character is at a point (getPositionForOffset): that trips a bounds check inside
  /// Flutter's engine on some lines, and its release build stops the app dead - the crashes on the tablet (SIGTRAP)
  /// and the PC ("illegal instruction"), always while laying a chapter out (user, builds 66-71).
  late final List<LineMetrics> metrics = tp.computeLineMetrics();
  late final List<TextRange> lines = _lineRanges();

  List<TextRange> _lineRanges() {
    final out = <TextRange>[];
    final n = tp.plainText.length;
    var start = 0;
    while (out.length < metrics.length && start <= n) {
      // at a wrapped line's end the boundary is the next line's; after a line break it's still the line before
      final r = tp.getLineBoundary(TextPosition(offset: start));
      if (out.isNotEmpty && r.start <= out.last.start) {
        start++; // past the line break
        continue;
      }
      out.add(r);
      start = r.end > start ? r.end : start + 1;
    }
    while (out.length < metrics.length) {
      out.add(TextRange(start: n, end: n));
    }
    return out;
  }

  /// The line at painter height [y] (the last if [y] is past them).
  int lineAt(double y) {
    var top = 0.0;
    for (var i = 0; i < metrics.length; i++) {
      top += metrics[i].height;
      if (y < top) return i;
    }
    return metrics.length - 1;
  }

  /// The chapter position of the line at painter height [y] (soft hyphens and the indent placeholder don't count).
  int positionAt(double y) {
    final pos = metrics.isEmpty ? 0 : lines[lineAt(y + 1)].start;
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
  _ImagePiece(this.image, this.rect, {this.zoomable = false});
  final ui.Image image;
  final Rect rect;
  final bool zoomable; // big enough to open full screen with a tap (not a drop cap or an ornament)
  @override
  void paint(Canvas c) => c.drawImageRect(image,
      Rect.fromLTWH(0, 0, image.width.toDouble(), image.height.toDouble()), rect, Paint()..filterQuality = FilterQuality.medium);
}

class EpubPage {
  final List<Piece> pieces = [];
  final List<EpubLink> links = []; // page coordinates (footnote markers among them)

  /// Where each run of text lines starts on the page (tests: indents, wrapping).
  @visibleForTesting
  List<Offset> get textOrigins => [for (final p in pieces) if (p is _TextPiece) p.at];

  /// Where each picture is drawn on the page (tests).
  @visibleForTesting
  List<Rect> get imageRects => [for (final p in pieces) if (p is _ImagePiece) p.rect];

  /// The pictures on the page big enough to open full screen with a tap: where each is drawn, and the picture.
  List<(Rect, ui.Image)> get pictures => [for (final p in pieces) if (p is _ImagePiece && p.zoomable) (p.rect, p.image)];

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

/// The text size most of a book's paragraphs are set in (sampled chapters' [blocks]), as the book's own sizes run
/// (1 = the reader's size) - when one size covers more than half their text; else 1. A book that sets its text
/// smaller or larger all through doesn't override the reader's size; a size on a few blocks (a prelude, a letter,
/// notes) stays (user, 2026-10-06: "don't let explicit css styling over-ride the default font size of the whole
/// book").
double bookTextSize(Iterable<List<Block>> chapters) {
  final chars = <double, int>{};
  var total = 0;
  for (final blocks in chapters) {
    for (final b in blocks) {
      if (b is! TextBlock || !b.paragraph) continue;
      for (final r in b.runs) {
        final n = r.text.trim().length;
        if (n == 0) continue;
        final size = (r.style.size * 100).roundToDouble() / 100;
        chars[size] = (chars[size] ?? 0) + n;
        total += n;
      }
    }
  }
  if (total == 0) return 1;
  final top = chars.entries.reduce((a, b) => a.value >= b.value ? a : b);
  return top.value * 2 > total && top.key > 0 ? top.key : 1;
}

class Paginator {
  /// [baseSize]: the book's own text size ([bookTextSize]) - the reader's size stands for it, other sizes in
  /// proportion.
  Paginator(this.theme, this.size, this.hyphenator, {this.baseSize = 1});
  final double baseSize;

  /// The book's em: its margins, indents and spacing are in its own text size's ems - in proportion to it, as its
  /// text is.
  double get _bookEm => theme.fontSize / baseSize;
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

  // every painter made, so the pages can be let go of (a chapter far from the one being read)
  final List<TextPainter> _made = [];
  late final TextPainter _hyphen = TextPainter(
      text: TextSpan(text: '-', style: _style(const InlineStyle())), textDirection: TextDirection.ltr)
    ..layout();

  /// Frees the laid-out text of [pages] (they mustn't be painted after this).
  void dispose() {
    for (final tp in _made) {
      tp.dispose();
    }
    _made.clear();
    _hyphen.dispose();
  }

  // the current text block's alignment and indent, after the formatting switch
  TextAlign _align = TextAlign.left;
  double _indent = 0;

  // the chapter's usual paragraph spacing (the most common), which the reader's own formatting takes out
  double _usualTop = 0, _usualBottom = 0;

  void _findUsual(List<Block> blocks) {
    final count = <(double, double), int>{};
    for (final b in blocks) {
      if (b is TextBlock && b.paragraph) {
        final k = ((b.paraTop * 100).roundToDouble() / 100, (b.paraBottom * 100).roundToDouble() / 100);
        count[k] = (count[k] ?? 0) + 1;
      }
    }
    if (count.isEmpty) return;
    final usual = count.entries.reduce((a, b) => b.value > a.value ? b : a).key;
    _usualTop = usual.$1;
    _usualBottom = usual.$2;
  }

  List<EpubPage> run(List<Block> blocks) {
    _findUsual(blocks);
    // a chapter that is only a picture (a cover, a map, a plate): centred on the page, at its own size (shrunk to fit,
    // never enlarged - user, 2026-10-06: native resolution; a tap shows it full screen)
    if (blocks.length == 1 && blocks.single is ImageBlock) {
      final b = blocks.single as ImageBlock;
      final img = b.image;
      if (img != null) {
        final area = Rect.fromLTRB(theme.margins.left, theme.margins.top, size.width - theme.margins.right, _bottom);
        final w0 = img.width / theme.pixelRatio, h0 = img.height / theme.pixelRatio;
        final s = math.min(1.0, math.min(area.width / w0, area.height / h0));
        pages.single._at(b.start);
        pages.single.pieces.add(_ImagePiece(img, Rect.fromCenter(center: area.center, width: w0 * s, height: h0 * s),
            zoomable: zoomable(img)));
        return pages;
      }
    }
    Block? prev;
    for (final b in blocks) {
      if (b.breakBefore && !_pageEmpty) _newPage();
      var mt = b.marginTop, mb = b.marginBottom;
      if (b is TextBlock) {
        _align = b.align == TextAlign.start ? TextAlign.left : b.align; // a browser's default: left
        _indent = b.indent;
        final plain = b.paragraph && const {TextAlign.start, TextAlign.left, TextAlign.justify}.contains(b.align);
        if (!theme.bookFormatting && plain) {
          // the reader's own: justified, indented after another paragraph, no gaps between paragraphs. Only the
          // book's ordinary gap goes: spacing the book asks for specifically - round a wrapper, or on a paragraph
          // that differs from the chapter's usual one (a scene break, the first paragraph after one) - is kept (user,
          // 2026-10-06: "specific spacing requirements defined in the book are respected")
          // each side on its own: one that differs from the usual is the book's own wish, kept; the usual one goes
          final ownTop = (b.paraTop - _usualTop).abs() >= 0.01, ownBottom = (b.paraBottom - _usualBottom).abs() >= 0.01;
          _align = TextAlign.justify;
          _indent = prev is TextBlock && prev.paragraph && !b.breakBefore && !(ownTop && b.paraTop > _usualTop) &&
                  !(prev.paraBottom - _usualBottom > 0.01)
              ? 1.5 * baseSize // (the reader's own 1.5 em, not the book's)
              : 0; // no indent after a space the book asked for (a scene break), as in print
          mt = ownTop ? math.max(b.wrapTop, b.paraTop) : b.wrapTop;
          mb = ownBottom ? math.max(b.wrapBottom, b.paraBottom) : b.wrapBottom;
        }
      }
      // the reader's own extra space between paragraphs (Paragraph spacing), on top of the book's
      final extra = b is TextBlock && b.paragraph && prev is TextBlock && prev.paragraph && !b.breakBefore
          ? theme.paragraphGap * theme.fontSize
          : 0.0;
      final gap = math.max(_pendingGap, mt * _bookEm) + extra;
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
      _pendingGap = mb * _bookEm;
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
        fontSize: theme.fontSize * s.size / baseSize,
        height: theme.lineHeight,
        fontStyle: s.italic ? FontStyle.italic : FontStyle.normal,
        fontWeight: s.bold ? FontWeight.w700 : FontWeight.w400,
        // the bundled reading fonts are variable: their weight comes from the axis (device fonts ignore it)
        fontVariations: [FontVariation('wght', s.bold ? 700 : 400)],
        fontFeatures: [if (s.smallCaps) const FontFeature.enable('smcp')],
      );

  /// A link's text that is a note marker: *, **, †, ‡, §, a number - in brackets or not.
  @visibleForTesting
  static final noteMarker = RegExp(r'^\s*[\[(]?(\*{1,3}|[†‡§]|[0-9⁰¹²³⁴⁵⁶⁷⁸⁹]{1,3})[\])]?\s*$');

  /// Note markers' colour: the app's accent, as it is (it's picked to show on the app's dark pages); on a light page
  /// darkened towards the text so it still reads.
  Color get _linkColour => theme.background.computeLuminance() > 0.4
      ? Color.lerp(theme.accent, theme.text, 0.35)!
      : theme.accent;

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
      final link = r.style.link;
      if (link != null && noteMarker.hasMatch(t)) {
        // a note marker: raised, bold, in the link colour - a plain "*" in the text colour went unseen (user,
        // 2026-10-06: "i didn't see any in hogfather or sourcery")
        // Sizes from the text's, not the book's <sup> (superscript digits are small already - at a <sup>'s size
        // they were specks); a lone * or † is a small glyph, drawn larger. The line no taller either way.
        t = superscript(t);
        final grow = RegExp(r'[0-9⁰¹²³⁴⁵⁶⁷⁸⁹\[]').hasMatch(t) ? 1.15 : 1.4;
        final size = theme.fontSize * math.max(r.style.size / baseSize, 0.9) * grow;
        spans.add(TextSpan(text: t, style: _style(r.style).copyWith(color: _linkColour, fontWeight: FontWeight.w700,
            fontVariations: [const FontVariation('wght', 700)], fontSize: size,
            height: theme.lineHeight * theme.fontSize / size)));
      } else {
        spans.add(TextSpan(text: t, style: _style(r.style)));
      }
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
        PlaceholderDimensions(size: Size(_indent * _bookEm, 0), alignment: PlaceholderAlignment.baseline,
            baseline: TextBaseline.alphabetic, baselineOffset: 0),
      ]);
    }
    // the full width, not the longest line's: Flutter shrinks a painter to its longest line otherwise, and right-aligned
    // or centred lines lined up on that, drawn from the left margin (Homeland's list of other books - user, build 70).
    // (A table cell measured at no limit keeps its own width.)
    tp.layout(minWidth: width.isFinite ? width : 0, maxWidth: width);
    _made.add(tp);
    final hyphen = _hyphen;
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
    for (var i = 0; i < laid.metrics.length; i++) {
      final lm = laid.metrics[i];
      final end = laid.lines[i].end;
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
    // margins inside the page (a negative one - "margin-left: -6px" - doesn't push text off it), and a line's room
    final left = math.max(0.0, b.left), right = math.max(0.0, b.right);
    final x = theme.margins.left + left * _bookEm;
    final width = math.max(theme.fontSize * 4, _width - (left + right) * _bookEm);
    final drop = b.drop;
    final fimg = b.floatImage?.image;
    final carried = drop == null && fimg == null && _floatBottom > _y + 4; // an earlier float still alongside
    if (drop == null && fimg == null && !carried) {
      if (_indent < 0) {
        _hanging(b, x, width);
        return;
      }
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
      // a floated picture - a drop cap drawn as one included - at its own size, as the book has it, the text flowing
      // beside it (user, 2026-10-06: "as they would in the proper formatting", not resized like the text drop caps)
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
      _made.add(dropTp);
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
    final cut = narrow.lines[k - 1].end;
    final rest = _sliceRuns(b.runs, cut);
    final soft = narrow.tp.plainText.substring(0, math.min(cut, narrow.tp.plainText.length)).split('­').length - 1;
    _lines(_painter(b, rest, width, indent: false, prepared: true, base: b.start + cut - soft), x);
  }

  /// A hanging indent (text-indent below 0: glossaries, references, footnotes): the first line starts further left,
  /// out into the paragraph's own left margin (never past the page's), the rest at the paragraph's margin. Flutter
  /// can't indent lines after the first, so the first line is laid out on its own and the rest from where it ends.
  void _hanging(TextBlock b, double x, double width) {
    final hang = math.min(-_indent * _bookEm, x - theme.margins.left);
    final indent = _indent;
    _indent = 0;
    final first = _painter(b, b.runs, width + hang, indent: false);
    final lines = first.tp.computeLineMetrics();
    if (lines.length <= 1 || hang <= 0) {
      _lines(hang <= 0 ? _painter(b, b.runs, width) : first, x - hang);
      _indent = indent;
      return;
    }
    final h = lines.first.height;
    if (_y + h > _bottom + 0.5 && !_pageEmpty) _newPage();
    _place(first, Offset(x - hang, _y), 0, h);
    _y += h;
    final cut = first.lines.first.end;
    final soft = first.tp.plainText.substring(0, math.min(cut, first.tp.plainText.length)).split('­').length - 1;
    _lines(_painter(b, _sliceRuns(b.runs, cut), width, indent: false, prepared: true, base: b.start + cut - soft), x);
    _indent = indent;
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

  /// A picture that opens full screen with a tap: 150 picture pixels or more both ways - an illustration, a map, a
  /// cover; not a drop cap, an ornament or a chapter-head banner (Homeland's are 321 x 96) (user, 2026-10-06: "only
  /// ... over a certain size").
  static bool zoomable(ui.Image img) => math.min(img.width, img.height) >= 150;

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
    // at its own size, one picture pixel to one screen pixel (shrunk to fit, never enlarged), centred
    final w0 = img.width / theme.pixelRatio, h0 = img.height / theme.pixelRatio;
    final scale = math.min(1.0, math.min(maxW / w0, maxH / h0));
    final w = w0 * scale, h = h0 * scale;
    pages.last._at(b.start);
    pages.last.pieces.add(_ImagePiece(img, Rect.fromLTWH(theme.margins.left + (maxW - w) / 2, _y, w, h),
        zoomable: zoomable(img)));
    _y += h;
  }
}
