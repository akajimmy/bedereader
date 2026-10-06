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

  test("the reader's own formatting: paragraphs justified, indented after another paragraph, no gaps - fewer pages "
      "than the book's browser-default gaps; headings keep theirs", () {
    final src = '<body><h1>Title</h1>${chapter(30, 20).replaceAll(RegExp('</?body>'), '')}</body>';
    final book = paginate(src);
    final mine = paginate(src, theme: const EpubTheme(bookFormatting: false));
    expect(mine.length, lessThan(book.length), reason: 'no gap between paragraphs');
  });
}
