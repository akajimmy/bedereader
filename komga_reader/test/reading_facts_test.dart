// A book's details, its reading facts (the tablet, 2026-10-27: a network EPUB said "Pages 100").
import 'package:flutter_test/flutter_test.dart';
import 'package:komga_reader/screens/book_details.dart' show readingFacts;

void main() {
  test("a local or network EPUB's details: its progress as a share of the book, and no page count (it was \"Pages "
      "100\"); a Komga book's as before", () {
    Map b(String id, Map? rp) => {
          'id': id, 'readProgress': rp,
          'media': {'pagesCount': 100, 'mediaProfile': 'EPUB'}, 'metadata': {}, 'name': 'x',
        };
    expect(readingFacts(b('lb0123456789abc', {'page': 37, 'completed': false})), ('In progress · 37%', null));
    expect(readingFacts(b('lb0123456789abc', null)).$2, isNull);
    expect(readingFacts(b('B1', {'page': 37, 'completed': false})), ('In progress · page 37 of 100', 100));
  });
}
