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
}
