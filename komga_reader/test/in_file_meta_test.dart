// Metadata edits as they go into the book files (Apply edits to files - reports\10-27-apply-edits-plan.md): a CBZ's
// ComicInfo.xml and an EPUB's package file, only the fields edited changed. (The rewrite that puts them in: file_zip_test.)

import 'package:flutter_test/flutter_test.dart';
import 'package:komga_reader/local/in_file_meta.dart';
import 'package:komga_reader/local/local_meta.dart';

void main() {
  group("the text", () {
    test("ComicInfo.xml: the title replaced, the number and date added, everything else as it was; a date taken away "
        "takes Year, Month and Day; a book with none gets one; text escaped", () {
      const was = '<?xml version="1.0"?>\n<ComicInfo>\n  <Title>Old</Title>\n  <Writer>Brian K. Vaughan</Writer>\n'
          '  <Year>2011</Year>\n</ComicInfo>\n';
      final x = comicInfoWith(was, const BookEdits(title: 'Chapter <One> & more', number: '1', dateSet: true,
          releaseDate: '2012-03-14'));
      expect(x, contains('<Title>Chapter &lt;One&gt; &amp; more</Title>'));
      expect(x, contains('<Writer>Brian K. Vaughan</Writer>'));
      expect(x, isNot(contains('Old')));
      expect([for (final t in ['Number', 'Year', 'Month', 'Day']) RegExp('<$t>(.*?)</$t>').firstMatch(x)?[1]],
          ['1', '2012', '3', '14']);
      final cleared = comicInfoWith(x, const BookEdits(dateSet: true));
      expect(cleared, allOf(isNot(contains('<Year>')), isNot(contains('<Month>')), isNot(contains('<Day>')),
          contains('<Number>1</Number>')));
      expect(comicInfoWith(null, const BookEdits(title: 'New')), contains('<Title>New</Title>'));
    });

    test("an EPUB's package file: its title replaced (its attributes kept), its date set or taken away, its number as "
        "calibre's series index", () {
      const opf = '<package><metadata xmlns:dc="http://purl.org/dc/elements/1.1/">\n'
          '    <dc:title id="t">Old</dc:title>\n    <dc:date>1999</dc:date>\n'
          '    <meta name="calibre:series_index" content="3"/>\n  </metadata><manifest/></package>';
      final x = opfWith(opf, const BookEdits(title: 'New', number: '4', dateSet: true, releaseDate: '2020-01-02'));
      expect(x, contains('<dc:title id="t">New</dc:title>'));
      expect(x, contains('<dc:date>2020-01-02</dc:date>'));
      expect('content="4"'.allMatches(x), hasLength(1));
      expect(x, isNot(contains('content="3"')));
      expect(opfWith(x, const BookEdits(dateSet: true)), isNot(contains('dc:date')));
    });

    test('ComicInfo.xml: summary, each role its field (names by commas), tags; a role emptied is taken out', () {
      final x = comicInfoWith('<ComicInfo>\n  <Inker>Someone</Inker>\n</ComicInfo>', const BookEdits(
          summary: 'A war.', tags: ['space', 'war'],
          authors: [('Brian K. Vaughan', 'writer'), ('Fiona Staples', 'penciller'), ('Jim Lee', 'penciller')]));
      expect(x, allOf(contains('<Summary>A war.</Summary>'), contains('<Writer>Brian K. Vaughan</Writer>'),
          contains('<Penciller>Fiona Staples, Jim Lee</Penciller>'), contains('<Tags>space, war</Tags>'),
          isNot(contains('Inker'))));
    });

    test("an EPUB's package file: dc:description, dc:creator for writers and dc:contributor for the others, "
        'dc:subject for each tag - the old ones replaced', () {
      const opf = '<package><metadata>\n    <dc:creator>Old</dc:creator>\n    <dc:subject>x</dc:subject>\n'
          '  </metadata></package>';
      final x = opfWith(opf, const BookEdits(summary: 'S', authors: [('Frank Herbert', 'writer'), ('Jo', 'cover')],
          tags: ['sf', 'desert']));
      expect(x, allOf(contains('<dc:description>S</dc:description>'), contains('<dc:creator>Frank Herbert</dc:creator>'),
          contains('<dc:contributor>Jo</dc:contributor>'), contains('<dc:subject>sf</dc:subject>'),
          contains('<dc:subject>desert</dc:subject>'), isNot(contains('Old')), isNot(contains('>x<'))));
    });
  });
}
