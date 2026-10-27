import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';

import '../content_changed.dart';
import '../epub/progress.dart' show komgaEpubPage;
import '../offline/catalogue_source.dart';
import 'book_names.dart';
import 'file_zip.dart';
import 'library_fs.dart';
import 'local_library.dart';
import 'local_scan.dart';
import 'local_store.dart';

/// The local libraries as a source of books: folders on this device (later: shares), scanned into a [LocalStore] and
/// answered from it - the questions every source answers from books held here through [CatalogueSource], its own
/// (pages, posters, progress, EPUBs) here. Opened once by the app; [close]d when it's done with.
class LocalSource extends CatalogueSource {
  LocalSource._(this.store, this._libraries, this._posters, this._fsFor);

  /// Opens the local libraries kept in [dir]: what the last scans found at once (nothing scanned meanwhile - call
  /// [rescan]). [fsFor]: where a library's files are read from (tests give their own).
  static Future<LocalSource> open(Directory dir, List<LocalLibrary> libraries,
      {LibraryFs Function(String path)? fsFor}) async {
    final store = LocalStore(dir);
    await store.load();
    final source = LocalSource._(store, List.of(libraries), Directory('${dir.path}${Platform.pathSeparator}posters'),
        fsFor ?? (_) => _localFs);
    source._rebuild();
    return source;
  }

  static final _localFs = LocalFs();

  final LocalStore store;
  List<LocalLibrary> _libraries;
  final Directory _posters;
  final LibraryFs Function(String path) _fsFor;

  /// What it's known by where a server address would be (downloads, error messages, the reader's EPUB cache).
  static const address = 'local';
  @override
  String get baseUrl => address;

  /// The libraries' folders.
  List<LocalLibrary> get folders => List.unmodifiable(_libraries);

  /// No book in any library (a folder typed wrong, or empty - or nothing scanned yet).
  bool get isEmpty => _entries.isEmpty;

  /// Whether [id] - a book, series, library or read list - is one of the local libraries': told by its form.
  bool owns(String id) => isLocalId(id);

  /// Counts up when what's listed changed (a scan found books added, changed or gone; a library added, renamed,
  /// removed).
  final changed = ValueNotifier<int>(0);

  /// While a scan runs: the books done so far ([found]: the book files found, while folders are listed); null
  /// otherwise.
  final scanning = ValueNotifier<int?>(null);
  final found = ValueNotifier<int?>(null);

  /// What the last scan couldn't read, by library id (none: all read).
  Map<String, LibraryScan> lastScan = const {};

  /// Libraries whose folder looks deleted - not there, while the place it was in answers - to ask the user about.
  final missing = ValueNotifier<List<LocalLibrary>>(const []);

  /// Libraries removed (Settings, or a missing one): their ids, and their series' and books' (the app: the pins to
  /// them go - user, 2026-10-26).
  void Function(Set<String> ids)? onRemoved;

  // ---- the entries: Komga's JSON for each book, made from the store once a scan, for the questions -----------------
  Map<String, Map<String, dynamic>> _entries = {};
  Map<String, LocalBook> _books = {}; // bookId -> its record
  Map<String, String> _seriesFirst = {}; // seriesId -> its first book (its poster)

  @override
  Map<String, Map<String, dynamic>> get entries => _entries;

  @override
  Map<String, dynamic>? readProgressOf(String bookId) {
    final p = store.progress[bookId];
    if (p == null) return null;
    return {'page': p['page'], 'completed': p['completed'] == true, 'readDate': p['at']};
  }

  void _rebuild() {
    final entries = <String, Map<String, dynamic>>{}, books = <String, LocalBook>{}, first = <String, (String, num)>{};
    for (final library in _libraries) {
      final index = store.libraries[library.id];
      if (index == null) continue;
      final lib = {'id': library.id, 'name': library.name};
      final seriesJson = {for (final s in index.series.values) s.id: _seriesJson(s)};
      for (final b in index.books.values) {
        final series = seriesJson[b.seriesId];
        if (series == null) continue;
        books[b.id] = b;
        entries[b.id] = {
          'book': _bookJson(b, index.series[b.seriesId]!), 'series': series, 'library': lib,
          // a read-list library's list, named after the library
          'readLists': [
            for (final r in b.readLists) {'id': r.id, 'name': library.name, 'index': r.index, 'count': r.count},
          ],
          'collections': const [], 'state': 'done',
        };
        if (first[b.seriesId] case (_, final n) when n <= b.numberSort) continue;
        first[b.seriesId] = (b.id, b.numberSort);
      }
    }
    _entries = entries;
    _books = books;
    _seriesFirst = {for (final MapEntry(:key, :value) in first.entries) key: value.$1};
  }

