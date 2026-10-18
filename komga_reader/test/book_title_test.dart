import 'package:flutter_test/flutter_test.dart';
import 'package:komga_reader/book_title.dart';

// The one "series #number" builder (code review 2026-10-05, #54).
void main() {
  test('an eBook is named by its title and author, not its series and number (user, 2026-10-18: "Nobody thinks of '
      'books in that way"); a comic as before', () {
    const ebook = {'seriesTitle': 'Discworld', 'media': {'mediaProfile': 'EPUB'}, 'name': 'small-gods',
      'metadata': {'number': '13', 'title': 'Small Gods', 'authors': [
        {'name': 'Josh Kirby', 'role': 'cover'}, {'name': 'Terry Pratchett', 'role': 'writer'},
        {'name': 'Neil Gaiman', 'role': 'writer'}, {'name': 'Terry Pratchett', 'role': 'writer'}]}};
    const comic = {'seriesTitle': 'Saga', 'media': {'mediaProfile': 'DIVINA'},
      'metadata': {'number': '3', 'title': 'Chapter Three', 'authors': [{'name': 'Brian K. Vaughan', 'role': 'writer'}]}};
    expect((bookTitle(ebook), bookSubtitle(ebook), bookHeading(ebook)),
        ('Small Gods', 'Terry Pratchett, Neil Gaiman', 'Terry Pratchett, Neil Gaiman'), reason: 'writers, each once');
    expect(bookSeriesLine(ebook), 'Discworld #13', reason: 'still there, for the poster line that asks for it');
    expect((bookTitle(comic), bookSubtitle(comic), bookHeading(comic)), ('Saga #3', 'Chapter Three', 'Saga #3'));
    // no writer: whoever Komga lists first; nobody: nothing (the reader's top bar has no heading then)
    expect(bookAuthors({'metadata': {'authors': [{'name': 'Josh Kirby', 'role': 'cover'}]}}), 'Josh Kirby');
    expect(bookHeading({...ebook, 'metadata': {'title': 'Small Gods'}}), isNull);
    // an eBook with no title of its own: its file name; none at all, the series and number
    expect(bookTitle({...ebook, 'metadata': {'number': '13'}}), 'small-gods');
    expect(bookTitle({'seriesTitle': 'Discworld', 'media': {'mediaProfile': 'EPUB'}, 'metadata': {'number': '13'}}),
        'Discworld #13');
  });

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
