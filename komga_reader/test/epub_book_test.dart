// The book's chapter cache (lib/epub/book.dart): chapters laid out, let go of, laid out again.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:komga_reader/epub/book.dart';
import 'package:komga_reader/epub/count_store.dart';
import 'package:komga_reader/epub/css.dart';
import 'package:komga_reader/epub/hyphenator.dart';
import 'package:komga_reader/epub/layout.dart';
import 'package:komga_reader/epub/source.dart';
import 'package:komga_reader/epub/xhtml.dart';

import 'epub_reader_test.dart' show MemorySource, para;

void main() {
  testWidgets("a chapter let go of and come back to is laid out afresh - after a new layout laid it out at once (its "
      'text already loaded), it used to hand back the freed pages and leave the reader on a spinner for good (user, '
      'build 69: deep into Homeland with the slider, then far back)', (tester) async {
    await tester.runAsync(() async {
      final hy = await Hyphenators.load((p) async => File(p).readAsStringSync());
      final spine = [for (var i = 0; i < 8; i++) 'c$i.xhtml'];
      final book = EpubBook(
          MemorySource({for (final c in spine) c: '<html><body>${para('word', 200)}</body></html>'},
              EpubInfo(spine: spine, toc: const [])),
          EpubInfo(spine: spine, toc: const []), hy);
      book.setLayout(const EpubTheme(), const Size(400, 600));
      await book.pages(0); // loaded and laid out
      book.setLayout(const EpubTheme(fontSize: 20), const Size(400, 600)); // a new layout: the text stays loaded
      await book.pages(0); // laid out again at once, from the loaded text
      book.keepAround(7); // far away: chapter 0 let go of
      expect(book.pagesNow(0), isNull);
      final again = await book.pages(0);
      expect(book.pagesNow(0), isNotNull, reason: 'laid out afresh, not the freed pages handed back');
      expect(identical(again, book.pagesNow(0)), isTrue);
      book.dispose();
    });
  });

  // outside frames (runAsync): counting's pause between chapters is a plain one
  Future<void> breath() => Future<void>.delayed(Duration.zero);

  testWidgets('counts handed over once the book is counted, and restored into a new book: counted at once, the same '
      "page numbers; a chapter that couldn't be read isn't handed over (it's tried again next time); counts that "
      "don't fit the book are refused", (tester) async {
    await tester.runAsync(() async {
      final hy = await Hyphenators.load((p) async => File(p).readAsStringSync());
      final spine = [for (var i = 0; i < 4; i++) 'c$i.xhtml'];
      final info = EpubInfo(spine: spine, toc: const []);
      final files = {for (var i = 0; i < 4; i++) spine[i]: '<html><body>${para('word', 100 + 80 * i)}</body></html>'};
      final first = EpubBook(MemorySource(files, info), info, hy)..setLayout(const EpubTheme(), const Size(400, 600));
      expect(first.counts, isNull, reason: 'not counted yet');
      await first.countAll(current: () => 0, breath: breath);
      final counts = first.counts!;
      expect(counts.starts.map((s) => s.length).toList(), [for (var i = 0; i < 4; i++) first.pageCount(i)]);
      expect(EpubCounts.fromJson(counts.toJson())!.starts, counts.starts, reason: 'survives its saved form');

      final again = EpubBook(MemorySource(files, info), info, hy)..setLayout(const EpubTheme(), const Size(400, 600));
      expect(again.restoreCounts(counts), isTrue);
      expect(again.counted, isTrue, reason: 'counted at once');
      expect(again.totalPages, first.totalPages);
      expect(again.bookPage(3, 0), first.bookPage(3, 0));
      expect(again.progression(const EpubPosition(2, 0)), first.progression(const EpubPosition(2, 0)));
      final other = EpubBook(MemorySource(files, info), info, hy)..setLayout(const EpubTheme(), const Size(400, 600));
      expect(other.restoreCounts(EpubCounts(counts.lengths.take(3).toList(), counts.starts.take(3).toList())), isFalse,
          reason: "three chapters' counts for a book of four");
      expect(other.counted, isFalse);

      final broken = EpubBook(MemorySource(Map.of(files)..remove('c2.xhtml'), info), info, hy)
        ..setLayout(const EpubTheme(), const Size(400, 600));
      await broken.countAll(current: () => 0, breath: breath);
      expect(broken.counted, isTrue, reason: 'the unreadable chapter counted as one page');
      expect(broken.counts, isNull, reason: 'not handed over: tried again next time');
      for (final b in [first, again, other, broken]) {
        b.dispose();
      }
    });
  });

  testWidgets("R5: a chapter that failed while counting (counted as one page), laid out later with its real pages - "
      "the book says its page numbers moved, so the reader can go back to the same page", (tester) async {
    await tester.runAsync(() async {
      final hy = await Hyphenators.load((p) async => File(p).readAsStringSync());
      final spine = ['c0.xhtml', 'c1.xhtml', 'c2.xhtml'];
      final info = EpubInfo(spine: spine, toc: const []);
      final files = {for (final c in spine) c: '<html><body>${para('word', 200)}</body></html>'};
      final missing = Map.of(files)..remove('c1.xhtml'); // c1 can't be read while counting
      final source = MemorySource(missing, info);
      final book = EpubBook(source, info, hy);
      book.setLayout(const EpubTheme(), const Size(400, 600));
      await book.countAll(current: () => 0, breath: breath);
      expect(book.counted, isTrue);
      expect(book.pageCount(1), 1, reason: 'counted as one page');
      final before = book.countChanges;
      source.files['c1.xhtml'] = files['c1.xhtml']!; // readable again
      book.retry(1);
      await book.pages(1);
      expect(book.pageCount(1), greaterThan(1));
      expect(book.countChanges, before + 1);
      book.dispose();
    });
  });

  testWidgets("E16: a link's target is where the chapter's reader put it - counted from the file's text it drifted "
      'a character per block (the whitespace between them), and a target deep in a chapter landed late', (tester) async {
    await tester.runAsync(() async {
      final hy = await Hyphenators.load((p) async => File(p).readAsStringSync());
      final body = '${List.generate(60, (i) => '\n    <p>Paragraph number $i of the chapter.</p>').join()}'
          '\n    <p>Before <span id="note">the note</span> here.</p>';
      final info = EpubInfo(spine: const ['c.xhtml'], toc: const []);
      final book = EpubBook(MemorySource({'c.xhtml': '<html><body>$body</body></html>'}, info), info, hy);
      final blocks = ChapterReader(StyleSheet(), (h) => h).read(parseXhtml('<body>$body</body>'));
      final last = blocks.last as TextBlock;
      expect(await book.positionOfFragment(0, 'note'), last.start + 'Before '.length);
      expect(await book.positionOfFragment(0, 'nowhere'), 0);
      book.dispose();
    });
  });
}
