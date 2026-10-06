// The EPUB layout engine (lib/epub/): hyphenation, the XHTML reader, the CSS cascade, the paginator.
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:komga_reader/epub/css.dart';
import 'package:komga_reader/epub/hyphenator.dart';
import 'package:komga_reader/epub/layout.dart';
import 'package:komga_reader/epub/xhtml.dart';

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

  test('a bordered passage gets a border; the same text without one has none', () {
    int pieces(String css) {
      final blocks = ChapterReader(StyleSheet()..add(css), (h) => h)
          .read(parseXhtml('<body><div class="box"><p>A notice.</p><p>Signed.</p></div></body>'));
      return Paginator(const EpubTheme(), const Size(400, 600), null).run(blocks).single.pieces.length;
    }
    expect(pieces('.box { border: 1px solid black }'), pieces('.box { }') + 1);
    expect(pieces('.box { border: none }'), pieces('.box { }'));
  });

  test("the reader's own formatting: paragraphs justified, indented after another paragraph, no gaps - fewer pages "
      "than the book's browser-default gaps; headings keep theirs", () {
    final src = '<body><h1>Title</h1>${chapter(30, 20).replaceAll(RegExp('</?body>'), '')}</body>';
    final book = paginate(src);
    final mine = paginate(src, theme: const EpubTheme(bookFormatting: false));
    expect(mine.length, lessThan(book.length), reason: 'no gap between paragraphs');
  });
}