  static String _date(DateTime d) =>
      '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

  static Map<String, dynamic> _seriesJson(LocalSeries s) => {
        'id': s.id, 'name': s.name, 'libraryId': s.libraryId, 'oneshot': s.oneshot,
        'metadata': {'title': s.name, 'titleSort': s.name, 'status': 'ONGOING', 'genres': const [], 'tags': const []},
        'booksMetadata': {'authors': const []},
      };

  static Map<String, dynamic> _bookJson(LocalBook b, LocalSeries s) {
    final name = b.path.substring(b.path.lastIndexOf(RegExp(r'[\\/]')) + 1);
    final modified = b.modified.toUtc().toIso8601String();
    return {
      'id': b.id, 'seriesId': b.seriesId, 'seriesTitle': s.name, 'libraryId': b.libraryId,
      'name': name.contains('.') ? name.substring(0, name.lastIndexOf('.')) : name, 'url': b.path,
      'created': modified, 'lastModified': modified, 'fileLastModified': modified, 'sizeBytes': b.size,
      'size': '${(b.size / 1048576).toStringAsFixed(1)} MiB',
      'media': {
        'status': 'READY', 'mediaType': b.mediaType, 'mediaProfile': b.epub ? 'EPUB' : 'DIVINA',
        // an EPUB: its progress as a share of the book, out of 100 (Komga counts its positions)
        'pagesCount': b.epub ? 100 : b.pages,
      },
      'metadata': {
        'title': b.title, 'summary': b.summary, 'number': b.number, 'numberSort': b.numberSort,
        if (b.released != null) 'releaseDate': _date(b.released!),
        if (b.released != null && b.precision != null) 'releaseDatePrecision': b.precision!.name,
        'authors': [for (final (n, r) in b.authors) {'name': n, 'role': r}],
        'tags': const [], 'isbn': '', 'links': const [],
      },
      'readProgress': null, 'deleted': false, 'oneshot': s.oneshot,
    };
  }

  // ---- scanning -----------------------------------------------------------------------------------------------------
  Future<void>? _scan;

  /// Every library scanned again - new and changed files opened, the rest kept; one at a time (asked while one runs,
  /// it runs after). The screens look again only if something changed.
  Future<void> rescan() {
    final before = _scan;
    final run = () async {
      await before?.catchError((Object _) {});
      scanning.value = 0;
      try {
        final report = <String, LibraryScan>{};
        final looksDeleted = <LocalLibrary>[];
        var done = 0;
        final signature = _signature();
        for (final library in List.of(_libraries)) {
          final r = await scanLibrary(_fsFor(library.path), library, store.libraries[library.id],
              onFound: (n) => found.value = n, onBook: (_) {
            found.value = null;
            scanning.value = ++done;
          });
          found.value = null;
          report[library.id] = r.report;
          // (not one removed while it was being scanned: it was asked about after it had gone - the review, 2026-10-26)
          if (r.report.missing && _libraries.any((l) => l.id == library.id)) looksDeleted.add(library);
          if (r.report.reached && _libraries.any((l) => l.id == library.id)) await store.putLibrary(r.index);
        }
        lastScan = report;
        missing.value = [for (final l in looksDeleted) if (_libraries.any((x) => x.id == l.id)) l];
        _rebuild();
        if (_signature() != signature) {
          changed.value++;
          contentChanged.value++;
        }
      } finally {
        scanning.value = null;
        found.value = null;
      }
    }();
    _scan = run;
    return run;
  }

  int _signature() => Object.hashAllUnordered([
        for (final library in _libraries) library.name,
        for (final b in _books.values) Object.hash(b.id, b.size, b.modified, b.title),
      ]);

