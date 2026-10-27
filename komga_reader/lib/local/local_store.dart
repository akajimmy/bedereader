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
    this.authors = const [], this.summary = '', this.readLists = const [], this.inside = 0,
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

  /// The file is the same one as before (its book needn't be opened again).
  bool sameFile(int size, DateTime modified) => size == this.size && modified == this.modified;

  Map<String, Object?> toJson() => {
        'id': id, 'series': seriesId, 'path': path, 'size': size, 'modified': modified.toIso8601String(),
        'title': title, if (epub) 'epub': true, if (mediaType != 'application/zip') 'mediaType': mediaType,
        if (pages > 0) 'pages': pages, if (cover != null) 'cover': cover, if (number.isNotEmpty) 'number': number,
        'numberSort': numberSort, if (released != null) 'released': released!.toIso8601String(),
        if (precision != null) 'precision': precision!.name,
        if (authors.isNotEmpty) 'authors': [for (final (n, r) in authors) [n, r]],
        if (summary.isNotEmpty) 'summary': summary,
        if (readLists.isNotEmpty) 'readLists': [for (final r in readLists) r.toJson()],
        'inside': inside,
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
        inside: j['inside'] as int? ?? 0,
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
/// Each written to a temporary file then moved over the old one (a crash can't leave half of one), its text made off
/// the screen's thread, and not written at all when nothing in it changed.
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

  /// FNV-1a, 64 bits, over the text: two different texts the same by chance - a change not written - is too unlikely
  /// to matter (String.hashCode is far shorter).
  /// [json] as text, and its [_hash] - made on another isolate (a library of thousands of books is megabytes of text).
  /// Static: the work sent there holds [json] only, not the store.
  static Future<(String, int)> _encode(Object json) => Isolate.run(() {
        final t = jsonEncode(json);
        return (t, _hash(t));
      });

  static int _hash(String s) {
    var h = 0xcbf29ce484222325;
    for (var i = 0; i < s.length; i++) {
      h ^= s.codeUnitAt(i);
      h *= 0x100000001b3;
    }
    return h;
  }
  Future<void> _queue = Future.value();

  File _file(String name) => File('${dir.path}${Platform.pathSeparator}$name');
  static String _libraryFile(String libraryId) => 'library-$libraryId.json';

  /// Reads every library's file, the progress and the sizes. A damaged or older file is left out (its library is
  /// scanned again), never fatal.
  Future<void> load() async {
    libraries.clear();
    progress.clear();
    sizes.clear();
    _savedHash.clear();
    if (!await dir.exists()) return;
    await for (final f in dir.list()) {
      final name = f.uri.pathSegments.last;
      if (f is! File || !name.endsWith('.json')) continue;
      final Object? j;
      try {
        final text = await f.readAsString();
        j = jsonDecode(text);
        _savedHash[name] = _hash(text);
      } catch (_) {
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
        j.forEach((k, v) => progress[k as String] = Map<String, Object?>.from(v as Map));
      } else if (name == 'sizes.json') {
        j.forEach((k, v) => sizes[k as String] = [for (final n in v as List) n as int]);
      }
    }
  }

  /// A library's scan, kept (its file written if it changed).
  Future<void> putLibrary(LibraryIndex index) {
    libraries[index.libraryId] = index;
    return _write(_libraryFile(index.libraryId), index.toJson());
  }

  /// A library removed: its file goes; its books' progress and sizes stay (adding the folder again finds them).
  Future<void> removeLibrary(String libraryId) {
    libraries.remove(libraryId);
    final name = _libraryFile(libraryId);
    _savedHash.remove(name);
    return _queue = _queue.then((_) async {
      final f = _file(name);
      if (await f.exists()) await f.delete();
    });
  }

  Future<void> setProgress(String bookId, {required int page, required bool completed, DateTime? at}) {
    progress[bookId] = {'page': page, 'completed': completed, 'at': (at ?? DateTime.now()).toIso8601String()};
    return _write('progress.json', progress);
  }

  Future<void> setSizes(String bookId, List<int> pageSizes) {
    sizes[bookId] = pageSizes;
    return _write('sizes.json', sizes);
  }

  /// Done once every write asked for so far is on disk.
  Future<void> get written => _queue;

  Future<void> _write(String name, Object json) {
    final write = _queue.then((_) async {
      final (text, hash) = await _encode(json);
      if (_savedHash[name] == hash) return; // nothing changed
      await dir.create(recursive: true);
      final tmp = _file('$name.tmp');
      await tmp.writeAsString(text);
      await tmp.rename(_file(name).path);
      _savedHash[name] = hash;
      writes++;
    });
    _queue = write.catchError((Object _) {}); // a failed write doesn't stop the ones after it
    return write;
  }
}
