import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'book_names.dart' show DatePrecision;

/// A series in a local library: stored once, not copied into each of its books.
class LocalSeries {
  const LocalSeries({required this.id, required this.libraryId, required this.name, this.oneshot = false});
  final String id, libraryId, name;

  /// A book of its own (a book loose in the library, or in a _oneshots folder).
  final bool oneshot;

  Map<String, Object?> toJson() => {'id': id, 'name': name, if (oneshot) 'oneshot': true};
  factory LocalSeries.fromJson(Map j, String libraryId) =>
      LocalSeries(id: j['id'] as String, libraryId: libraryId, name: j['name'] as String, oneshot: j['oneshot'] == true);
}

/// A book's place in a read list (a read-list library's list).
class ReadListPlace {
  const ReadListPlace(this.id, this.index, this.count);
  final String id;
  final int index, count;

  Map<String, Object?> toJson() => {'id': id, 'index': index, 'count': count};
  factory ReadListPlace.fromJson(Map j) => ReadListPlace(j['id'] as String, j['index'] as int, j['count'] as int);
}

/// A book in a local library: its file (where, how big, when changed - a file unchanged since isn't opened again),
/// what was read from inside it, and what its name and ComicInfo say.
class LocalBook {
  const LocalBook({
    required this.id, required this.libraryId, required this.seriesId, required this.path, required this.size,
    required this.modified, required this.title, this.epub = false, this.mediaType = 'application/zip',
    this.pages = 0, this.cover, this.number = '', this.numberSort = 0, this.released, this.precision,
    this.authors = const [], this.summary = '', this.readLists = const [], this.inside = 0, this.rightToLeft = false,
    this.publisher, this.genres = const [], this.count,
  });

  final String id, libraryId, seriesId;

  /// The file, its size in bytes and when it was last changed.
  final String path;
  final int size;
  final DateTime modified;

  final String title;
  final bool epub;
  final String mediaType;

  /// A comic's page count (an EPUB: 0).
  final int pages;

  /// The entry its poster is made from (a comic's first page, an EPUB's cover).
  final String? cover;

  /// The number as shown ("1", "1.5", "" for none) and the one it sorts by.
  final String number;
  final num numberSort;

  final DateTime? released;
  final DatePrecision? precision;

  /// (name, role).
  final List<(String, String)> authors;
  final String summary;
  final List<ReadListPlace> readLists;

  /// Which version of the scan's rules read the inside of the file: a book read by older rules is read again.
  final int inside;

  /// Manga read right to left (ComicInfo's Manga: YesAndRightToLeft).
  final bool rightToLeft;

  /// ComicInfo's, for its series: publisher, genres, how many books it has.
  final String? publisher;
  final List<String> genres;
  final int? count;

  /// The file is the same one as before (its book needn't be opened again): the same size, changed at the same moment
  /// - whatever time zone the device is in now (review, 2026-10-26: kept as local time, every book looked changed
  /// after the iPad crossed one, and a whole library was read again).
  bool sameFile(int size, DateTime modified) => size == this.size && modified.isAtSameMomentAs(this.modified);

  Map<String, Object?> toJson() => {
        'id': id, 'series': seriesId, 'path': path, 'size': size, 'modified': modified.toUtc().toIso8601String(),
        'title': title, if (epub) 'epub': true, if (mediaType != 'application/zip') 'mediaType': mediaType,
        if (pages > 0) 'pages': pages, if (cover != null) 'cover': cover, if (number.isNotEmpty) 'number': number,
        'numberSort': numberSort, if (released != null) 'released': released!.toIso8601String(),
        if (precision != null) 'precision': precision!.name,
        if (authors.isNotEmpty) 'authors': [for (final (n, r) in authors) [n, r]],
        if (summary.isNotEmpty) 'summary': summary,
        if (readLists.isNotEmpty) 'readLists': [for (final r in readLists) r.toJson()],
        'inside': inside, if (rightToLeft) 'rightToLeft': true, if (publisher != null) 'publisher': publisher,
        if (genres.isNotEmpty) 'genres': genres, if (count != null) 'count': count,
      };