  /// The libraries changed (Settings): kept, the removed ones' scans let go (not their progress), and scanned again -
  /// not waited for: [scanning] tells how it goes, and the screens look again when it's done (the first scan of a big
  /// library kept the sign-in screen waiting with nothing said - the review, 2026-10-26). [rescan] waits for it.
  Future<void> setLibraries(List<LocalLibrary> libraries) async {
    final ids = {for (final l in libraries) l.id};
    final removed = [for (final l in _libraries) if (!ids.contains(l.id)) l];
    // the list first, before anything is waited for: a scan ending meanwhile sees it (the review, 2026-10-26: one
    // ending while a removed library's files were let go put it back up as looking deleted)
    _libraries = List.of(libraries);
    final gone = <String>{};
    for (final l in removed) {
      final index = store.libraries[l.id];
      gone.addAll([l.id, ...?index?.series.keys, ...?index?.books.keys]);
      await store.removeLibrary(l.id);
    }
    if (gone.isNotEmpty) onRemoved?.call(gone);
    await LocalLibraries.save(libraries);
    _rebuild();
    changed.value++;
    contentChanged.value++;
    unawaited(rescan().catchError((Object _) {})); // (a scan's own trouble is in lastScan)
  }

  // ---- account / libraries ------------------------------------------------------------------------------------------
  @override
  Future<Map<String, dynamic>?> me() async => null; // (no account)

  @override
  void close() => unawaited(closeFiles());

  /// The books held open let go - done once they are (a file held open can't be moved or deleted on Windows).
  Future<void> closeFiles() async {
    final open = [..._open.values];
    _open.clear();
    for (final o in open) {
      await o.archive.close();
    }
  }

  /// The library list, from the libraries (an empty one, or one not scanned yet, is listed too).
  @override
  Future<List<dynamic>> libraries() async =>
      [for (final l in _libraries) {'id': l.id, 'name': l.name}]..sort((a, b) => '${a['name']}'.compareTo('${b['name']}'));

  /// [id] (a book, series or library of these) is on a network share.
  bool onShare(String id) {
    final path = _books[id]?.path ?? _books[_seriesFirst[id]]?.path ?? libraryPath(id);
    return path != null && splitUnc(path) != null;
  }

  /// A library's folder.
  String? libraryPath(String libraryId) => _libraries.where((l) => l.id == libraryId).firstOrNull?.path;

  /// A book's file; null for none of these.
  String? bookPath(String bookId) => _books[bookId]?.path;

  /// Whether a book's file has gone since the last scan (not there, while its library's folder is).
  Future<bool> fileGone(String bookId) async {
    final b = _books[bookId];
    if (b == null) return false;
    final fs = _fsFor(b.path);
    try {
      final f = await fs.open(b.path);
      await f.close();
      return false;
    } catch (e) {
      return fs.classify(e) == FileTrouble.gone;
    }
  }

  // ---- pages: straight out of the archive ---------------------------------------------------------------------------
  // the books open lately (their directories read once), [_keepOpen] at most; one being read isn't closed under it
  final Map<String, _OpenBook> _open = {};
  static const _keepOpen = 4;

  Future<T> _withArchive<T>(String bookId, Future<T> Function(ComicArchive a, List<String> pages) use) async {
    final b = _books[bookId];
    if (b == null) throw NeedsKomga('This book'); // (not one of these: never asked here)
    var o = _open.remove(bookId);
    if (o != null && !o.book.sameFile(b.size, b.modified)) {
      // its file changed since it was opened: opened again
      if (o.users == 0) unawaited(o.archive.close());
      o = null;
    }
    if (o == null) {
      final archive = await ComicArchive.open(_fsFor(b.path), b.path);
      o = _OpenBook(b, archive, comicPages(archive.names));
    }
    _open[bookId] = o; // (the newest last)
    o.users++;
    try {
      return await use(o.archive, o.pages);
    } finally {
      o.users--;
      while (_open.length > _keepOpen) {
        final oldest = _open.entries.where((e) => e.value.users == 0).firstOrNull;
        if (oldest == null) break;
        _open.remove(oldest.key);
        unawaited(oldest.value.archive.close());
      }
    }
  }

  /// A comic's pages, read from its archive as it's opened, with their sizes - measured from the start of each
  /// picture the first time, then kept ([LocalStore.sizes]).
  @override
  Future<List<dynamic>> pages(String bookId) async {
    if (_books[bookId]?.epub ?? false) return const [];
    return _withArchive(bookId, (archive, names) async {
      var sizes = store.sizes[bookId];
      if (sizes == null || sizes.length != names.length * 2) {
        sizes = await _measure(archive, names);
        unawaited(store.setSizes(bookId, sizes));
      }
      return [
        for (final (i, n) in names.indexed)
          {
            'number': i + 1, 'mediaType': imageType(n),
            if (sizes[2 * i] > 0) ...{'width': sizes[2 * i], 'height': sizes[2 * i + 1]},
          },
      ];
    });
  }

