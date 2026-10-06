// The book's chapter cache (lib/epub/book.dart): chapters laid out, let go of, laid out again.
import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:komga_reader/epub/book.dart';
import 'package:komga_reader/epub/hyphenator.dart';
import 'package:komga_reader/epub/layout.dart';
import 'package:komga_reader/epub/source.dart';

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

  testWidgets('counting the book waits while pages are being turned, and carries on after (turns stuttered while a '
      'big book was being counted - user, build 71)', (tester) async {
    await tester.runAsync(() async {
      final hy = await Hyphenators.load((p) async => File(p).readAsStringSync());
      final spine = [for (var i = 0; i < 6; i++) 'c$i.xhtml'];
      final info = EpubInfo(spine: spine, toc: const []);
      final book = EpubBook(MemorySource({for (final c in spine) c: '<html><body>${para('word', 200)}</body></html>'},
          info), info, hy);
      book.setLayout(const EpubTheme(), const Size(400, 600));
      var turning = true;
      unawaited(book.countAll(current: () => 0, busy: () => turning));
      await Future<void>.delayed(const Duration(milliseconds: 600));
      expect(book.counted, isFalse, reason: 'still turning: counting waits after the first chapter');
      expect(book.pageCount(0), isNotNull);
      expect(book.pageCount(2), isNull);
      turning = false;
      for (var i = 0; i < 100 && !book.counted; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      expect(book.counted, isTrue, reason: 'turning stopped: counted');
      book.dispose();
    });
  });

  testWidgets("how far through the book, before it's counted: chapters weighed by Komga's positions, not as equals (a "
      "short chapter then long ones: 24% became 2% once counted - user, build 74, The Dispossessed); once they're all "
      'read in, by their lengths', (tester) async {
    await tester.runAsync(() async {
      final hy = await Hyphenators.load((p) async => File(p).readAsStringSync());
      final spine = ['c0.xhtml', 'c1.xhtml', 'c2.xhtml', 'c3.xhtml'];
      final words = [20, 180, 200, 200];
      final info = EpubInfo(spine: spine, toc: const []);
      EpubBook make() => EpubBook(
          MemorySource({for (var i = 0; i < 4; i++) spine[i]: '<html><body>${para('word', words[i])}</body></html>'},
              info),
          info, hy);
      final book = make();
      expect(book.progression(const EpubPosition(1, 0)), 0.25, reason: 'nothing known: equal shares');
      // Komga's positions: 1 in the short chapter, 9, 10, 10 in the others
      book.estimateFrom([for (var i = 0; i < 4; i++) ...List.filled(i == 0 ? 1 : words[i] ~/ 20, spine[i])]);
      expect(book.progression(const EpubPosition(1, 0)), closeTo(1 / 30, 1e-9));
      expect(book.chapterAtFraction(0.5).$1, 2, reason: 'half way is in chapter 2, not chapter 1');
      // every chapter read in (a book of 4: the text-size sample loads them all): their lengths
      await book.measureTextSize();
      final lengths = [for (var i = 0; i < 4; i++) book.lengthOf(i)];
      expect(lengths.every((l) => l > 0), isTrue);
      expect(book.progression(const EpubPosition(1, 0)),
          closeTo(lengths[0] / lengths.fold(0, (a, b) => a + b), 1e-9));
      book.dispose();
    });
  });
}