  factory LocalBook.fromJson(Map j, String libraryId) => LocalBook(
        id: j['id'] as String, libraryId: libraryId, seriesId: j['series'] as String, path: j['path'] as String,
        size: j['size'] as int, modified: DateTime.parse(j['modified'] as String), title: j['title'] as String,
        epub: j['epub'] == true, mediaType: j['mediaType'] as String? ?? 'application/zip',
        pages: j['pages'] as int? ?? 0, cover: j['cover'] as String?, number: j['number'] as String? ?? '',
        numberSort: j['numberSort'] as num? ?? 0,
        released: j['released'] == null ? null : DateTime.parse(j['released'] as String),
        precision: DatePrecision.values.asNameMap()[j['precision']],
        authors: [for (final a in (j['authors'] as List?) ?? const []) ((a as List)[0] as String, a[1] as String)],
        summary: j['summary'] as String? ?? '',
        readLists: [for (final r in (j['readLists'] as List?) ?? const []) ReadListPlace.fromJson(r as Map)],
        inside: j['inside'] as int? ?? 0, rightToLeft: j['rightToLeft'] == true, publisher: j['publisher'] as String?,
        genres: [for (final g in (j['genres'] as List?) ?? const []) g as String], count: j['count'] as int?,
      );
}

/// One library's scan: its series and books.
class LibraryIndex {
  LibraryIndex(this.libraryId, Iterable<LocalSeries> series, Iterable<LocalBook> books)
      : series = {for (final s in series) s.id: s},
        books = {for (final b in books) b.id: b};
  final String libraryId;
  final Map<String, LocalSeries> series;
  final Map<String, LocalBook> books;

  Map<String, Object?> toJson() => {
        'v': LocalStore.version,
        'series': [for (final s in series.values) s.toJson()],
        'books': [for (final b in books.values) b.toJson()],
      };

  factory LibraryIndex.fromJson(String libraryId, Map j) => LibraryIndex(
        libraryId,
        [for (final s in (j['series'] as List?) ?? const []) LocalSeries.fromJson(s as Map, libraryId)],
        [for (final b in (j['books'] as List?) ?? const []) LocalBook.fromJson(b as Map, libraryId)],
      );
}

/// What the local libraries' scans found, kept on this device in [dir] - a file each library, so a rescan rewrites
/// only the libraries that changed (the experiment kept them all in the downloads' one index, rewritten whole on every
/// scan, and on the first opening of each book). Beside them, small files of their own:
///   progress.json    reading progress (local books never sync: no queue, no baseline)
///   sizes.json       the pages' sizes of the books opened so far (from ComicInfo or the pictures themselves)
///
/// Writes run one after another, in the order asked, each to a temporary file flushed to the disk then moved over the
/// old one (a crash can't leave half of one); the text is made on another isolate, and not written at all when nothing
/// in it changed. Writes of the same file asked while one is waiting are one write, of what it holds by then (page
/// turns in a row: one write). A file that couldn't be read when loading is copied aside (*.unreadable) before anything
/// replaces it - its contents never lost to the next write.
class LocalStore {
  LocalStore(this.dir);
  final Directory dir;

  /// The format of the files ([LibraryIndex.toJson]); a file of another is read as empty (scanned again).
  static const version = 1;

  final Map<String, LibraryIndex> libraries = {};

  /// bookId -> {page, completed, at (ISO time)}.
  final Map<String, Map<String, Object?>> progress = {};

  /// bookId -> each page's width and height, in turn ([w, h, w, h ...]; 0, 0 for a page whose size isn't known).
  final Map<String, List<int>> sizes = {};

  /// How many files have been written - tests.
  int writes = 0;

  final Map<String, int> _savedHash = {}; // file name -> [_hash] of the text last written to it (or read from it)
  final Map<String, Future<void>> _waiting = {}; // file name -> its write asked for and not started yet
  Future<void> _queue = Future.value();

  File _file(String name) => File('${dir.path}${Platform.pathSeparator}$name');
  static String _libraryFile(String libraryId) => 'library-$libraryId.json';

