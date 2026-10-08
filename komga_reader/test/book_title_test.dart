import 'package:flutter_test/flutter_test.dart';
import 'package:komga_reader/book_title.dart';

// The one "series #number" builder (code review 2026-10-05, #54): each option keeps the output its callers had.
void main() {
  const full = {'seriesTitle': 'Saga', 'number': 9, 'metadata': {'number': '3'}};
  const noSeries = {'metadata': {'number': '3'}};
  const noMetaNumber = {'seriesTitle': 'Saga', 'number': 9, 'metadata': <String, dynamic>{}};
  const noNumber = {'seriesTitle': 'Saga', 'metadata': <String, dynamic>{}};
  const noMetadata = {'seriesTitle': 'Saga', 'number': 9};

  test('plain: the metadata number, a missing one empty, spaces kept', () {
    expect(bookTitle(full), 'Saga #3');
    expect(bookTitle(noSeries), ' #3');
    expect(bookTitle(noMetaNumber), 'Saga #');
    expect(bookTitle(noMetadata), 'Saga #');
  });

  test('trim: no leading space without a series, no trailing one without a number', () {
    expect(bookTitle(full, trim: true), 'Saga #3');
    expect(bookTitle(noSeries, trim: true), '#3');
    expect(bookTitle(noMetaNumber, trim: true), 'Saga #');
  });

  test("bookNumber: the book's own number when the metadata has none; the metadata's first", () {
    expect(bookTitle(full, bookNumber: true), 'Saga #3');
    expect(bookTitle(noMetaNumber, bookNumber: true), 'Saga #9');
    expect(bookTitle(noMetadata, bookNumber: true, trim: true), 'Saga #9');
    expect(bookTitle(noNumber, bookNumber: true), 'Saga #null', reason: 'as those callers always showed it');
  });

  test("the reader's heading: none without a series, no number part without a number", () {
    expect(bookHeading(full), 'Saga #3');
    expect(bookHeading(noSeries), isNull);
    expect(bookHeading({'seriesTitle': '', 'metadata': {'number': '3'}}), isNull);
    expect(bookHeading(noMetaNumber), 'Saga');
    expect(bookHeading({'seriesTitle': 'Saga', 'metadata': {'number': ''}}), 'Saga #');
  });
}
