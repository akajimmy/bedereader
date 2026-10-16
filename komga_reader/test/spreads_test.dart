// Comics in two pages: how the pages pair (user's choices, 2026-10-16 - lib/reader/spreads.dart).
import 'package:flutter_test/flutter_test.dart';
import 'package:komga_reader/reader/spreads.dart';

/// A book's pages written as text: '.' a single page, 'W' a wide one.
List<bool> book(String s) => [for (final c in s.split('')) c == 'W'];

/// The spreads written as text, e.g. "[-|0] [1|2] [3 wide]".
String paired(String s, {bool shifted = false}) => pairPages(book(s), shifted: shifted).join(' ');

void main() {
  test('a book with no wide page: the cover alone on the right, then pairs from page 2; an odd last page alone on '
      'the left', () {
    expect(paired('.......'), '[-|0] [1|2] [3|4] [5|6]');
    expect(paired('......'), '[-|0] [1|2] [3|4] [5|-]');
    expect(paired('.'), '[-|0]');
  });

  test('a wraparound cover pairs exactly as a normal one (user, 2026-10-16): alone, then the next page on the left',
      () {
    expect(paired('W.....'), '[0 wide] [1|2] [3|4] [5|-]');
    expect(paired('......'), '[-|0] [1|2] [3|4] [5|-]');
    expect(paired('W....W..'), '[0 wide] [1|2] [3|4] [5 wide] [6|7]');
    expect(paired('.....W..'), '[-|0] [1|2] [3|4] [5 wide] [6|7]');
  });

  test('anchored on a spread: the pages before it pair backwards from it, so it starts on a left page; an odd one is '
      'alone right after the cover, on the right - where a dropped inside cover leaves it (42 of 241 sampled books)',
      () {
    // cover, 5 single pages, a spread, 2 more
    expect(paired('......W..'), '[-|0] [-|1] [2|3] [4|5] [6 wide] [7|8]');
    // an even run needs nothing
    expect(paired('.....W..'), '[-|0] [1|2] [3|4] [5 wide] [6|7]');
    // between two spreads: an odd run (a page missing or extra between them) - one alone after the first spread
    // (the last page after a spread: a left-hand page, alone)
    expect(paired('..W...W.'), '[-|0] [-|1] [2 wide] [-|3] [4|5] [6 wide] [7|-]');
    // spreads one after another; a book ending on one
    expect(paired('.WW..W'), '[-|0] [1 wide] [2 wide] [3|4] [5 wide]');
  });

  test('"Shift pairing by one" flips the first run only - the pages up to the first spread, or the whole book with '
      'none; the pairs after a spread stay, anchored by it', () {
    expect(paired('......W..', shifted: true), '[-|0] [1|2] [3|4] [5|-] [6 wide] [7|8]');
    expect(paired('.....W..', shifted: true), '[-|0] [-|1] [2|3] [4|-] [5 wide] [6|7]');
    expect(paired('.......', shifted: true), '[-|0] [-|1] [2|3] [4|5] [6|-]');
    expect(paired('W....W..', shifted: true), '[0 wide] [-|1] [2|3] [4|-] [5 wide] [6|7]');
    expect(paired('..W...W.', shifted: true).split(' ').skip(3).join(' '),
        paired('..W...W.').split(' ').skip(3).join(' '), reason: 'after the first spread: unchanged');
  });

  test('every page is in exactly one spread, in order; the index finds each page\'s spread', () {
    for (final s in ['.......', '......W..', '..W...W.', 'W', 'WW.', '.WW..W', '..']) {
      for (final shifted in [false, true]) {
        final spreads = pairPages(book(s), shifted: shifted);
        expect([for (final x in spreads) ...x.pages], List.generate(s.length, (i) => i), reason: '$s $shifted');
        final of = spreadIndex(spreads, s.length);
        for (var p = 0; p < s.length; p++) {
          expect(spreads[of[p]].pages, contains(p));
        }
      }
    }
  });

  test("eBooks: each chapter starts on a right-hand page (user, 2026-10-16) - the page beside it blank; then pairs; an "
      'odd last page alone on the left; a spread never holds two chapters; an empty chapter takes nothing', () {
    String chapters(List<int> counts) => pairChapters(counts).join(' ');
    expect(chapters([1, 4, 3]), '[-|0] [-|1] [2|3] [4|-] [-|5] [6|7]');
    expect(chapters([5]), '[-|0] [1|2] [3|4]');
    expect(chapters([2, 0, 2]), '[-|0] [1|-] [-|2] [3|-]');
    for (final counts in [[1, 4, 3], [5], [2, 0, 2], [7, 1, 6]]) {
      final total = counts.fold(0, (a, b) => a + b);
      final spreads = pairChapters(counts);
      expect([for (final s in spreads) ...s.pages], List.generate(total, (i) => i), reason: '$counts: every page once');
    }
  });

  test('wide: wider than tall, from the page list Komga gives; a square page or one of unknown size is a single',
      () {
    expect(isWidePage({'width': 2000, 'height': 1500}), isTrue);
    expect(isWidePage({'width': 1500, 'height': 1500}), isFalse);
    expect(isWidePage({'width': 1000, 'height': 1500}), isFalse);
    expect(isWidePage({'number': 1}), isFalse);
    expect(isWidePage({'width': 2000, 'height': 0}), isFalse);
  });
}
