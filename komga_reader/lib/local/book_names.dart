import 'dart:convert';

import 'file_zip.dart' show ComicArchive;

// What a book's file says about it: its ids, its name's number, title and series, the pages in its archive, its
// ComicInfo.xml and an EPUB's own metadata - the rules the local libraries' scan applies, kept free of files and
// state so each can be tried on its own.

// ---- ids --------------------------------------------------------------------------------------------------------------
/// iOS: the app's own folder, /var/mobile/Containers/Data/Application/{GUID}/ - the GUID can change when the app is
/// updated or put back, so a path in it is known by what's after it (its ids too: progress kept).
/// (Its shared app-group folders too, whose GUID changes the same way.)
final iosContainer = RegExp(r'^/(?:private/)?var/mobile/Containers/(?:Data/Application|Shared/AppGroup)/[^/]+/');

/// A path as its ids are made from it: the iOS app folder's GUID left out, a share written \\host\share whichever way
/// it was given (smb://, //), one kind of separator and one at a time, no trailing one, and lower case - the places
/// the books live (Windows, Android's storage and cards, the iPad, an SMB share) don't tell "Batman 1.cbz" from
/// "batman 1.cbz", and the same book reached as \\NICK-NAS or \\nick-nas keeps its progress (user, 2026-10-26).
String normPath(String p) {
  var s = p.trim().replaceFirst(iosContainer, '~/').replaceFirst(RegExp(r'^smb://', caseSensitive: false), '//');
  s = s.replaceAll('/', r'\');
  final share = s.startsWith(r'\\');
  s = s.replaceAll(RegExp(r'\\+'), r'\');
  if (share) s = '\\$s';
  return s.replaceAll(RegExp(r'\\+$'), '').toLowerCase();
}

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
  // its number: after a "#", else the first number standing on its own - not one the name starts with ("100 Bullets
  // 001" is 100 Bullets: review, 2026-10-26 - it came out empty)
  final number = RegExp(r'#\s*-?\d').firstMatch(bare) ??
      RegExp(r'(?:^|\s)(\d{1,4}(?:\.\d+)?)(?=\s|$)').allMatches(bare).where((m) => m.start > 0).firstOrNull;
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
  final c = ra.length.compareTo(rb.length);
  // the same by that ("p01" and "p1"): by the names as written, so the order is always the same
  return c != 0 ? c : a.compareTo(b);
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
    // a field as written - with attributes (<Title lang="en">), or its text in CDATA (review, 2026-10-26: both missed)
    String? field(String name) {
      final m = RegExp('<$name(?:\\s[^>]*)?>(.*?)</$name>', caseSensitive: false, dotAll: true).firstMatch(xml);
      if (m == null) return null;
      final cdata = RegExp(r'^\s*<!\[CDATA\[(.*)\]\]>\s*$', dotAll: true).firstMatch(m[1]!);
      final v = (cdata != null ? cdata[1]! : _unescape(m[1]!)).trim();
      return v.isEmpty ? null : v;
    }

    int? number(String name) => int.tryParse(field(name) ?? '');
    final year = number('Year'), month = number('Month'), day = number('Day');
    final hasMonth = month != null && month >= 1 && month <= 12;
    // a day the month has (30 February isn't 1 March)
    final hasDay = hasMonth && day != null && day >= 1 && DateTime.utc(year ?? 2000, month, day).day == day;
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
      pageSizes: _pageSizes(xml),
    );
  }

  /// Each page's size, at the page its Image attribute says (the next one where there's none) - a list that names
  /// some pages only put their sizes on the first ones (review, 2026-10-26).
  static List<(int, int)?> _pageSizes(String xml) {
    final at = <int, (int, int)?>{};
    var next = 0;
    for (final m in RegExp(r'<Page\b[^>]*>', caseSensitive: false).allMatches(xml)) {
      int? attr(String name) => int.tryParse(RegExp('\\b$name\\s*=\\s*["\'](\\d+)["\']').firstMatch(m[0]!)?[1] ?? '');
      final i = attr('Image') ?? next;
      next = i + 1;
      final w = attr('ImageWidth'), h = attr('ImageHeight');
      at[i] = w != null && h != null && w > 0 && h > 0 ? (w, h) : null;
    }
    if (at.isEmpty) return const [];
    final last = at.keys.reduce((a, b) => a > b ? a : b);
    return [for (var i = 0; i <= last; i++) at[i]];
  }
}

