import 'dart:convert';
import 'dart:io';

import 'package:dart_smb2/dart_smb2.dart';

import '../epub/source.dart' show Zip;
import 'file_zip.dart';
import 'storage.dart';

/// A local library: a folder on this device (or a share it can reach), one folder per series inside it.
class LocalLibrary {
  const LocalLibrary(this.name, this.path);
  final String name;
  final String path;

  /// Stable for the folder: progress kept under it survives a rescan or a restart.
  String get id => 'L${stableId(_normPath(path))}';

  Map<String, dynamic> toJson() => {'name': name, 'path': path};
  factory LocalLibrary.fromJson(Map<String, dynamic> j) => LocalLibrary(j['name'] as String, j['path'] as String);

  /// A library for [path], named after its folder.
  factory LocalLibrary.at(String path) {
    final clean = path.trim().replaceAll(RegExp(r'[\\/]+$'), '');
    return LocalLibrary(clean.split(RegExp(r'[\\/]')).last, clean);
  }
}

String _normPath(String p) => p.trim().replaceAll('/', r'\').replaceAll(RegExp(r'\\+$'), '').toLowerCase();

/// A short id that stays the same for the same text (FNV-1a, 64 bits): books, series and libraries keep their ids
/// - and so their reading progress - from one scan to the next.
String stableId(String text) {
  var h = 0xcbf29ce484222325;
  for (final c in utf8.encode(text)) {
    h ^= c;
    h *= 0x100000001b3;
  }
  return h.toUnsigned(64).toRadixString(36);
}

const _comicExt = {'.cbz'};
const _bookExt = {'.epub'};
const _imageTypes = {
  '.jpg': 'image/jpeg', '.jpeg': 'image/jpeg', '.png': 'image/png', '.webp': 'image/webp', '.gif': 'image/gif',
  '.avif': 'image/avif', '.jxl': 'image/jxl',
};

/// Folders whose files are each a series of their own (Komga's convention, as on the NAS's E-Books\_oneshots).
const oneshotFolders = {'_oneshots'};

String _ext(String name) {
  final i = name.lastIndexOf('.');
  return i < 0 ? '' : name.substring(i).toLowerCase();
}

String _base(String path) => path.split(RegExp(r'[\\/]')).last;
String _stem(String path) {
  final b = _base(path);
  final i = b.lastIndexOf('.');
  return i <= 0 ? b : b.substring(0, i);
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

String _numberText(double n) => n == n.roundToDouble() ? '${n.toInt()}' : '$n';

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

String _unescape(String s) => s
    .replaceAll('&amp;', '&')
    .replaceAll('&lt;', '<')
    .replaceAll('&gt;', '>')
    .replaceAll('&quot;', '"')
    .replaceAll('&#39;', "'")
    .replaceAll('&apos;', "'");

/// The image entries of a comic archive, in reading order (natural order of their names).
List<String> comicPages(Iterable<String> names) => [
      for (final n in names)
        if (_imageTypes.containsKey(_ext(n)) && !n.endsWith('/') && !n.startsWith('__MACOSX') && !_base(n).startsWith('.'))
          n,
    ]..sort(naturalCompare);

String imageType(String name) => _imageTypes[_ext(name)] ?? 'image/jpeg';

/// Scans [libraries]: bookId -> an entry shaped as a download's (lib/offline/store.dart) - the book and its series
/// as Komga would give them, the library, the pages (zip entry names) - plus 'path', the book's file. A library folder
/// that can't be read is left out (its books just don't show). [known]: the last scan's entries by file path - a file
/// unchanged since isn't opened again. [onBook]: told the count of books done so far, as the scan goes.
Future<Map<String, Map<String, dynamic>>> scanLibraries(List<LocalLibrary> libraries,
    {Map<String, Map<String, dynamic>> known = const {}, void Function(int books)? onBook,
    void Function(LocalLibrary library, Object? error, {bool missing})? onUnreadable,
    void Function(LocalLibrary library, String path, FileTrouble trouble, Object error)? onFile}) async {
  final out = <String, Map<String, dynamic>>{};
  var done = 0;
  for (final lib in libraries) {
    final fs = Storage.instance.of(lib.path); // this device's files, or a share through the app's SMB client
    // [onUnreadable] told of a library that couldn't be read through - out of reach, refused, cut off part-way, or
    // [missing]: not there while the place it was in answers (it looks deleted - the user is asked). Its books
    // aren't known this time, which isn't "it has none".
    try {
      if (!await fs.exists(lib.path)) {
        onUnreadable?.call(lib, null, missing: await fs.placeAnswers(lib.path).catchError((Object _) => false));
        continue;
      }
    } catch (e) {
      onUnreadable?.call(lib, e, missing: false);
      continue;
    }
    final rootPath = lib.path.replaceAll(RegExp(r'[\\/]+$'), '');
    // series: each folder with books in it; a _oneshots folder's books and books loose in the library each their own
    final groups = <(String, bool), List<FsEntry>>{}; // (series folder or file, oneshot) -> its books
    try {
      await for (final e in fs.list(lib.path)) {
        final ext = _ext(e.path);
        if (!_comicExt.contains(ext) && !_bookExt.contains(ext)) continue;
        final parent = e.path.substring(0, e.path.lastIndexOf(RegExp(r'[\\/]'))).replaceAll(RegExp(r'[\\/]+$'), '');
        final oneshot = parent.toLowerCase() == rootPath.toLowerCase() ||
            oneshotFolders.contains(_base(parent).toLowerCase());
        groups.putIfAbsent(oneshot ? (e.path, true) : (parent, false), () => []).add(e);
      }
    } catch (e) {
      onUnreadable?.call(lib, e, missing: false); // the folder couldn't be read through (a share dropping part-way)
      continue;
    }
    // the books read several at a time: on a network share, opening each file is mostly waiting for the network
    final made = <String, Map<String, dynamic>>{}; // file path -> its entry
    final jobs = [
      for (final MapEntry(key: (where, oneshot), value: files) in groups.entries)
        for (final (i, f) in (files..sort((a, b) => naturalCompare(_base(a.path), _base(b.path)))).indexed)
          (f, i, where, oneshot),
    ];
    await _inParallel(jobs, 8, (j) async {
      final (f, i, where, oneshot) = j;
      try {
        made[f.path] = await _bookEntry(fs, f, i, 'S${stableId(_normPath(where))}',
            oneshot ? _stem(where) : _base(where), lib, oneshot, known);
      } catch (e) {
        // a damaged file, or one gone since the listing: left out. The share not answering (it stopped part-way, a
        // timeout): what the last scan had of it is kept, as for a library out of reach (user, 2026-10-25: a share
        // dropping mid-scan lost every book after it)
        final trouble = troubleOf(e);
        if (trouble == FileTrouble.noAnswer) {
          if (known[f.path] case final was?) made[f.path] = was;
        }
        onFile?.call(lib, f.path, trouble, e);
      }
      onBook?.call(++done);
    });
    for (final MapEntry(key: (where, oneshot), value: files) in groups.entries) {
      final seriesName = oneshot ? _stem(where) : _base(where);
      final seriesId = 'S${stableId(_normPath(where))}';
      final books = [for (final f in files) if (made[f.path] case final b?) b];
      if (books.isEmpty) continue;
      final dates = [for (final b in books) (b['book']['metadata'] as Map)['releaseDate'] as String?]
          .whereType<String>()
          .toList()
        ..sort();
      final authors = {
        for (final b in books)
          for (final a in ((b['book']['metadata'] as Map)['authors'] as List)) '${a['name']}|${a['role']}': a,
      }.values.toList();
      final created = [for (final b in books) b['book']['created'] as String]..sort();
      // the series' own metadata from its books' ComicInfo.xml (the latest book's, where they differ)
      final infos = [for (final b in books.reversed) if ((b['inside'] as Map)['info'] case final Map i) i];
      T? first<T>(String key) => infos.map((i) => i[key]).whereType<T>().firstOrNull;
      final genres = {for (final i in infos) ...((i['genres'] as List?) ?? const []).cast<String>()}.toList();
      final series = <String, dynamic>{
        'id': seriesId, 'libraryId': lib.id, 'name': seriesName, 'url': where,
        'created': created.first, 'lastModified': created.last, 'fileLastModified': created.last,
        'booksCount': books.length, 'booksReadCount': 0, 'booksUnreadCount': books.length, 'booksInProgressCount': 0,
        'metadata': {
          'status': 'ONGOING', 'title': seriesName, 'titleSort': seriesName, 'summary': '',
          'readingDirection': first<bool>('rightToLeft') == true ? 'RIGHT_TO_LEFT' : '',
          'publisher': first<String>('publisher') ?? '', 'ageRating': null, 'language': '', 'genres': genres,
          'tags': <String>[], 'totalBookCount': first<int>('count'), 'links': <dynamic>[],
          'alternateTitles': <dynamic>[],
        },
        'booksMetadata': {'authors': authors, 'tags': <String>[], 'releaseDate': dates.firstOrNull, 'summary': ''},
        'deleted': false, 'oneshot': oneshot,
      };
      for (final b in books) {
        b['series'] = series;
        out[b['book']['id'] as String] = b;
      }
    }
  }
  return out;
}

Future<Map<String, dynamic>> _bookEntry(LibraryFs fs, FsEntry f, int index, String seriesId, String seriesName, LocalLibrary lib,
    bool oneshot, Map<String, Map<String, dynamic>> known) async {
  final stem = _stem(f.path);
  final epub = _bookExt.contains(_ext(f.path));
  final parsed = parseBookName(stem, oneshot ? '' : seriesName);
  final number = oneshot ? 1.0 : (parsed.number ?? index + 1.0);
  // its own title: what follows the number, else the name without its tags ("(2025) (Digital) (Shan-Empire)")
  final untagged = stem.replaceAll(RegExp(r'\([^)]*\)|\[[^\]]*\]'), ' ').replaceAll(RegExp(r'\s+'), ' ').trim();
  var title = oneshot ? stem : (parsed.title ?? (untagged.isEmpty ? stem : untagged));
  final modified = f.modified.toIso8601String();
  // what's read from inside the file (its pages, an EPUB's title, author and cover): kept from the last scan if the
  // file hasn't changed since - only new and changed files are opened
  final was = known[f.path];
  final reuse = was != null && was['fileModified'] == modified && was['bytes'] == f.size && was['inside'] is Map &&
      (was['inside'] as Map)['v'] == _insideVersion;
  final inside = reuse ? (was['inside'] as Map).cast<String, dynamic>() : await _readInside(fs, f.path, epub);
  final pages = [for (final p in (inside['pages'] as List)) (p as Map).cast<String, dynamic>()];
  if (!epub && pages.isEmpty) throw const FormatException('no pages');
  if (inside['title'] is String) title = inside['title'] as String;
  final authors = <Map<String, dynamic>>[
    if (inside['author'] is String) {'name': inside['author'], 'role': 'writer'},
  ];
  // a comic's ComicInfo.xml, where it has one: its own title, number, date, people and summary over the file name's
  final info = (inside['info'] as Map?)?.cast<String, dynamic>();
  if (info?['title'] case final String t) title = t;
  if (info?['authors'] case final List a) authors.addAll([for (final x in a) (x as Map).cast<String, dynamic>()]);
  final infoNumber = double.tryParse('${info?['number'] ?? ''}');
  final shownNumber = info?['number'] is String && !oneshot ? info!['number'] as String : _numberText(number);
  final sortNumber = infoNumber != null && !oneshot ? infoNumber : number;
  final releaseDate = info?['releaseDate'] as String? ?? (parsed.year == null ? null : '${parsed.year}-01-01');
  final cover = inside['cover'] as String?;
  final book = <String, dynamic>{
    'id': 'B${stableId(_normPath(f.path))}', 'seriesId': seriesId, 'seriesTitle': seriesName, 'libraryId': lib.id,
    'name': stem, 'url': f.path, 'number': index + 1, 'created': modified, 'lastModified': modified,
    'fileLastModified': modified, 'sizeBytes': f.size, 'size': '${(f.size / 1048576).toStringAsFixed(1)} MiB',
    'media': {
      'status': 'READY', 'mediaType': epub ? 'application/epub+zip' : 'application/zip',
      // an EPUB: progress as a share of the book, out of 100 (Komga counts its positions)
      'pagesCount': epub ? 100 : pages.length, 'comment': '', 'mediaProfile': epub ? 'EPUB' : 'DIVINA',
    },
    'metadata': {
      'title': title, 'summary': info?['summary'] ?? '', 'number': shownNumber, 'numberSort': sortNumber,
      'releaseDate': releaseDate, 'authors': authors, 'tags': <String>[],
      'isbn': '', 'links': <dynamic>[],
    },
    'readProgress': null, 'deleted': false, 'oneshot': oneshot,
  };
  return {
    'book': book, 'library': {'id': lib.id, 'name': lib.name}, 'readLists': <dynamic>[], 'collections': <dynamic>[],
    'pages': pages, 'state': 'done', 'path': f.path, 'bytes': f.size, if (cover != null) 'cover': cover,
    if (epub) 'epub': true, 'fileModified': modified, 'inside': inside,
  };
}

/// Why the scan couldn't use a file. [noAnswer]: the share or the network didn't answer - not the file's doing: its
/// book is kept from the last scan. [damaged] (not a zip, a broken one, a format not read yet) and [gone] (deleted
/// since the folder was listed): left out - not in the app after that scan; the file untouched, its progress kept.
enum FileTrouble { noAnswer, damaged, gone }

FileTrouble troubleOf(Object e) => switch (e) {
      FormatException() || RangeError() || ArgumentError() => FileTrouble.damaged,
      Smb2Exception(:final type) when type == Smb2ErrorType.notFound || type == Smb2ErrorType.isADirectory =>
        FileTrouble.gone,
      // ERROR_FILE_NOT_FOUND / ENOENT (2), ERROR_PATH_NOT_FOUND (3) - not a share out of reach (Windows: 53, 64, 67)
      FileSystemException(:final osError) when osError?.errorCode == 2 || osError?.errorCode == 3 => FileTrouble.gone,
      _ => FileTrouble.noAnswer,
    };

/// Runs [f] on each of [items], [n] at a time.
Future<void> _inParallel<T>(List<T> items, int n, Future<void> Function(T item) f) async {
  var next = 0;
  Future<void> worker() async {
    while (next < items.length) {
      await f(items[next++]);
    }
  }

  await Future.wait([for (var k = 0; k < n; k++) worker()]);
}

/// What's kept from inside a file: read again when this changes (a scan from an older version had less in it).
const _insideVersion = 2;

/// Opens the book: a comic's pages (its pictures, in order - their sizes too where its ComicInfo.xml gives them) and
/// its ComicInfo.xml; an EPUB's own title, author and cover.
Future<Map<String, dynamic>> _readInside(LibraryFs fs, String path, bool epub) async {
  if (epub) {
    final meta = epubMetadata(Zip(await fs.readAll(path)));
    return {'v': _insideVersion, 'pages': const [], 'title': meta.title, 'author': meta.author, 'cover': meta.cover};
  }
  final zip = await FileZip.open(fs, path);
  final names = comicPages(zip.names);
  final infoName = zip.find('ComicInfo.xml');
  final info = infoName == null ? null : comicInfo(utf8.decode(await zip.read(infoName) ?? const [], allowMalformed: true));
  final sizes = (info?['pageSizes'] as List?) ?? const [];
  return {
    'v': _insideVersion,
    'pages': [
      for (final (i, n) in names.indexed)
        {
          'number': i + 1, 'file': n, 'mediaType': imageType(n),
          // (ComicInfo lists a page for each picture, in the same order, when it's whole)
          if (sizes.length == names.length && sizes[i] != null) 'width': sizes[i][0],
          if (sizes.length == names.length && sizes[i] != null) 'height': sizes[i][1],
        },
    ],
    'cover': names.firstOrNull,
    if (info != null) 'info': info..remove('pageSizes'),
  };
}

/// A ComicInfo.xml (the comic's own metadata, as Komga reads it): the fields kept - title, number, summary, the
/// release date, who made it, publisher, genres, the series' book count, manga read right to left, and each page's size.
Map<String, dynamic> comicInfo(String xml) {
  String? field(String name) {
    final m = RegExp('<$name>([^<]*)</$name>', caseSensitive: false).firstMatch(xml);
    final v = m == null ? null : _unescape(m[1]!).trim();
    return v == null || v.isEmpty ? null : v;
  }

  int? number(String name) => int.tryParse(field(name) ?? '');
  // the people: Komga's roles, from ComicInfo's fields (comma-separated names)
  const roles = {
    'Writer': 'writer', 'Penciller': 'penciller', 'Inker': 'inker', 'Colorist': 'colorist', 'Letterer': 'letterer',
    'CoverArtist': 'cover', 'Editor': 'editor',
  };
  final authors = [
    for (final MapEntry(key: tag, value: role) in roles.entries)
      for (final name in (field(tag) ?? '').split(','))
        if (name.trim().isNotEmpty) {'name': name.trim(), 'role': role},
  ];
  final year = number('Year'), month = number('Month'), day = number('Day');
  String two(int v) => '$v'.padLeft(2, '0');
  final pageSizes = [
    for (final m in RegExp(r'<Page\b[^>]*>', caseSensitive: false).allMatches(xml))
      () {
        final w = int.tryParse(RegExp(r'ImageWidth="(\d+)"').firstMatch(m[0]!)?[1] ?? '');
        final h = int.tryParse(RegExp(r'ImageHeight="(\d+)"').firstMatch(m[0]!)?[1] ?? '');
        return w != null && h != null && w > 0 && h > 0 ? [w, h] : null;
      }(),
  ];
  final manga = field('Manga')?.toLowerCase();
  return {
    'title': field('Title'), 'number': field('Number'), 'summary': field('Summary'),
    if (year != null && year > 0)
      'releaseDate': '$year-${two(month != null && month > 0 ? month : 1)}-${two(day != null && day > 0 ? day : 1)}',
    'authors': authors, 'publisher': field('Publisher'),
    'genres': [for (final g in (field('Genre') ?? '').split(',')) if (g.trim().isNotEmpty) g.trim()],
    'count': number('Count'), if (manga == 'yesandrighttoleft') 'rightToLeft': true,
    'pageSizes': pageSizes,
  };
}
