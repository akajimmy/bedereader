// The EPUB layout engine (lib/epub/): hyphenation, the XHTML reader, the CSS cascade, the paginator.
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:komga_reader/epub/css.dart';
import 'package:komga_reader/epub/hyphenator.dart';
import 'package:komga_reader/epub/layout.dart';
import 'package:komga_reader/epub/xhtml.dart';

/// A blank picture [w] x [h].
Future<ui.Image> _image(int w, int h) {
  final rec = ui.PictureRecorder();
  Canvas(rec).drawRect(Rect.fromLTWH(0, 0, w.toDouble(), h.toDouble()), Paint());
  return rec.endRecording().toImage(w, h);
}

void main() {
  late Hyphenators hy;
  setUpAll(() async => hy = await Hyphenators.load((p) async => File(p).readAsStringSync()));
  String show(Hyphenator h, String w) => h.apply(w).replaceAll(Hyphenator.soft, '-');

  test('hyphenation points (Liang, US English)', () {
    final h = hy.forLang('en')!;
    expect(show(h, 'hyphenation'), 'hy-phen-ation');
    expect(show(h, 'computer'), 'com-puter'); // at least 3 letters after a break (the patterns' own minimum)
    expect(show(h, 'Dispossessed'), 'Dis-pos-sessed');
    expect(show(h, 'table'), 'ta-ble'); // 2 letters before, 3 after: allowed
    expect(show(h, 'wall'), 'wall'); // too short for English's minimums
    expect(show(h, 'disinfection'), 'dis-in-fec-tion');
  });

  test('French: its own patterns, 2 letters either side of a break', () {
    final h = hy.forLang('fr')!;
    expect(show(h, 'anticonstitutionnellement'), 'an-ti-cons-ti-tu-tion-nel-le-ment');
    expect(show(h, 'bibliothèque'), 'bi-blio-thèque');
  });

  test("patterns picked by the book's language; English when it doesn't say; none for other languages", () {
    expect(hy.forLang(null), same(hy.forLang('en')));
    expect(hy.forLang(''), same(hy.forLang('en')));
    expect(hy.forLang('en-GB'), same(hy.forLang('en')));
    expect(hy.forLang('fr-CA'), same(hy.forLang('fr')));
    expect(hy.forLang('FR'), same(hy.forLang('fr')));
    expect(hy.forLang('de'), isNull);
  });

  test("a chapter's language comes from <html> or <body>", () {
    ChapterReader read(String src) => ChapterReader(StyleSheet(), (h) => h)..read(parseXhtml(src));
    expect(read('<html lang="fr"><body><p>x</p></body></html>').lang, 'fr');
    expect(read('<html xml:lang="en-GB"><body><p>x</p></body></html>').lang, 'en-GB');
    expect(read('<html><body lang="fr-CA"><p>x</p></body></html>').lang, 'fr-CA');
    expect(read('<html><body><p>x</p></body></html>').lang, isNull);
  });

  test('XHTML: entities, nesting, self-closing tags', () {
    final r = parseXhtml('<?xml version="1.0"?><html><body><p class="a b">It&#8217;s <i>so</i>&nbsp;on<br/>next</p></body></html>');
    final p = r.find('p')!;
    expect(p.classes, ['a', 'b']);
    expect(p.children.whereType<XText>().first.text, 'It’s ');
    expect(p.find('i'), isNotNull);
    expect(p.find('br'), isNotNull);
  });

  test('CSS: specificity and order, margin shorthand', () {
    final s = StyleSheet()..add('p { text-indent: 1em; margin: 0 0 1em } .first { text-indent: 0 } p.x { margin-top: 2em }');
    final root = parseXhtml('<body><p class="first x">a</p></body>');
    final d = s.declsFor(root.find('p')!);
    expect(d['text-indent'], '0');
    expect(d['margin-top'], '2em');
    expect(d['margin-bottom'], '1em');
  });

  // a chapter of [n] paragraphs of [words] words each (distinct words, so positions can be checked)
  String chapter(int n, int words) => '<body>${[
        for (var p = 0; p < n; p++) '<p>${[for (var w = 0; w < words; w++) 'w${p}x$w'].join(' ')}</p>',
      ].join()}</body>';

  List<EpubPage> paginate(String src, {EpubTheme theme = const EpubTheme(), Size size = const Size(400, 600)}) {
    final blocks = ChapterReader(StyleSheet(), (h) => h).read(parseXhtml(src));
    return Paginator(theme, size, hy.forLang('en')).run(blocks);
  }

  test('paginator: long text runs over several pages, none of them empty', () {
    final pages = paginate(chapter(40, 60));
    expect(pages.length, greaterThan(5));
    expect(pages.every((p) => p.pieces.isNotEmpty), isTrue);
  });

  test("pages know the chapter position they start at: rising, the first at 0; a position finds its page, at any "
      'text size', () {
    final src = chapter(30, 50);
    final blocks = ChapterReader(StyleSheet(), (h) => h)..read(parseXhtml(src));
    final total = blocks.length;
    for (final size in [16.0, 24.0]) {
      final pages = paginate(src, theme: EpubTheme(fontSize: size));
      expect(pages.first.start, 0);
      for (var i = 1; i < pages.length; i++) {
        expect(pages[i].start, greaterThan(pages[i - 1].start), reason: 'page ${i + 1} at $size px');
        expect(pages[i].start, lessThan(total));
        expect(pageFor(pages, pages[i].start), i, reason: "a page's own start finds it");
        expect(pageFor(pages, pages[i].start - 1), i - 1, reason: 'the character before is on the page before');
      }
      expect(pageFor(pages, total + 10), pages.length - 1, reason: 'past the end: the last page');
    }
  });

  test('links on a page: where each sits, where it goes (in the book, fragment kept), its text - footnote markers '
      'like Discworld\'s', () {
    final blocks = ChapterReader(StyleSheet(), (h) => 'OEBPS/$h').read(parseXhtml(
        '<body><p>The Watch<a class="footnote-link" href="Footnotes.html#fn-1">*</a> arrived. '
        'See <a href="#ch2">chapter two</a>.</p></body>'));
    final pages = Paginator(const EpubTheme(), const Size(400, 600), hy.forLang('en')).run(blocks);
    final links = pages.single.links;
    // (a link across a line break: one tap area on each line)
    expect({for (final l in links) (l.href, l.text)}, {('OEBPS/Footnotes.html#fn-1', '*'), ('OEBPS/#ch2', 'chapter two')});
    expect(links.where((l) => l.text == '*').length, 1);
    for (final l in links) {
      expect(l.rect.width, greaterThan(0));
      // in page coordinates: inside the text area (the theme's margins: 36 at the sides, 40 top and bottom)
      expect(const Rect.fromLTRB(36, 40, 364, 560).contains(l.rect.center), isTrue,
          reason: '${l.text} at ${l.rect}: inside the text area');
    }
    expect(links[0].rect.right, lessThan(links[1].rect.left), reason: 'the marker comes before the later link');
  });

  test("note markers (Hogfather's *, Snuff's [**], a number) are told from other links (a contents page's INDEX, "
      'the "th" of 50th), and drawn bigger without making their line taller', () {
    for (final m in ['*', '**', '[**]', '†', '‡', '31', '³¹', '(7)', ' 12 ']) {
      expect(Paginator.noteMarker.hasMatch(m), isTrue, reason: m);
    }
    for (final m in ['INDEX', 'MAPS', 'TH', 'a', '1234', 'Chapter 1']) {
      expect(Paginator.noteMarker.hasMatch(m), isFalse, reason: m);
    }
    List<double> lines(String a) {
      final blocks = ChapterReader(StyleSheet(), (h) => h).read(parseXhtml('<body><p>Shed by the deserving$a, and '
          'then wondered where the stories went, and why, and where to.</p><p>Next.</p></body>'));
      return Paginator(const EpubTheme(), const Size(400, 600), null).run(blocks).single.textOrigins.map((o) => o.dy).toList()
        ..add(blocks.length.toDouble());
    }
    expect(lines('<a href="n.html#f1">*</a>'), lines('*'));
  });

  test('superscripts: digits become superscript characters (footnote numbers); other text stays itself', () {
    expect(superscript('12'), '¹²');
    final b = ChapterReader(StyleSheet(), (h) => h).read(parseXhtml('<body><p>x<sup>23</sup> 1<sup>st</sup></p></body>'))
        .single as TextBlock;
    expect(b.runs.map((r) => r.text).join(), 'x²³ 1st');
    expect(b.runs.firstWhere((r) => r.text == 'st').style.size, lessThan(1), reason: 'letters: smaller');
    expect(b.runs.firstWhere((r) => r.text == '²³').style.size, 1, reason: 'superscript digits: no smaller still');
  });

  test("tables: rows and cells (thead / tbody looked through), a cell's paragraphs become lines; laid out as a grid", () {
    final r = ChapterReader(StyleSheet(), (h) => h)..read(parseXhtml('<body><p>Kings:</p><table border="1"><tbody>'
        '<tr><td>1-37</td><td>Aegon I</td><td><p>Aegon the Conqueror,</p><p>the Dragon</p></td></tr>'
        '<tr><th>37-42</th><td>Aenys I</td></tr></tbody></table><p>After.</p></body>'));
    final t = r.blocks.whereType<TableBlock>().single;
    expect(t.rows.length, 2);
    expect(t.rows[0].length, 3);
    expect(t.rows[0][2].map((x) => x.text).join(), 'Aegon the Conqueror,\nthe Dragon');
    expect(t.rows[1][0].first.style.bold, isTrue, reason: 'a header cell is bold');
    expect(t.bordered, isTrue);
    expect(r.blocks.last.start, greaterThan(t.start), reason: 'positions count on past the table');
    final pages = Paginator(const EpubTheme(), const Size(500, 700), hy.forLang('en')).run(r.blocks);
    expect(pages.length, 1);
  });

  test('pictures at their own size, one picture pixel to one screen pixel (user, 2026-10-06): a chapter that is only '
      'a picture centred, never enlarged; one in the text centred on its line; too big for the page: shrunk to fit; '
      'only big ones open full screen', () async {
    final img = await _image(300, 500);
    final small = await _image(321, 96); // a chapter-head banner
    List<Block> read(String html) => ChapterReader(StyleSheet(), (h) => h).read(parseXhtml(html));
    // on a screen with 2 screen pixels to a layout pixel: 300 x 500 takes 150 x 250
    const theme = EpubTheme(pixelRatio: 2);
    final cover = read('<body><div><img src="c.jpg"/></div></body>');
    (cover.single as ImageBlock).image = img;
    var page = Paginator(theme, const Size(400, 600), null).run(cover).single;
    expect(page.imageRects.single.size, const Size(150, 250));
    expect(page.imageRects.single.center, const Offset(200, 300), reason: 'centred in the text area (36..364 x 40..560)');
    expect(page.pictures, hasLength(1), reason: 'big enough to open full screen');
    final inText = read('<body><p>Before.</p><p><img src="m.jpg"/></p><p><img src="b.jpg"/></p></body>');
    final pics = inText.whereType<ImageBlock>().toList();
    pics[0].image = img;
    pics[1].image = small;
    page = Paginator(theme, const Size(400, 900), null).run(inText).first;
    expect(page.imageRects[0].size, const Size(150, 250));
    expect(page.imageRects[0].center.dx, 200);
    expect(page.pictures.map((p) => p.$1), [page.imageRects[0]], reason: 'the banner (96 tall) does not open');
    // too big for the page (600 x 1000 on a 1:1 screen, the text area 328 x 520): shrunk to fit
    final big = await _image(600, 1000);
    (cover.single as ImageBlock).image = big;
    page = Paginator(const EpubTheme(), const Size(400, 600), null).run(cover).single;
    expect(page.imageRects.single.height, closeTo(520, 0.01));
    expect(page.imageRects.single.width, closeTo(312, 0.01));
  });

  test("a drop cap drawn as a picture (Homeland: <span float:left><img/></span> starting the paragraph, or just before "
      "it) is drawn at its own size, the paragraph's first lines beside it", () async {
    final sheet = StyleSheet()..add('.dropcaps { float: left; }');
    final words = List.filled(80, 'word').join(' ');
    for (final html in [
      '<body><p><span class="dropcaps"><img src="T.jpg"/></span>he $words</p></body>',
      '<body><div class="dropcaps"><img src="T.jpg"/></div><p>he $words</p></body>',
    ]) {
      final blocks = ChapterReader(sheet, (h) => h).read(parseXhtml(html));
      final para = blocks.whereType<TextBlock>().single;
      expect(para.floatImage, isNotNull, reason: html);
      expect(blocks.whereType<ImageBlock>(), isEmpty, reason: 'not a picture on its own line');
      para.floatImage!.image = await _image(19, 35);
      final page = Paginator(const EpubTheme(), const Size(400, 600), null).run(blocks).first;
      final r = page.imageRects.single;
      expect(r.size, const Size(19, 35)); // its own size - not enlarged to a text drop cap's
      expect(r.left, 36);
      expect(page.textOrigins.first.dx, greaterThan(r.right), reason: 'the first lines beside it');
      expect(page.textOrigins.last.dx, 36, reason: 'then the full width under it');
    }
  });

  test("right-aligned and centred lines line up on the text column, not on their paragraph's longest line (Homeland's "
      'list of other books: each group was flush left, its short lines right-aligned to its longest)', () {
    final blocks = ChapterReader(StyleSheet()..add('p.r { text-align: right } p.c { text-align: center }'), (h) => h)
        .read(parseXhtml('<body><p class="r"><a href="a.html">Homeland</a><br/><a href="b.html">The Halfling</a></p><p class="c"><a href="c.html">Exile</a></p></body>'));
    final links = Paginator(const EpubTheme(), const Size(400, 600), null).run(blocks).single.links;
    // the text column: 36..364 (the test font: 19 px a letter - The Halfling, 12, is the longest line)
    expect(links[0].rect.right, closeTo(364, 1), reason: 'Homeland: at the right edge');
    expect(links[1].rect.right, closeTo(364, 1), reason: 'the longer line too');
    expect(links[2].rect.center.dx, closeTo(200, 1), reason: 'centred on the column');
  });

  test("the book's own text size: a size set on most of its paragraphs is the book's (shown at the reader's size, "
      'the rest in proportion); a size on a few blocks (a prelude) is not', () {
    List<Block> read(String css, String html) => ChapterReader(StyleSheet()..add(css), (h) => h).read(parseXhtml(html));
    final words = List.filled(30, 'word').join(' ');
    // small all through, on its paragraphs (p { font-size: small }; a size on <body> is never taken - the reader's
    // size stands for it already): most paragraph text at 0.85
    final small = read('p { font-size: small }', '<body><p>$words</p><p>$words</p><p>$words</p></body>');
    expect(bookTextSize([small, small]), 0.85);
    // a prelude in a small wrapper, the chapters plain: the book's size is the reader's
    final prelude = read('div.preface { font-size: small }', '<body><div class="preface"><p>$words</p></div></body>');
    final chapter = read('', '<body><p>$words</p><p>$words</p><p>$words</p></body>');
    expect(bookTextSize([prelude, chapter, chapter]), 1);
    // laid out with it, the small-all-through book's paragraphs come out as a plain book's: the same pages, same lines
    List<Offset> lay(List<Block> b, double base) =>
        Paginator(const EpubTheme(), const Size(400, 600), null, baseSize: base).run(b).first.textOrigins;
    final plain = read('', '<body><p>$words</p><p>$words</p><p>$words</p></body>');
    expect(lay(small, 0.85), lay(plain, 1));
    expect(lay(small, 1), isNot(lay(plain, 1)), reason: 'without it, the small text lays out differently');
  });

  test('Paragraph spacing: the space added between one paragraph and the next, in ems of the text', () {
    final blocks = ChapterReader(StyleSheet()..add('p { margin: 0 }'), (h) => h)
        .read(parseXhtml('<body><p>One.</p><p>Two.</p></body>'));
    double second(double gap) =>
        Paginator(EpubTheme(paragraphGap: gap), const Size(400, 600), null).run(blocks).single.textOrigins[1].dy;
    expect(second(1) - second(0), closeTo(19, 0.01), reason: '1 em at 19 px');
    expect(second(0.5) - second(0), closeTo(9.5, 0.01));
  });

  test("Exile's page (user, build 73): a text-indent in pt is a small indent, not a third of the line; a border with "
      'width 0 draws nothing; a book bold all through shows in normal weight, its headings still bold', () {
    List<Block> read(String css, String html) => ChapterReader(StyleSheet()..add(css), (h) => h).read(parseXhtml(html));
    final words = List.filled(30, 'word').join(' ');
    // 8pt: 10.67 px - about two thirds of the book's em (it came out as 10.67 em)
    final indented = read('p { text-indent: 8pt }', '<body><p>$words</p></body>').single as TextBlock;
    expect(indented.indent, closeTo(10.67 / 16, 0.01));

    expect(showsBorder({'border-style': 'solid', 'border-width': '0', 'border-color': 'rgb(0, 0, 0)'}), isFalse);
    expect(showsBorder({'border-color': 'black'}), isFalse, reason: 'no style: no border');
    expect(showsBorder({'border-style': 'solid'}), isTrue, reason: 'no width given: medium');
    expect(showsBorder({'border': '1px solid black'}), isTrue);
    expect(showsBorder({'border': 'none'}), isFalse);
    expect(showsBorder({'border-top': '2px dotted grey'}), isTrue, reason: 'a side of its own');
    final boxed = read('.bs { border-style: solid; border-width: 0 }', '<body><div class="bs"><p>$words</p></div></body>');
    expect((boxed.single as TextBlock).box, isNull, reason: 'no box round it');

    final allBold = read('.bs2 { font-weight: bold } h1 { font-size: 1.5em }',
        '<body><h1>Chapter</h1><div class="bs2"><p>$words</p><p>$words</p></div></body>');
    expect(bookTextBold([allBold]), isTrue);
    expect(bookTextBold([read('', '<body><p>$words <b>and bold</b></p></body>')]), isFalse);
  });

  test('a bordered passage gets a border; the same text without one has none', () {
    int pieces(String css) {
      final blocks = ChapterReader(StyleSheet()..add(css), (h) => h)
          .read(parseXhtml('<body><div class="box"><p>A notice.</p><p>Signed.</p></div></body>'));
      return Paginator(const EpubTheme(), const Size(400, 600), null).run(blocks).single.pieces.length;
    }
    expect(pieces('.box { border: 1px solid black }'), pieces('.box { }') + 1);
    expect(pieces('.box { border: none }'), pieces('.box { }'));
  });

  test('hanging indents (text-indent below 0, as in glossaries - Ender\'s Game): the first line starts further left '
      'than the rest; a negative margin keeps text on the page', () {
    final blocks = ChapterReader(StyleSheet()..add('p.g { margin-left: 2em; text-indent: -2em } div.c { margin-left: -6px }'),
        (h) => h).read(parseXhtml('<body><p class="g">Battle School: the orbiting school where the children are '
        'trained.</p><div class="c"><p>Off the edge?</p></div></body>'));
    // (the test font's letters are as wide as they're tall: ~15 to a line here)
    final pages = Paginator(const EpubTheme(), const Size(400, 900), hy.forLang('en')).run(blocks);
    expect(pages.length, 1, reason: [for (final p in pages) p.textOrigins].toString());
    final o = pages.single.textOrigins;
    expect(o.length, 3, reason: 'the first line, the rest of the paragraph, the other paragraph');
    expect(o[0].dx, 36, reason: 'first line: out at the page margin');
    expect(o[1].dx, 36 + 2 * 19, reason: 'the rest: at the paragraph margin (2em at 19 px)');
    expect(o[1].dy, greaterThan(o[0].dy));
    expect(o[2].dx, 36, reason: 'a negative margin stops at the page margin');
  });

  test("margins in px are px (16 to the book's em), not em: Homeland's \"also by\" page (30px either side, 45px more "
      'on the right) keeps a full-width column', () {
    final blocks = ChapterReader(
        StyleSheet()..add('div.o { margin-left: 32px; margin-right: 32px } p.r { text-align: right; margin-right: 48px }'),
        (h) => h).read(parseXhtml('<body><div class="o"><p>Homeland</p><p class="r">The Crystal Shard</p></div></body>'));
    final t = blocks.whereType<TextBlock>().toList();
    expect(t[0].left, 2, reason: '32px = 2 em');
    expect(t[1].right, 2 + 3, reason: "the wrapper's 32px and its own 48px");
    final o = Paginator(const EpubTheme(), const Size(400, 600), null).run(blocks).single.textOrigins;
    expect(o[0].dx, 36 + 2 * 19, reason: '2 em at 19 px');
  });

  test('margins nest: a quotation or a wrapper indents the paragraphs inside it, wrappers inside wrappers add up',
      () {
    TextBlock para(List<Block> bs, String text) =>
        bs.whereType<TextBlock>().firstWhere((b) => b.runs.map((r) => r.text).join().contains(text));
    final bs = ChapterReader(StyleSheet()..add('div.a { margin-left: 2em } div.b { margin-left: 1em; margin-right: 3em }'),
        (h) => h).read(parseXhtml('<body><p>Body.</p><blockquote><p>Quoted.</p></blockquote>'
        '<div class="a"><p>Outer.</p><div class="b"><p>Inner.</p></div></div><p>After.</p></body>'));
    expect((para(bs, 'Body.').left, para(bs, 'Body.').right), (0.0, 0.0));
    expect((para(bs, 'Quoted.').left, para(bs, 'Quoted.').right), (1.5, 1.5), reason: "a blockquote's indent");
    expect(para(bs, 'Outer.').left, 2);
    expect((para(bs, 'Inner.').left, para(bs, 'Inner.').right), (3.0, 3.0), reason: '2 + 1 on the left, 3 on the right');
    expect((para(bs, 'After.').left, para(bs, 'After.').right), (0.0, 0.0), reason: 'outside again: none');
  });

  test("Mistborn's epigraph (a wrapper with a right margin and space after): its paragraphs inset on the right, and "
      'the space after it kept with the reader\'s own formatting on (only the gaps between paragraphs go)', () {
    const css = '.chapterEpigraph { display: block; margin-top: 0%; margin-bottom: 10%; margin-right: 5% } '
        '.chapterTitle { text-align: center }';
    final src = '<body><div class="chapterEpigraph"><p><i>Sometimes, I worry.</i></p><p><i>When they see me.</i></p>'
        '</div><h2 class="chapterTitle">PROLOGUE</h2><p>Ash fell from the sky.</p></body>';
    final bs = ChapterReader(StyleSheet()..add(css), (h) => h).read(parseXhtml(src));
    final epi = bs.whereType<TextBlock>().take(2).toList();
    expect(epi.map((b) => b.right), [1.5, 1.5], reason: '5% of the page, as about 30 em wide');
    expect(epi.last.wrapBottom, 3, reason: '10%: the space after the epigraph');
    double headingY(bool bookFormatting) {
      final page = Paginator(EpubTheme(bookFormatting: bookFormatting), const Size(600, 900), null).run(
          ChapterReader(StyleSheet()..add(css), (h) => h).read(parseXhtml(src))).single;
      return page.textOrigins[2].dy; // the third run of lines: PROLOGUE
    }
    final plainSrc = src.replaceAll(' class="chapterEpigraph"', '');
    final page = Paginator(const EpubTheme(bookFormatting: false), const Size(600, 900), null)
        .run(ChapterReader(StyleSheet()..add(css), (h) => h).read(parseXhtml(plainSrc))).single;
    // the gap before PROLOGUE: the larger of the epigraph's space after (3 em = 57 px) and the heading's own top margin
    // (~22 px, there in both) - so 35 px more than with no wrapper
    expect(headingY(false) - page.textOrigins[2].dy, closeTo(57 - 0.83 * 1.4 * 19, 1),
        reason: "own formatting keeps the epigraph's space after, not just the heading's own");
  });

  test("own formatting takes out only the book's usual gap between paragraphs: a paragraph that asks for its own "
      'spacing (a scene break) keeps it, and starts without an indent', () {
    const css = 'p { margin: 1em 0 } p.break { margin-top: 3em }';
    final src = '<body><p>One.</p><p>Two.</p><p>Three.</p><p class="break">After the break.</p><p>Five.</p></body>';
    final page = Paginator(const EpubTheme(bookFormatting: false), const Size(600, 900), null)
        .run(ChapterReader(StyleSheet()..add(css), (h) => h).read(parseXhtml(src))).single;
    final o = page.textOrigins;
    final line = o[1].dy - o[0].dy; // ordinary paragraphs: one line apart, no gap
    expect(o[2].dy - o[1].dy, closeTo(line, 0.5), reason: 'the usual 1em gap is gone');
    expect(o[3].dy - o[2].dy, closeTo(line + 3 * 19, 0.5), reason: "the break's own 3em above stays");
    expect(o[4].dy - o[3].dy, closeTo(line, 0.5), reason: "the break's usual 1em below goes like the others'");
  });

  test("the reader's own formatting: paragraphs justified, indented after another paragraph, no gaps - fewer pages "
      "than the book's browser-default gaps; headings keep theirs", () {
    final src = '<body><h1>Title</h1>${chapter(30, 20).replaceAll(RegExp('</?body>'), '')}</body>';
    final book = paginate(src);
    final mine = paginate(src, theme: const EpubTheme(bookFormatting: false));
    expect(mine.length, lessThan(book.length), reason: 'no gap between paragraphs');
  });
}