String _unescape(String s) => s
    // characters by number (&#233; &#xE9;) - before "&amp;": "&amp;#233;" is the text "&#233;"
    .replaceAllMapped(RegExp(r'&#(x[0-9a-fA-F]+|\d+);'), (m) {
      final n = m[1]!.startsWith('x') ? int.tryParse(m[1]!.substring(1), radix: 16) : int.tryParse(m[1]!);
      return n == null || n > 0x10ffff ? m[0]! : String.fromCharCode(n);
    })
    .replaceAll('&lt;', '<')
    .replaceAll('&gt;', '>')
    .replaceAll('&quot;', '"')
    .replaceAll('&#39;', "'")
    .replaceAll('&apos;', "'")
    .replaceAll('&amp;', '&'); // (last: "&amp;lt;" is "&lt;", not "<")

// ---- EPUB ------------------------------------------------------------------------------------------------------------
/// An EPUB's title, author and cover (its OPF), as far as they can be read; nulls otherwise. Read through [book]'s
/// archive - the few files it needs, not the whole book (review, 2026-10-26: an EPUB on a share was read whole for
/// this).
Future<({String? title, String? author, String? cover})> epubMetadata(ComicArchive book) async {
  const none = (title: null, author: null, cover: null);
  try {
    Future<String?> text(String name) async {
      final entry = book.find(name);
      final bytes = entry == null ? null : await book.read(entry);
      return bytes == null ? null : utf8.decode(bytes, allowMalformed: true);
    }

    String? attr(String tag, String name) =>
        RegExp('\\b$name\\s*=\\s*(?:"([^"]*)"|\'([^\']*)\')', caseSensitive: false).firstMatch(tag)?.let((m) =>
            m[1] ?? m[2]);

    final container = await text('META-INF/container.xml');
    final rootfile = container == null ? null : RegExp(r'<rootfile\b[^>]*>', caseSensitive: false).firstMatch(container);
    final opfPath = rootfile == null ? null : attr(rootfile[0]!, 'full-path');
    if (opfPath == null) return none;
    final opf = await text(opfPath);
    if (opf == null) return none;
    String? tag(String name) {
      final m = RegExp('<(?:dc:)?$name\\b[^>]*>(.*?)</(?:dc:)?$name>', caseSensitive: false, dotAll: true)
          .firstMatch(opf);
      final t = m == null ? null : _unescape(m[1]!.replaceAll(RegExp(r'<[^>]*>'), '')).trim();
      return t == null || t.isEmpty ? null : t;
    }

    final dir = opfPath.contains('/') ? opfPath.substring(0, opfPath.lastIndexOf('/') + 1) : '';
    // the manifest's pictures: (id, href, properties)
    final images = [
      for (final m in RegExp(r'<item\b[^>]*>', caseSensitive: false).allMatches(opf))
        if ((attr(m[0]!, 'media-type') ?? '').startsWith('image/'))
          (attr(m[0]!, 'id') ?? '', attr(m[0]!, 'href') ?? '', attr(m[0]!, 'properties') ?? ''),
    ];
    String? coverId;
    for (final m in RegExp(r'<meta\b[^>]*>', caseSensitive: false).allMatches(opf)) {
      if (attr(m[0]!, 'name') == 'cover') coverId = attr(m[0]!, 'content');
    }
    // EPUB 3's cover-image; EPUB 2's meta cover; then what publishers name it ("cover", Penguin Random House's
    // "...cvi..." - cover image); then the first picture
    final href = [
      for (final i in images) if (i.$3.contains('cover-image')) i.$2,
      for (final i in images) if (coverId != null && i.$1 == coverId) i.$2,
      for (final i in images) if ('${i.$1} ${i.$2}'.toLowerCase().contains('cover')) i.$2,
      for (final i in images) if (RegExp(r'[_-]cvi[_.-]').hasMatch(i.$2.toLowerCase())) i.$2,
      for (final i in images) i.$2,
    ].where((h) => h.isNotEmpty).firstOrNull;
    return (title: tag('title'), author: tag('creator'), cover: href == null ? null : _resolve(dir, href));
  } catch (_) {
    return none;
  }
}

/// [href] (written in the OPF, relative to its folder [dir]) as a path in the book: %-escapes decoded where they're
/// whole ("cover 100%.jpg" kept as it is), "../" and "./" worked out.
String _resolve(String dir, String href) {
  String decoded;
  try {
    decoded = Uri.decodeFull(href);
  } catch (_) {
    decoded = href;
  }
  final out = <String>[];
  for (final part in '$dir$decoded'.split('/')) {
    if (part == '..') {
      if (out.isNotEmpty) out.removeLast();
    } else if (part != '.' && part.isNotEmpty) {
      out.add(part);
    }
  }
  return out.join('/');
}

extension<T> on T {
  R let<R>(R Function(T it) f) => f(this);
}