  /// Reads every library's file, the progress and the sizes - once the writes asked for so far are done (a write
  /// still waiting would otherwise be lost to what's read). A damaged or older library file is left out (scanned
  /// again); a damaged progress or sizes file keeps what can be read of it, and is copied aside first. Never fatal.
  Future<void> load() async {
    await written;
    libraries.clear();
    progress.clear();
    sizes.clear();
    _savedHash.clear();
    if (!await dir.exists()) return;
    await for (final f in dir.list()) {
      final name = f.uri.pathSegments.last;
      if (f is! File) continue;
      if (name.endsWith('.tmp')) {
        await _quietly(f.delete); // (a write cut short)
        continue;
      }
      if (!name.endsWith('.json')) continue;
      final Object? j;
      try {
        final text = await f.readAsString();
        j = jsonDecode(text);
        _savedHash[name] = _hash(text);
      } catch (_) {
        if (name == 'progress.json' || name == 'sizes.json') await _quietly(() => f.copy('${f.path}.unreadable'));
        continue;
      }
      if (j is! Map) continue;
      if (name.startsWith('library-')) {
        if (j['v'] != version) continue;
        final id = name.substring('library-'.length, name.length - '.json'.length);
        try {
          libraries[id] = LibraryIndex.fromJson(id, j);
        } catch (_) {
          // damaged: scanned again
        }
      } else if (name == 'progress.json') {
        var bad = false;
        for (final MapEntry(:key, :value) in j.entries) {
          if (key is String && value is Map) {
            progress[key] = Map<String, Object?>.from(value);
          } else {
            bad = true;
          }
        }
        if (bad) await _quietly(() => f.copy('${f.path}.unreadable'));
      } else if (name == 'sizes.json') {
        var bad = false;
        for (final MapEntry(:key, :value) in j.entries) {
          if (key is String && value is List && value.every((n) => n is int)) {
            sizes[key] = value.cast<int>().toList();
          } else {
            bad = true;
          }
        }
        if (bad) await _quietly(() => f.copy('${f.path}.unreadable'));
      }
    }
  }

  /// A library's scan, kept (its file written if it changed).
  Future<void> putLibrary(LibraryIndex index) {
    libraries[index.libraryId] = index;
    return _write(_libraryFile(index.libraryId), () => libraries[index.libraryId]);
  }

  /// A library removed: its file goes; its books' progress and sizes stay (adding the folder again finds them).
  Future<void> removeLibrary(String libraryId) {
    libraries.remove(libraryId);
    final name = _libraryFile(libraryId);
    // a write of it asked before this runs before it (and writes nothing: gone by then); one asked after is another,
    // after it - not joined to the one before (which would leave no file)
    unawaited(_waiting.remove(name));
    return _run(() async {
      // (here, in turn: a write of this file asked before ran first, and one asked after finds no hash - written)
      _savedHash.remove(name);
      final f = _file(name);
      if (await f.exists()) await f.delete();
    });
  }

  Future<void> setProgress(String bookId, {required int page, required bool completed, DateTime? at}) {
    progress[bookId] = {'page': page, 'completed': completed, 'at': (at ?? DateTime.now()).toIso8601String()};
    return _write('progress.json', () => progress);
  }

  Future<void> setSizes(String bookId, List<int> pageSizes) {
    sizes[bookId] = pageSizes;
    return _write('sizes.json', () => sizes);
  }

  /// Done once every write asked for so far is on disk (failed ones too).
  Future<void> get written => _queue;

  /// [what] (a [LibraryIndex], or a map) is taken when the write runs - the latest, for writes asked meanwhile.
  Future<void> _write(String name, Object? Function() what) => _waiting[name] ??= _run(() async {
        unawaited(_waiting.remove(name)); // (this very write: running now - one asked from here on is another)
        final o = what();
        if (o == null) return; // (removed meanwhile)
        final (text, hash) = await _encode(o);
        if (_savedHash[name] == hash) return; // nothing changed
        await dir.create(recursive: true);
        final tmp = _file('$name.tmp');
        await tmp.writeAsString(text, flush: true);
        await tmp.rename(_file(name).path);
        _savedHash[name] = hash;
        writes++;
      });

  /// [step], after everything asked before it; one that fails doesn't stop the ones after it.
  Future<void> _run(Future<void> Function() step) {
    final run = _queue.then((_) => step());
    _queue = run.catchError((Object _) {});
    return run;
  }

  static Future<void> _quietly(Future<Object?> Function() f) async {
    try {
      await f();
    } catch (_) {}
  }

  /// [o] as text, and its [_hash] - made on another isolate, a library's JSON built there too (a library of thousands
  /// of books is megabytes of text). Static: what's sent there is [o] only, not the store.
  static Future<(String, int)> _encode(Object o) => Isolate.run(() {
        final t = jsonEncode(o is LibraryIndex ? o.toJson() : o);
        return (t, _hash(t));
      });

  /// FNV-1a, 64 bits, over the text: two different texts the same by chance - a change not written - is too unlikely
  /// to matter (String.hashCode is far shorter).
  static int _hash(String s) {
    var h = 0xcbf29ce484222325;
    for (var i = 0; i < s.length; i++) {
      h ^= s.codeUnitAt(i);
      h *= 0x100000001b3;
    }
    return h;
  }
}
