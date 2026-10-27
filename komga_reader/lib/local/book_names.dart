import 'dart:convert';

import '../epub/source.dart' show Zip;

// What a book's file says about it: its ids, its name's number, title and series, the pages in its archive, its
// ComicInfo.xml and an EPUB's own metadata - the rules the local libraries' scan applies, kept free of files and
// state so each can be tried on its own.

// ---- ids --------------------------------------------------------------------------------------------------------------
/// iOS: the app's own folder, /var/mobile/Containers/Data/Application/{GUID}/ - the GUID can change when the app is
/// updated or put back, so a path in it is known by what's after it (its ids too: progress kept).
final iosContainer = RegExp(r'^/(?:private/)?var/mobile/Containers/Data/Application/[^/]+/');

/// A path as its ids are made from it: the iOS app folder's GUID left out, one kind of separator, no trailing one, and
/// lower case - the places the books live (Windows, Android's storage and cards, the iPad, an SMB share) don't tell
/// "Batman 1.cbz" from "batman 1.cbz", and the same book reached as \\NICK-NAS or \\nick-nas keeps its progress (user,
/// 2026-10-26).
String normPath(String p) =>
    p.trim().replaceFirst(iosContainer, '~/').replaceAll('/', r'\').replaceAll(RegExp(r'\\+$'), '').toLowerCase();

/// A short id that stays the same for the same text (FNV-1a, 64 bits, unsigned, base 36, 13 characters): books,
/// series and libraries keep their ids - and so their reading progress - from one scan to the next. (The experiment's
/// came out signed: about half began with a minus.)
String stableId(String text) {
  var h = 0xcbf29ce484222325;
  for (final c in utf8.encode(text)) {
    h ^= c;
    h *= 0x100000001b3;
  }
  return BigInt.from(h).toUnsigned(64).toRadixString(36).padLeft(13, '0');
}

/// A local library's id (from its folder), a series' (its folder, or a one-shot's file), a book's (its file) and a
/// read-list library's read list (its folder). They start with a lower-case 'l' and their kind - Komga's ids are
/// capitals and digits only, so the two are never mixed up, whatever the hash comes out as.
String localLibraryId(String folder) => 'll${stableId(normPath(folder))}';
String localSeriesId(String pathOf) => 'ls${stableId(normPath(pathOf))}';
String localBookId(String file) => 'lb${stableId(normPath(file))}';
String localReadListId(String folder) => 'lr${stableId(normPath(folder))}';

/// Whether [id] is a local library's, series', book's or read list's - told by its form alone, even once its library
/// is gone (a pin to it, say).
bool isLocalId(String? id) => id != null && id.length > 2 && id.startsWith('l') && 'lsbr'.contains(id[1]);

// ---- names ------------------------------------------------------------------------------------------------------------
/// A read list's file name starts with its place in the list: "001 - Green Lantern 021" - not the issue.
final _readingOrder = RegExp(r'^\s*\d{1,4}\s*-\s+');

/// A book's series from its file name, where the folder doesn't say (a read list's books): the name up to its issue
/// number - after a "#", else the first number standing on its own - without a reading order at the start ("001 - ")
/// or a "Vol." / "v" just before the number; a name with no number is the whole name (a book of its own).
/// "002 - Green Lantern 021(2007)(Digital)" is Green Lantern, "Fables (2002) Vol. 22 - Farewell" is Fables.
String seriesFromName(String stem) {
  final bare = stem
      .replaceAll(RegExp(r'\([^)]*\)|\[[^\]]*\]'), ' ')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim()
      .replaceFirst(_readingOrder, '');
  final hash = RegExp(r'#\s*-?\d').firstMatch(bare);
  final number = hash ?? RegExp(r'(?:^|\s)(\d{1,4}(?:\.\d+)?)(?=\s|$)').firstMatch(bare);
  final s = (number == null ? bare : bare.substring(0, number.start)).replaceAll(RegExp(r'^[\s\-_:,]+|[\s\-_:,]+$'), '');
  return s.replaceFirst(RegExp(r'\s+(vol\.?|volume|v)$', caseSensitive: false), '').replaceAll(RegExp(r'[\s\-_:,]+$'), '');
}

/// One series' books' names without the start they all share (user, 2026-10-26: "Green Lantern Mosaic 012 (1993)" in
/// a folder of Green Lantern Mosaic issues is "012 (1993)"): cut after the last " - " or ": " in the shared start
/// ("Batman - Year One 01 - Who I Am" is "Year One 01 - Who I Am"), else after its last space.
/// Null: fewer than two books, nothing shared up to a break, or a name that would be left empty.
List<String>? withoutSharedStart(List<String> names) {
  if (names.length < 2) return null;
  var n = names.first.length;
  for (final s in names.skip(1)) {
    var i = 0;
    while (i < n && i < s.length && s[i].toLowerCase() == names.first[i].toLowerCase()) {
      i++;
    }
    n = i;
  }
  final shared = names.first.substring(0, n);
  final separators = RegExp(r'\s[-–—]\s|:\s').allMatches(shared).toList();
  final cut = separators.isNotEmpty ? separators.last.end : shared.lastIndexOf(RegExp(r'\s')) + 1;
  if (cut <= 0) return null;
  final out = [for (final s in names) s.substring(cut).trim()];
  return out.any((s) => s.isEmpty) ? null : out;
}

/// What a file name says about its book: its issue number, a title after it, a year.
/// "Absolute Batman 010 (2025) (Digital) (Shan-Empire)" in "Absolute Batman (2024)": 10, no title, 2025;
/// "Spider-Island - Cloak & Dagger (2011) #001": 1; "Dune 01 - Dune Messiah" in "Dune": 1, "Dune Messiah".
({double? number, String? title, int? year}) parseBookName(String stem, String seriesName) {
  int? year;
  for (final m in RegExp(r'\((\d{4})\)').allMatches(stem)) {
    year ??= int.tryParse(m[1]!);
  }
  final bare = stem.replaceAll(RegExp(r'\([^)]*\)|\[[^\]]*\]'), ' ').replaceAll(RegExp(r'\s+'), ' ').trim();
  final seriesBare = seriesName.replaceAll(RegExp(r'\([^)]*\)'), ' ').replaceAll(RegExp(r'\s+'), ' ').trim();
  final hash = RegExp(r'#\s*(-?\d+(?:\.\d+)?)').firstMatch(stem);
  double? number;
  String? title;
  if (hash != null) {
    number = double.tryParse(hash[1]!);
  } else {
    // the part after the series' own name (so "Spider-Man 2099" isn't taken for issue 2099), else the whole name
    final rest = seriesBare.isNotEmpty && bare.toLowerCase().startsWith(seriesBare.toLowerCase())
        ? bare.substring(seriesBare.length)
        : bare;
    final m = RegExp(r'(?:^|\s)(\d{1,4}(?:\.\d+)?)(?=\s|$)').firstMatch(rest);
    if (m != null) {
      number = double.tryParse(m[1]!);
      final after = rest.substring(m.end).replaceFirst(RegExp(r'^\s*[-:]\s*'), '').trim();
      if (after.isNotEmpty) title = after;
    }
  }
  return (number: number, title: title, year: year);
}

/// Natural order ("page 2" before "page 10"), as Komga sorts files.
int naturalCompare(String a, String b) {
  final ra = RegExp(r'\d+|\D+').allMatches(a.toLowerCase()).map((m) => m[0]!).toList();
  final rb = RegExp(r'\d+|\D+').allMatches(b.toLowerCase()).map((m) => m[0]!).toList();
  for (var i = 0; i < ra.length && i < rb.length; i++) {
    final x = ra[i], y = rb[i];
    final nx = int.tryParse(x), ny = int.tryParse(y);
    final c = nx != null && ny != null ? nx.compareTo(ny) : x.compareTo(y);
    if (c != 0) return c;
  }
  return ra.length.compareTo(rb.length);
}

// ---- pages -----------------------------------------------------------------------------------------------------------
const _imageTypes = {
  '.jpg': 'image/jpeg', '.jpeg': 'image/jpeg', '.png': 'image/png', '.webp': 'image/webp', '.gif': 'image/gif',
  '.avif': 'image/avif', '.jxl': 'image/jxl',
};

String _ext(String name) {
  final i = name.lastIndexOf('.');
  return i < 0 ? '' : name.substring(i).toLowerCase();
}

String _base(String path) => path.split(RegExp(r'[\\/]')).last;

/// The image entries of a comic archive, in reading order (natural order of their names) - not a Mac's resource forks
/// (__MACOSX/, ._x) or other hidden files.
List<String> comicPages(Iterable<String> names) => [
      for (final n in names)
        if (_imageTypes.containsKey(_ext(n)) && !n.endsWith('/') && !n.startsWith('__MACOSX') && !_base(n).startsWith('.'))
          n,
    ]..sort(naturalCompare);

/// A page's media type, from its name.
String imageType(String name) => _imageTypes[_ext(name)] ?? 'image/jpeg';

// ---- ComicInfo.xml ---------------------------------------------------------------------------------------------------
/// How much of a release date is known: a year alone isn't shown as "1 January".
enum DatePrecision { year, month, day }

/// A comic's ComicInfo.xml (its own metadata, as Komga reads it): the fields kept.
class ComicInfo {
  const ComicInfo({this.title, this.series, this.number, this.summary, this.released, this.precision,
      this.authors = const [], this.publisher, this.genres = const [], this.count, this.rightToLeft = false,
      this.pageSizes = const []});

  final String? title, series, number, summary, publisher;

  /// The release date as far as it's known ([precision]: the rest is 1, for sorting).
  final DateTime? released;
  final DatePrecision? precision;

  /// (name, Komga's role: writer, penciller, inker, colorist, letterer, cover, editor).
  final List<(String, String)> authors;
  final List<String> genres;

  /// How many books the series has.
  final int? count;

  /// Manga read right to left.
  final bool rightToLeft;

  /// Each page's (width, height), in the archive's page order, where it's given (null for a page it isn't).
  final List<(int, int)?> pageSizes;

  static const _roles = {
    'Writer': 'writer', 'Penciller': 'penciller', 'Inker': 'inker', 'Colorist': 'colorist', 'Letterer': 'letterer',
    'CoverArtist': 'cover', 'Editor': 'editor',
  };

  factory ComicInfo.parse(String xml) {
    String? field(String name) {
      final m = RegExp('<$name>([^<]*)</$name>', caseSensitive: false).firstMatch(xml);
      final v = m == null ? null : _unescape(m[1]!).trim();
      return v == null || v.isEmpty ? null : v;
    }

    int? number(String name) => int.tryParse(field(name) ?? '');
    final year = number('Year'), month = number('Month'), day = number('Day');
    final hasMonth = month != null && month >= 1 && month <= 12;
    final hasDay = hasMonth && day != null && day >= 1 && day <= 31;
    return ComicInfo(
      title: field('Title'), series: field('Series'), number: field('Number'), summary: field('Summary'),
      released: year != null && year > 0 ? DateTime.utc(year, hasMonth ? month : 1, hasDay ? day : 1) : null,
      precision: year == null || year <= 0
          ? null
          : !hasMonth
              ? DatePrecision.year
              : !hasDay
                  ? DatePrecision.month
                  : DatePrecision.day,
      authors: [
        for (final MapEntry(key: tag, value: role) in _roles.entries)
          for (final name in (field(tag) ?? '').split(','))
            if (name.trim().isNotEmpty) (name.trim(), role),
      ],
      publisher: field('Publisher'),
      genres: [for (final g in (field('Genre') ?? '').split(',')) if (g.trim().isNotEmpty) g.trim()],
      count: number('Count'),
      rightToLeft: field('Manga')?.toLowerCase() == 'yesandrighttoleft',
      pageSizes: [
        for (final m in RegExp(r'<Page\b[^>]*>', caseSensitive: false).allMatches(xml))
          () {
            final w = int.tryParse(RegExp(r'ImageWidth="(\d+)"').firstMatch(m[0]!)?[1] ?? '');
            final h = int.tryParse(RegExp(r'ImageHeight="(\d+)"').firstMatch(m[0]!)?[1] ?? '');
            return w != null && h != null && w > 0 && h > 0 ? (w, h) : null;
          }(),
      ],
    );
  }
}

String _unescape(String s) => s
    .replaceAll('&lt;', '<')
    .replaceAll('&gt;', '>')
    .replaceAll('&quot;', '"')
    .replaceAll('&#39;', "'")
    .replaceAll('&apos;', "'")
    .replaceAll('&amp;', '&'); // (last: "&amp;lt;" is "&lt;", not "<")

// ---- EPUB ------------------------------------------------------------------------------------------------------------
/// An EPUB's title, author and cover (its OPF), as far as they can be read; nulls otherwise.
({String? title, String? author, String? cover}) epubMetadata(Zip z) {
  try {
    final container = utf8.decode(z.read('META-INF/container.xml') ?? const [], allowMalformed: true);
    final opfPath = RegExp(r'full-path="([^"]+)"').firstMatch(container)?[1];
    if (opfPath == null) return (title: null, author: null, cover: null);
    final opf = utf8.decode(z.read(opfPath) ?? const [], allowMalformed: true);
    String? tag(String name) {
      final m = RegExp('<(?:dc:)?$name[^>]*>([^<]*)</(?:dc:)?$name>', caseSensitive: false).firstMatch(opf);
      final t = m?[1]?.trim();
      return t == null || t.isEmpty ? null : _unescape(t);
    }

    final dir = opfPath.contains('/') ? opfPath.substring(0, opfPath.lastIndexOf('/') + 1) : '';
    // the manifest's pictures: (id, href, properties)
    final images = [
      for (final m in RegExp(r'<item\b[^>]*>', caseSensitive: false).allMatches(opf))
        if (RegExp(r'media-type="image/').hasMatch(m[0]!))
          (
            RegExp(r'\bid="([^"]*)"').firstMatch(m[0]!)?[1] ?? '',
            RegExp(r'href="([^"]+)"').firstMatch(m[0]!)?[1] ?? '',
            RegExp(r'properties="([^"]*)"').firstMatch(m[0]!)?[1] ?? '',
          ),
    ];
    final coverId = RegExp(r'<meta[^>]*name="cover"[^>]*content="([^"]+)"').firstMatch(opf)?[1] ??
        RegExp(r'<meta[^>]*content="([^"]+)"[^>]*name="cover"').firstMatch(opf)?[1];
    // EPUB 3's cover-image; EPUB 2's meta cover; then what publishers name it ("cover", Penguin Random House's
    // "...cvi..." - cover image); then the first picture
    final href = [
      for (final i in images) if (i.$3.contains('cover-image')) i.$2,
      for (final i in images) if (coverId != null && i.$1 == coverId) i.$2,
      for (final i in images) if ('${i.$1} ${i.$2}'.toLowerCase().contains('cover')) i.$2,
      for (final i in images) if (RegExp(r'[_-]cvi[_.-]').hasMatch(i.$2.toLowerCase())) i.$2,
      for (final i in images) i.$2,
    ].where((h) => h.isNotEmpty).firstOrNull;
    return (title: tag('title'), author: tag('creator'), cover: href == null ? null : Uri.decodeFull('$dir$href'));
  } catch (_) {
    return (title: null, author: null, cover: null);
  }
}
