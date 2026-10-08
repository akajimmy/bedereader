import 'package:flutter_test/flutter_test.dart';
import 'package:komga_reader/book_title.dart';

// The one "series #number" builder (code review 2026-10-05, #54).
void main() {
  const full = {'seriesTitle': 'Saga', 'number': 9, 'metadata': {'number': '3'}};
  const noSeries = {'metadata': {'number': '3'}};
  const noMetaNumber = {'seriesTitle': 'Saga', 'number': 9, 'metadata': <String, dynamic>{}};
  const noNumber = {'seriesTitle': 'Saga', 'metadata': <String, dynamic>{}};
  const emptyNumber = {'seriesTitle': 'Saga', 'metadata': {'number': ''}};

  test("the metadata's number first, else the book's own", () {
    expect(bookTitle(full), 'Saga #3');
    expect(bookTitle(noMetaNumber), 'Saga #9');
    expect(bookTitle({'seriesTitle': 'Saga', 'number': 9}), 'Saga #9');
  });

  test('a book with no number is just the series - never "#null" or a bare "#"', () {
    expect(bookTitle(noNumber), 'Saga');
    expect(bookTitle(emptyNumber), 'Saga');
  });

  test('no series: just the number, with no leading space; neither: empty', () {
    expect(bookTitle(noSeries), '#3');
    expect(bookTitle(<String, dynamic>{}), '');
  });

  test("the reader's heading: none without a series, else the title", () {
    expect(bookHeading(full), 'Saga #3');
    expect(bookHeading(noSeries), isNull);
    expect(bookHeading({'seriesTitle': '', 'metadata': {'number': '3'}}), isNull);
    expect(bookHeading(noNumber), 'Saga');
    expect(bookHeading(emptyNumber), 'Saga');
  });
}
