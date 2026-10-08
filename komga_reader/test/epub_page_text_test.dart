// A page's text for selecting and copying (lib/epub/page_text.dart): what's under a point, words, the copied text.
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

  List<EpubPage> paginate(String body, {Size size = const Size(400, 600), bool hyphenate = false}) =>
      Paginator(const EpubTheme(), size, hyphenate ? hy.forLang('en') : null)
          .run(ChapterReader(StyleSheet(), (h) => h).read(parseXhtml('<body>$body</body>')));

  // paragraphs of distinct words: w<paragraph>x<word>
  String paras(int n, int words) => [
        for (var p = 0; p < n; p++) '<p>${[for (var w = 0; w < words; w++) 'w${p}x$w'].join(' ')}</p>',
      ].join();

  test('word boundaries come from the text: letters and digits, apostrophes and hyphens inside a word, soft hyphens; '
      'a space takes the word before it, a dash or quote mark is itself', () {
    String word(String t, int c) {
      final (a, b) = wordAround(t, c);
      return t.substring(a, b);
    }
    const t = 'He said “don’t” to a well-known extra\u00ADordinary man — twice.';
    expect(word(t, t.indexOf('on’t')), 'don’t');
    expect(word(t, t.indexOf('known')), 'well-known');
    expect(word(t, t.indexOf('well') + 4), 'well-known', reason: 'on the hyphen itself');
    expect(word(t, t.indexOf('ordinary')), 'extra\u00ADordinary');
    expect(word(t, t.indexOf(' to')), 'to', reason: 'a space after a quote mark: the word after it');
    expect(word(t, t.indexOf(' a ') + 1), 'a');
    expect(word(t, t.indexOf('said') - 1), 'He', reason: 'a space: the word before it');
    expect(word(t, t.indexOf('—')), '—');
    expect(word(t, t.indexOf('twice') + 5), '.');
    expect(wordAround('ab cd', 3, 3, 5), (3, 5), reason: 'kept within the range given');
  });

  test("a point on a word finds that word; two points select what's between them, a caret's width at a time", () {
    final page = paginate(paras(1, 40)).single, text = page.text;
    for (var w = 0; w < 40; w++) {
      final r = text.boxesOf('w0x$w').first;
      for (final p in [r.center, r.centerLeft + const Offset(1, 0), r.centerRight - const Offset(1, 0)]) {
        final (a, b) = text.wordAt(p)!;
        expect(text.textOf(a, b), 'w0x$w', reason: 'at $p');
      }
    }
    final from = text.boxesOf('w0x2').first, to = text.boxesOf('w0x4').first;
    expect(text.textOf(text.spotAt(from.centerLeft + const Offset(1, 0)), text.spotAt(to.centerRight - const Offset(1, 0))),
        'w0x2 w0x3 w0x4');
    expect(text.textOf(text.spotAt(to.centerRight - const Offset(1, 0)), text.spotAt(from.centerLeft)),
        'w0x2 w0x3 w0x4', reason: 'either way round');
    expect(text.wordAt(const Offset(2, 2)), isNull, reason: 'the margin: no word');
  });

  test('an emoji (two UTF-16 halves) is never split: not by a selection edge, not by the search for one', () {
    const smile = '\u{1F600}';
    final page = paginate('<p>a$smile$smile$smile b ${smile}x$smile c</p>').single, text = page.text;
    bool whole(String s) => s.isEmpty || !(s.codeUnitAt(s.length - 1) >= 0xD800 && s.codeUnitAt(s.length - 1) <= 0xDBFF);
    final line = text.boxesOf('a$smile').first;
    // every point along the line, a pixel at a time: the edge there leaves no half emoji behind it
    for (var x = 0.0; x < 400; x += 1) {
      final s = text.textOf(text.first, text.spotAt(Offset(x, line.center.dy)));
      expect(whole(s), isTrue, reason: 'an edge at x $x split an emoji: ${s.codeUnits}');
    }
    final r = text.boxesOf('${smile}x').first;
    final (a, b) = text.wordAt(r.centerLeft + const Offset(2, 0))!;
    expect(whole(text.textOf(a, b)) && text.textOf(a, b).contains(smile), isTrue, reason: 'the emoji whole');
  });

  test('a selection across paragraphs: in reading order, a newline between them, no space left at the line end', () {
    final page = paginate(paras(2, 12)).single, text = page.text;
    final a = text.wordAt(text.boxesOf('w0x10').first.center)!, b = text.wordAt(text.boxesOf('w1x1').first.center)!;
    expect(text.textOf(a.$1, b.$2), 'w0x10 w0x11\nw1x0 w1x1');
    expect(text.textOf(text.first, text.last).split('\n'), hasLength(2));
    // between the paragraphs (below the first's last line): the end of the first
    final gapY = (text.boxesOf('w0x11').first.bottom + text.boxesOf('w1x0').first.top) / 2;
    final under = text.boxesOf('w0x11').first.bottom;
    if (gapY > under) expect(text.textOf(a.$1, text.spotAt(Offset(10, gapY))), 'w0x10 w0x11');
  });

  test('copied text is plain: a word broken over two lines (at a soft hyphen) is one word again, no soft hyphens, no '
      "indent placeholder; a drop cap's letter starts its paragraph again", () {
    const words = 'The extraordinary fishermen remembered uncomfortable temperatures and particularly '
        'unpredictable weather conditions throughout their understandable conversations. ';
    final source = words.replaceAll('.', '').split(' ').where((w) => w.isNotEmpty).toSet();
    final pages = paginate('<p style="text-indent: 2em">${List.filled(6, words).join()}</p>',
        size: const Size(300, 2000), hyphenate: true);
    final page = pages.first, text = page.text;
    expect(page.hyphenMarks, greaterThan(0), reason: 'words broken at line ends on the page');
    expect(page.textIndents.first, greaterThan(0), reason: 'an indent (its placeholder in the text)');
    final all = text.textOf(text.first, text.last);
    expect(all, isNot(contains('\u00AD')));
    expect(all, isNot(contains('\uFFFC')));
    for (final w in all.replaceAll('.', '').split(RegExp(r'\s+')).where((w) => w.isNotEmpty)) {
      expect(source, contains(w), reason: 'every word whole');
    }
    expect(all, startsWith('The extraordinary'));

    final drop = paginate('<p><span style="float: left">T</span>he quick brown fox.</p>').single.text;
    expect(drop.textOf(drop.first, drop.last), 'The quick brown fox.');
  });

  test('the point-to-character search never asks the engine which character is at a point: getPositionForOffset '
      '(and the word-boundary calls built on it) crashed release builds - see _Laid.lines', () {
    // a guard over the code that lays out and shows EPUB pages: TextPainter can't be swapped for a fake inside the
    // paginator, so the calls are kept out of the source (comments may name them)
    final banned = RegExp(r'\b(getPositionForOffset|getWordBoundary|getWordAtOffset|getGlyphPositionAtCoordinate)\s*\(');
    for (final dir in ['lib/epub', 'lib/reader']) {
      for (final f in Directory(dir).listSync(recursive: true).whereType<File>().where((f) => f.path.endsWith('.dart'))) {
        final code = f.readAsLinesSync().map((l) => l.replaceFirst(RegExp(r'//.*'), '')).join('\n');
        expect(banned.hasMatch(code), isFalse, reason: '${f.path} calls ${banned.firstMatch(code)?.group(1)}');
      }
    }
  });
}