  /// Each page's size from the start of its picture ([w, h, ...]; 0, 0 where it can't be told), 8 at a time - a
  /// picture whose size isn't in its first 64 KB (a big colour profile) read further, to 1 MB.
  static Future<List<int>> _measure(ComicArchive archive, List<String> names) async {
    final out = List.filled(names.length * 2, 0);
    var next = 0;
    Future<void> worker() async {
      while (next < names.length) {
        final i = next++;
        try {
          var size = imageSizeOf(await archive.head(names[i], 64 * 1024) ?? Uint8List(0));
          size ??= imageSizeOf(await archive.head(names[i], 1024 * 1024) ?? Uint8List(0));
          if (size == null) continue;
          out[2 * i] = size.$1;
          out[2 * i + 1] = size.$2;
        } catch (_) {
          // (its size not known: shown alone)
        }
      }
    }

    await Future.wait([for (var k = 0; k < 8; k++) worker()]);
    return out;
  }

  @override
  Future<Uint8List> pageBytes(String bookId, int number) => _withArchive(bookId, (archive, names) async {
        if (number < 1 || number > names.length) throw FormatException('No page $number');
        final bytes = await archive.read(names[number - 1]);
        if (bytes == null) throw FormatException('No page $number');
        return bytes;
      });

  @override
  Future<Uint8List> pageThumbBytes(String bookId, int number) => pageBytes(bookId, number);

  // ---- posters: each book's cover (a comic's first page, an EPUB's cover), made small when first shown, and kept -----
  /// A book's poster file; '' for none of these. Named for the file as it is now - a file replaced gets a poster of
  /// its own (the experiment kept the first one forever).
  @override
  String bookThumb(String id) {
    final b = _books[id];
    if (b == null) return '';
    final sign = stableId('${b.size}|${b.modified.toUtc().toIso8601String()}');
    return '${_posters.path}${Platform.pathSeparator}$id-$sign.png';
  }

  /// A series' poster: its first book's.
  @override
  String seriesThumb(String id) {
    final first = _seriesFirst[id];
    return first == null ? '' : bookThumb(first);
  }

  @override
  String readListThumb(String id) => '';
  @override
  String collectionThumb(String id) => '';

  @override
  ImageProvider thumbImage(String ref) => _Poster(ref, this);

  /// Whether a poster reference ([bookThumb], [seriesThumb]) is one of these.
  bool ownsPoster(String ref) => ref.startsWith(_posters.path);

  final Map<String, Future<bool>> _making = {}; // posters being made (one each, however many tiles ask)
  int _makingNow = 0;
  final List<Completer<void>> _turns = []; // posters waiting for a turn (a few at a time: the files may be on a NAS)
  // posters that couldn't be made from their file as it is (named for the file: one changed is tried again); one out
  // of reach isn't kept here - tried again, the share may be back
  final Set<String> _noPoster = {};

  /// Makes the poster at [path] if it isn't there yet. False: none can be had.
  @visibleForTesting
  Future<bool> posterAt(String path) => _making[path] ??= () async {
        try {
          if (path.isEmpty) return false;
          if (await File(path).exists()) return true;
          if (_noPoster.contains(path)) return false;
          final id = path.substring(path.lastIndexOf(Platform.pathSeparator) + 1).split('-').first;
          final b = _books[id];
          final cover = b?.cover;
          if (b == null || cover == null) return false;
          if (_makingNow >= 3) {
            final turn = Completer<void>();
            _turns.add(turn);
            await turn.future;
          }
          _makingNow++;
          try {
            final fs = _fsFor(b.path);
            final Uint8List? bytes;
            // its own archive: not the reader's (a grid scrolling closed the reader's book under it - the review)
            try {
              final archive = await ComicArchive.open(fs, b.path);
              try {
                bytes = await archive.read(archive.find(cover) ?? cover);
              } finally {
                await archive.close();
              }
            } catch (e) {
              if (fs.classify(e) != FileTrouble.noAnswer) _noPoster.add(path);
              return false;
            }
            if (bytes == null) {
              _noPoster.add(path);
              return false;
            }
            final ui.Codec codec;
            try {
              codec = await ui.instantiateImageCodec(bytes, targetWidth: 320);
            } catch (_) {
              _noPoster.add(path); // (a cover that isn't a picture this device reads)
              return false;
            }
            final frame = await codec.getNextFrame();
            final png = await frame.image.toByteData(format: ui.ImageByteFormat.png);
            frame.image.dispose();
            codec.dispose();
            if (png == null) return false;
            await _posters.create(recursive: true);
            await File(path).writeAsBytes(png.buffer.asUint8List(png.offsetInBytes, png.lengthInBytes));
            return true;
          } finally {
            _makingNow--;
            if (_turns.isNotEmpty) _turns.removeAt(0).complete();
          }
        } catch (_) {
          return false;
        } finally {
          unawaited(Future(() => _making.remove(path)));
        }
      }();

