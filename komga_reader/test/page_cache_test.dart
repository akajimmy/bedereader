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
