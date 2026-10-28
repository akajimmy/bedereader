// What a book's file says about it (lib/local/book_names.dart): ids, the number / title / series in its name, its
// pages, its ComicInfo.xml and an EPUB's metadata - the local libraries' rules, tried on the NAS's names (2026-10-26).
import 'package:flutter_test/flutter_test.dart';
import 'package:komga_reader/local/book_names.dart';
import 'package:komga_reader/local/file_zip.dart';

import 'support/memory_fs.dart';
import 'support/zip_writer.dart';

void main() {
  group('ids', () {
    test("a local id is told from Komga's by its form, whatever its hash: 'l' and its kind, then 13 characters - "
        'never a minus (half the experiment\'s began with one)', () {
      for (final p in [r'C:\Comics', '/storage/emulated/0/Comics', r'\\nick-nas\NAS-SHARE\COMICS', 'x', '']) {
        for (final id in [localLibraryId(p), localSeriesId(p), localBookId(p), localReadListId(p)]) {
          expect(id, matches(RegExp(r'^l[lsbr][0-9a-z]{13}$')), reason: id);
          expect(isLocalId(id), isTrue);
        }
      }
      // Komga's: capitals and digits
      for (final komga in ['0S0E37AS8KD0N', 'LIB1', 'B0001', 'S2', 'R9Z']) {
        expect(isLocalId(komga), isFalse, reason: komga);
      }
      expect(isLocalId(null), isFalse);
    });

    test('the same file in any case, written with either slash or a trailing one, is the same book; another is another '
        '(user, 2026-10-26: the places books live tell no case apart)', () {
      expect(localBookId(r'\\NICK-NAS\Comics\Saga #1.cbz'), localBookId('//nick-nas/comics/saga #1.cbz'));
      expect(localLibraryId(r'C:\Comics\'), localLibraryId('c:/comics'));
      expect(localBookId(r'C:\Comics\Saga #1.cbz'), isNot(localBookId(r'C:\Comics\Saga #2.cbz')));
      expect(localBookId('a'), isNot(localSeriesId('a')), reason: 'the kind is in the id');
    });

    test("iPad: a library kept from before the app's folder moved (its GUID changed) has the same ids - progress kept",
        () {
      const a = '/var/mobile/Containers/Data/Application/AC3D1135-B7F2-4A3C-A311-EE511E0826EB/Documents/Saga';
      const b = '/private/var/mobile/Containers/Data/Application/0F1E2D3C-4B5A-6978-8796-A5B4C3D2E1F0/Documents/Saga';
      expect(localLibraryId(a), localLibraryId(b));
    });
  });

  group('names', () {
    test("the issue number: after #, else after the series' own name, else the first number; a title after it", () {
      expect(parseBookName('Absolute Batman 010 (2025) (Digital) (Shan-Empire)', 'Absolute Batman (2024)'),
          (number: 10.0, title: null, year: 2025));
      expect(parseBookName('Spider-Island - Cloak & Dagger (2011) #002', 'Spider-Island - Cloak & Dagger (2011)'),
          (number: 2.0, title: null, year: 2011));
      expect(parseBookName('Dune 02 - Dune Messiah', 'Dune'), (number: 2.0, title: 'Dune Messiah', year: null));
      expect(parseBookName('Spider-Man 2099 #3', 'Spider-Man 2099').number, 3.0);
      expect(parseBookName('Spider-Man 2099 004', 'Spider-Man 2099').number, 4.0, reason: 'not 2099');
      expect(parseBookName('Saga #1.5', 'Saga').number, 1.5);
      expect(parseBookName('Frankenstein - Mary Shelley', '').number, isNull);
    });

    test("a book's series from its file name, in a read list: up to its number, without a reading order at the start "
        'or a "Vol." before the number', () {
      expect(seriesFromName('002 - Green Lantern 021(2007)(2 covers)(Digital)(TLK-EMPIRE-HD)'), 'Green Lantern');
      expect(seriesFromName('007 - Tales of the Sinestro Corps - Parallax (2007) (Minutemen-Ace of Scans)'),
          'Tales of the Sinestro Corps - Parallax', reason: 'no number: the whole name');
      expect(seriesFromName('Spider-Island - Cloak & Dagger (2011) #002'), 'Spider-Island - Cloak & Dagger');
      expect(seriesFromName('Fables (2002) Vol. 22 - Farewell'), 'Fables');
      expect(seriesFromName('White Sand (2016) v 3'), 'White Sand');
      // "v03" isn't a number of its own: taking it for one would put Green Lantern v3 and v5 in one series
      expect(seriesFromName('Brightest Day v01 (2010)'), 'Brightest Day v01');
      expect(seriesFromName('Absolute Batman 010 (2025) (Digital) (Shan-Empire)'), 'Absolute Batman');
    });

    // user, 2026-10-26: cut after a " - " or ": " in what they share, else at its last word break
    test("a series' books' titles without the start they share", () {
      expect(withoutSharedStart(['Green Lantern Mosaic 001 (1992)', 'Green Lantern Mosaic 012 (1993)']),
          ['001 (1992)', '012 (1993)']);
      expect(withoutSharedStart(['Green Lantern - Rebirth 001 (2004) (Digital-Empire)', 'Green Lantern - Rebirth 002']),
          ['Rebirth 001 (2004) (Digital-Empire)', 'Rebirth 002']);
      expect(withoutSharedStart(['Batman - Year One 01 - Who I Am', 'Batman - Year One 02 - War Is Declared']),
          ['Year One 01 - Who I Am', 'Year One 02 - War Is Declared']);
      expect(withoutSharedStart(['Spider-Man 001', 'Spider-Man 002']), ['001', '002'], reason: 'a hyphen in a word');
      expect(withoutSharedStart(['Saga', 'Saga 2']), isNull, reason: 'one would be left empty');
      expect(withoutSharedStart(['Saga 1']), isNull, reason: 'one book');
      expect(withoutSharedStart(['Saga 1', 'RESIZED']), isNull, reason: 'nothing shared');
    });

    test("a comic's pages: its pictures in natural order (page 2 before page 10) - not a Mac's resource forks or "
        'other hidden files', () {
      expect(comicPages(['p10.jpg', 'p2.jpg', 'p1.JPG', 'notes.txt', '__MACOSX/p1.jpg', 'dir/', '._p3.jpg']),
          ['p1.JPG', 'p2.jpg', 'p10.jpg']);
      expect(imageType('a.WEBP'), 'image/webp');
    });
  });

  group('ComicInfo.xml', () {
    test("its title, number, people, publisher, genres, manga's direction and each page's size", () {
      final i = ComicInfo.parse('<?xml version="1.0"?><ComicInfo><Title>The Black Swordsman</Title><Number>1</Number>'
          '<Series>Berserk</Series><Writer>Kentaro Miura, Studio Gaga</Writer><CoverArtist>Kentaro Miura</CoverArtist>'
          '<Publisher>Dark Horse</Publisher><Genre>Fantasy, Horror</Genre><Count>41</Count>'
          '<Manga>YesAndRightToLeft</Manga><Summary>Guts &amp; Puck</Summary>'
          '<Pages><Page Image="0" ImageWidth="1988" ImageHeight="3056"/><Page Image="1"/></Pages></ComicInfo>');
      expect((i.title, i.number, i.series, i.publisher, i.count), ('The Black Swordsman', '1', 'Berserk', 'Dark Horse', 41));
      expect(i.authors, [('Kentaro Miura', 'writer'), ('Studio Gaga', 'writer'), ('Kentaro Miura', 'cover')]);
      expect(i.genres, ['Fantasy', 'Horror']);
      expect(i.rightToLeft, isTrue);
      expect(i.summary, 'Guts & Puck');
      expect(i.pageSizes, [(1988, 3056), null]);
    });

    test('its date as far as it is given - a year, a month, a day - and nothing for one that makes no sense', () {
      ComicInfo d(String date) => ComicInfo.parse('<ComicInfo>$date</ComicInfo>');
      expect((d('<Year>2016</Year>').released, d('<Year>2016</Year>').precision), (DateTime.utc(2016), DatePrecision.year));
      expect(d('<Year>2016</Year><Month>3</Month>').precision, DatePrecision.month);
      expect(d('<Year>2016</Year><Month>4</Month><Day>9</Day>').released, DateTime.utc(2016, 4, 9));
      expect(d('<Year>2016</Year><Month>13</Month><Day>9</Day>').precision, DatePrecision.year,
          reason: 'month 13: the year only');
      expect(d('<Year>0</Year>').released, isNull);
      expect(d('').precision, isNull);
    });

    test('an escaped "&lt;" written as text stays as written (it was decoded twice, into "<")', () {
      expect(ComicInfo.parse('<ComicInfo><Title>a &amp;lt; b</Title></ComicInfo>').title, 'a &lt; b');
    });
  });

  group('EPUB', () {
    late MemoryFs fs;
    Future<ComicArchive> epub(String manifest, {String meta = '', String title = 'Frankenstein',
        String container = '<container><rootfile full-path="OPS/book.opf"/></container>'}) {
      fs = MemoryFs({
        'b.epub': zipOf({
          'META-INF/container.xml': container,
          'OPS/book.opf': '<package><metadata><dc:title>$title</dc:title><dc:creator>Mary Shelley</dc:creator>'
              '$meta</metadata><manifest>$manifest</manifest></package>',
          'OPS/chapter1.xhtml': 'x' * 50000,
          'OPS/images/a.jpg': [1, 2, 3],
        }),
      });
      return ComicArchive.open(fs, 'b.epub');
    }

    test("its title, author and cover - EPUB 2's meta cover, else a picture named for it, else the first", () async {
      final m = await epubMetadata(await epub('<item id="c" href="images/front%20page.png" media-type="image/png"/>'
          '<item id="i1" href="images/a.jpg" media-type="image/jpeg"/>', meta: '<meta name="cover" content="c"/>'));
      expect(m, (title: 'Frankenstein', author: 'Mary Shelley', cover: 'OPS/images/front page.png'));
      expect((await epubMetadata(await epub('<item id="i1" href="a.jpg" media-type="image/jpeg"/>'
          '<item id="i2" href="cover.jpg" media-type="image/jpeg"/>'))).cover, 'OPS/cover.jpg');
      expect((await epubMetadata(await epub('<item id="i1" href="a.jpg" media-type="image/jpeg"/>'))).cover,
          'OPS/a.jpg');
      final notEpub = await ComicArchive.open(MemoryFs({'x.epub': zipOf({'x': 'y'})}), 'x.epub');
      expect(await epubMetadata(notEpub), (title: null, author: null, cover: null));
    });

    // review, 2026-10-26
    test('read through the archive - the files it needs, not the whole book (an EPUB on a share was read whole)',
        () async {
      final book = await epub('<item id="i1" href="images/a.jpg" media-type="image/jpeg"/>');
      final before = fs.reads;
      await epubMetadata(book);
      expect(fs.reads - before, 2, reason: 'container.xml and the OPF - not the chapters');
    });

    test('a cover path with "../" worked out, a stray "%" kept as written, single-quoted attributes, characters by '
        'number in the title', () async {
      final m = await epubMetadata(await epub(
          "<item id='c' href='../covers/cover 100%.jpg' media-type='image/jpeg'/>",
          title: 'Les Mis&#233;rables',
          container: "<container><rootfile full-path='OPS/book.opf'/></container>"));
      expect(m, (title: 'Les Misérables', author: 'Mary Shelley', cover: 'covers/cover 100%.jpg'));
    });
  });

  group('the review (2026-10-26)', () {
    test('a series whose name starts with a number keeps it: "100 Bullets 001" is 100 Bullets (it came out empty)', () {
      expect(seriesFromName('100 Bullets 001'), '100 Bullets');
      expect(seriesFromName('001 - 100 Bullets 001'), '100 Bullets');
      expect(seriesFromName('2000 AD 2100'), '2000 AD');
      expect(seriesFromName('1602 #1'), '1602');
    });

    test('a share written smb://, // or \\\\ is one library; doubled separators are one; the iPad\'s shared app '
        "group's GUID left out too", () {
      expect(localLibraryId('smb://NAS/Comics'), localLibraryId(r'\\nas\comics'));
      expect(localLibraryId('//nas/comics/'), localLibraryId(r'\\nas\comics'));
      expect(localBookId(r'C:\Comics\\Saga\\1.cbz'), localBookId(r'C:\Comics\Saga\1.cbz'));
      expect(
          localLibraryId('/var/mobile/Containers/Shared/AppGroup/1111-2222/Comics'),
          localLibraryId('/private/var/mobile/Containers/Shared/AppGroup/3333-4444/Comics'));
    });

    test('pages that tie in natural order ("p01", "p1") come out in one order, whichever way they were listed', () {
      expect(comicPages(['p1.jpg', 'p01.jpg']), comicPages(['p01.jpg', 'p1.jpg']));
    });

    test("ComicInfo: a field with attributes or in CDATA; characters by number; 30 February isn't a day; a page's "
        'size at the page its Image says', () {
      final i = ComicInfo.parse('<ComicInfo><Title lang="en">Saga</Title>'
          '<Summary><![CDATA[Alana & Marko <3]]></Summary><Writer>Jos&#233; &#x4C;uis</Writer>'
          '<Year>2016</Year><Month>2</Month><Day>30</Day>'
          '<Pages><Page Image="2" ImageWidth="800" ImageHeight="1200"/></Pages></ComicInfo>');
      expect((i.title, i.summary), ('Saga', 'Alana & Marko <3'));
      expect(i.authors, [('José Luis', 'writer')]);
      expect((i.released, i.precision), (DateTime.utc(2016, 2), DatePrecision.month));
      expect(i.pageSizes, [null, null, (800, 1200)]);
    });
  });
}