  // ---- reading progress: kept on this device ------------------------------------------------------------------------
  @override
  Future<void> setProgress(String bookId, int page, {bool completed = false}) =>
      store.setProgress(bookId, page: page, completed: completed);

  @override
  Future<void> markRead(String bookId) {
    final b = _books[bookId];
    return store.setProgress(bookId, page: b == null ? 1 : (b.epub ? 100 : b.pages), completed: true);
  }

  @override
  Future<void> markUnread(String bookId) => store.clearProgress(bookId);

  // ---- EPUBs: read from their own file (the reader's FileEpubSource) ---------------------------------------------------
  /// No positions list (Komga's): the place is kept as it was read, the progress as a share of the book.
  @override
  Future<List<dynamic>> epubPositions(String bookId) async => const [];

  @override
  Future<Map<String, dynamic>?> epubProgression(String bookId) async =>
      (store.progress[bookId]?['place'] as Map?)?.cast<String, dynamic>();

  @override
  Future<void> setEpubProgression(String bookId, Map<String, dynamic> progression) {
    final at = (progression['locator'] as Map?)?['locations'] as Map?;
    final page = komgaEpubPage((at?['totalProgression'] as num?)?.toDouble(), 100) ?? 0;
    return store.setProgress(bookId, page: page, completed: false, place: progression);
  }

  /// An EPUB's whole file (the reader reads it from this).
  Future<Uint8List> epubBytes(String bookId) async {
    final b = _books[bookId];
    if (b == null || !b.epub) throw NeedsKomga('This book');
    return readWhole(_fsFor(b.path), b.path);
  }

  // ---- what only Komga has ------------------------------------------------------------------------------------------
  // (settings are this device's own here: nothing to sync)
  @override
  Future<Map<String, dynamic>> clientSettings() async => const {};
  @override
  Future<void> putClientSetting(String key, String value) async {}
  @override
  Future<Map<String, dynamic>?> epubManifest(String bookId) async => throw NeedsKomga('This book');
  @override
  Future<Uint8List> epubResource(String bookId, String path) async => throw NeedsKomga('This book');
  @override
  Future<Uint8List> bookFileBytes(String bookId) => epubBytes(bookId);
  @override
  Future<Uint8List?> thumbBytes(String url) async => null;
  @override
  Future<List<dynamic>> bookReadLists(String bookId) async => [
        for (final r in (entries[bookId]?['readLists'] as List?) ?? const [])
          if (await readList((r as Map)['id'] as String) case final list?) list,
      ];
  @override
  Future<List<dynamic>> seriesCollections(String seriesId) async => const [];
  @override
  Future<void> deleteBookFile(String bookId) async => throw NeedsKomga('Deleting a book');
  @override
  Future<void> deleteSeriesFiles(String seriesId) async => throw NeedsKomga('Deleting a series');
  @override
  Future<void> renameReadList(String id, String name) async => throw NeedsKomga('Renaming a read list');
  @override
  Future<void> renameCollection(String id, String name) async => throw NeedsKomga('Renaming a collection');
}

class _OpenBook {
  _OpenBook(this.book, this.archive, this.pages);
  final LocalBook book;
  final ComicArchive archive;
  final List<String> pages;
  int users = 0;
}

/// A local book's poster, made when it's first shown ([LocalSource.posterAt]).
class _Poster extends ImageProvider<_Poster> {
  const _Poster(this.path, this.source);
  final String path;
  final LocalSource source;

  @override
  Future<_Poster> obtainKey(ImageConfiguration configuration) => SynchronousFuture(this);

  @override
  ImageStreamCompleter loadImage(_Poster key, ImageDecoderCallback decode) =>
      MultiFrameImageStreamCompleter(codec: _load(decode), scale: 1);

  Future<ui.Codec> _load(ImageDecoderCallback decode) async {
    if (!await source.posterAt(path)) throw StateError('no poster for $path');
    return decode(await ui.ImmutableBuffer.fromUint8List(await File(path).readAsBytes()));
  }

  @override
  bool operator ==(Object other) => other is _Poster && other.path == path;
  @override
  int get hashCode => path.hashCode;
}
