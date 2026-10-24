// The reader's page cache (lib/page_image.dart PageLoader): a slow load that fails doesn't take a newer load of the
// same page with it (code review 2026-10-05, #18: the page was downloaded again).
import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:komga_reader/page_image.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/epub_books.dart' show onePixelPng;
import 'support/no_network.dart';

/// A Komga whose page loads wait to be finished by the test, one completer per request, in order.
class HeldPages extends TestKomga {
  final requests = <Completer<Uint8List>>[]; // page 1's (others - the pages read ahead - are just held)
  @override
  Future<Uint8List> pageBytes(String bookId, int number) {
    final c = Completer<Uint8List>();
    if (number == 1) requests.add(c);
    return c.future;
  }
}

/// A Komga whose every page is a small picture, at once.
class AllPages extends TestKomga {
  @override
  Future<Uint8List> pageBytes(String bookId, int number) async => onePixelPng;
}

/// [AllPages], counting what's asked for.
class CountedPages extends TestKomga {
  final asked = <int>[];
  @override
  Future<Uint8List> pageBytes(String bookId, int number) async {
    asked.add(number);
    return onePixelPng;
  }
}

void main() {
  testWidgets("Enhance colours' remembered levels: the most recent $levelsKept books kept, the oldest goes - one was "
      'kept for every book ever opened with it (code review 2026-10-05, #49)', (tester) async {
    SharedPreferences.setMockInitialValues({
      for (var i = 0; i < levelsKept; i++) 'levels.old$i': '0,0,0,1,1,1',
      'levels.books': [for (var i = 0; i < levelsKept; i++) 'old$i'], // oldest first
    });
    await tester.runAsync(() async {
      await PageLoader(noNetwork(AllPages.new), 'NEW', List.generate(10, (i) => i + 1)).bookLevels();
      final p = await SharedPreferences.getInstance();
      final kept = p.getKeys().where((k) => k.startsWith('levels.') && k != 'levels.books').toList();
      expect(kept, hasLength(levelsKept));
      expect(p.getString('levels.NEW'), isNotNull, reason: 'the book just measured is kept');
      expect(p.getStringList('levels.books')!.last, 'NEW');
      expect(p.getString('levels.old0'), isNull, reason: 'the oldest gone');
      expect(p.getString('levels.old1'), isNotNull);
    });
  });

  testWidgets('two pages up, pages are kept decoded only one turn back and two ahead; their files a little further, so '
      'a page come back to is decoded again without asking Komga (user, 2026-10-24: killed for memory, 11 pages were '
      'kept decoded)', (tester) async {
    await tester.runAsync(() async {
      final api = noNetwork(CountedPages.new);
      final loader = PageLoader(api, 'B1', List.generate(30, (i) => i + 1));
      for (var i = 0; i <= 12; i += 2) { // read on, a pair at a time
        await loader.get(i);
        loader.around(i, span: 2);
        for (final j in loader.held.$1) {
          await loader.get(j); // (arrived)
        }
      }
      final (decoded, files) = loader.held;
      expect(decoded, everyElement(inInclusiveRange(10, 16)), reason: 'one turn back, two ahead');
      expect(decoded, containsAll([10, 11, 12, 13, 14]));
      expect(files, containsAll([8, 9]), reason: 'two turns back: the files');
      expect(files, everyElement(inInclusiveRange(8, 18)));
      final asked = api.asked.length;
      await loader.get(8);
      expect(api.asked.length, asked, reason: 'decoded again from its file - not asked for again');
    });
  });

  testWidgets('a slow failing load of a page leaves the newer load of it in place', (tester) async {
    await tester.runAsync(() async {
      final api = noNetwork(HeldPages.new);
      final loader = PageLoader(api, 'B1', List.generate(20, (i) => i + 1));
      final first = loader.get(0)..ignore(); // slow, and it will fail
      loader.around(10); // read on: page 0 forgotten
      final second = loader.get(0); // back again: asked for afresh
      expect(api.requests, hasLength(2));
      api.requests[1].complete(onePixelPng); // the new one arrives
      await second;
      api.requests[0].completeError(StateError('timed out')); // then the old one fails
      await first.then((_) {}, onError: (Object _) {});
      loader.get(0).ignore(); // the page again: from the cache
      expect(api.requests, hasLength(2), reason: 'not downloaded a third time');
    });
  });
}
