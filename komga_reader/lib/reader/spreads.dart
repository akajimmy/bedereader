import 'package:flutter/foundation.dart';

/// What two pages side by side show (dual-page mode - user, 2026-10-16): a pair, a page alone in one of the two
/// slots, or a wide page across both. Pages are 0-based indexes into the book's pages; [earlier] / [later] are in
/// reading order - left / right in a left-to-right book, right / left in a right-to-left one (the renderer mirrors).
@immutable
class Spread {
  const Spread.pair(int this.earlier, int this.later) : wide = false;
  const Spread.alone({this.earlier, this.later})
      : wide = false,
        assert((earlier == null) != (later == null));
  const Spread.wide(int page)
      : earlier = page,
        later = null,
        wide = true;

  final int? earlier, later;

  /// One page across both slots (a spread saved as one picture, a wraparound cover).
  final bool wide;

  /// Its pages, in reading order.
  List<int> get pages => [if (earlier != null) earlier!, if (later != null) later!];
  int get first => earlier ?? later!;
  int get last => later ?? earlier!;

  @override
  bool operator ==(Object other) =>
      other is Spread && other.earlier == earlier && other.later == later && other.wide == wide;
  @override
  int get hashCode => Object.hash(earlier, later, wide);
  @override
  String toString() => wide ? '[$earlier wide]' : '[${earlier ?? '-'}|${later ?? '-'}]';
}

/// A page wider than tall: shown alone, across both slots. A page of unknown size is a single one.
bool isWidePage(Map page) {
  final w = page['width'], h = page['height'];
  return w is num && h is num && h > 0 && w > h;
}

/// A comic's pages paired for two pages side by side (user's choices, 2026-10-16 - NOTES, "Dual-page mode"):
/// - the cover (page 1) alone, in the later slot, as a book's first page is a right-hand one;
/// - a wide page always alone, across both slots (a wraparound cover too - so it pairs exactly as a normal cover);
/// - the single pages before a wide page pair backwards from it: in print a spread starts on a left-hand page, so the
///   page before it is a right-hand one. An odd one is left alone at the start of the run, in the later slot - where
///   a dropped inside cover leaves it (42 of 241 sampled books: reports\10-16-dual-page-sample.md);
/// - after the last wide page (and in a book with none) forwards, an odd last page alone in the earlier slot.
/// [shifted] (the reader's "Shift pairing by one", per book) flips the first run only - the pages after the cover up
/// to the first wide page, or the whole book with none: the pairs after a wide page are anchored by it and stay.
List<Spread> pairPages(List<bool> wide, {bool shifted = false}) {
  final n = wide.length;
  if (n == 0) return const [];
  final out = <Spread>[wide[0] ? const Spread.wide(0) : const Spread.alone(later: 0)];
  var start = 1;
  var firstRun = true;
  while (start < n) {
    var end = start; // the run of single pages [start, end)
    while (end < n && !wide[end]) {
      end++;
    }
    final anchored = end < n; // a wide page follows: pair backwards from it
    var loneFirst = anchored && (end - start).isOdd;
    if (firstRun && shifted) loneFirst = !loneFirst;
    var i = start;
    if (loneFirst && i < end) out.add(Spread.alone(later: i++));
    for (; i + 1 < end; i += 2) {
      out.add(Spread.pair(i, i + 1));
    }
    if (i < end) out.add(Spread.alone(earlier: i)); // one left over at the end of the run
    if (end < n) out.add(Spread.wide(end));
    start = end + 1;
    firstRun = false;
  }
  return out;
}

/// The spread each page is in: index i holds the spread number of page i.
List<int> spreadIndex(List<Spread> spreads, int pageCount) {
  final of = List<int>.filled(pageCount, 0);
  for (var s = 0; s < spreads.length; s++) {
    for (final p in spreads[s].pages) {
      of[p] = s;
    }
  }
  return of;
}
