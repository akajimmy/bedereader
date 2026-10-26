import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../app_log.dart';
import '../epub/source.dart' show Zip;
import '../offline/offline_komga.dart';
import '../offline/store.dart';
import 'file_zip.dart';
import 'folder_scan.dart';
import 'storage.dart';

/// Local mode (experimental/sources): Komga as if it were a few folders on this device - no server at all. The
/// libraries are folders ([LocalLibrary]), scanned into entries shaped as downloads' ([scanLibraries]), and answered
/// as the offline source answers for downloads: browsing, filters, sort, reading progress (kept on the device). Pages
/// come out of the CBZ files where they are; an EPUB is opened from its own file.
///
/// The last scan is kept (index.json in [dataDir]): a start shows it at once and scans again in the background,
/// opening only the files that are new or changed ([rescan]). Posters are made when a tile first asks for one.
class FolderKomga extends OfflineKomga {
  FolderKomga._(super.store, this._folders, this._thumbs) : super(baseUrl: address);

  /// Its "server address" (saved as the server, so the app knows to start in local mode).
  static const address = 'local';

  List<LocalLibrary> _folders;
  final Directory _thumbs;

  /// The libraries: folders.
  List<LocalLibrary> get folders => List.unmodifiable(_folders);

  // ---- this device's local libraries (saved with the app's settings) ---------------------------------------------
  static const _librariesKey = 'local.libraries';

  static Future<List<LocalLibrary>> savedLibraries() async {
    final raw = (await SharedPreferences.getInstance()).getString(_librariesKey);
    if (raw == null) return const [];
    try {
      return [for (final j in jsonDecode(raw) as List) LocalLibrary.fromJson((j as Map).cast<String, dynamic>())];
    } catch (_) {
      return const [];
    }
  }

  static Future<void> saveLibraries(List<LocalLibrary> libraries) async => (await SharedPreferences.getInstance())
      .setString(_librariesKey, jsonEncode([for (final l in libraries) l.toJson()]));

  /// Local mode on [libraries], kept in [dataDir] (local\ in the app's storage): the last scan at once if there is one
  /// (scanned again in the background), else a first scan, waited for - [onBook] told how far it has got.
  static Future<FolderKomga> open(List<LocalLibrary> libraries, {required Directory dataDir,
      void Function(int books)? onBook}) async {
    await Storage.instance.load(); // (the shares' logins)
    final store = OfflineStore(dataDir);
    await dataDir.create(recursive: true);
    await store.load(); // the last scan, and the progress kept here
    final ids = {for (final l in libraries) l.id};
    store.books.removeWhere((_, e) => !ids.contains((e['library'] as Map?)?['id']));
    final api = FolderKomga._(store, List.of(libraries), Directory('${dataDir.path}${Platform.pathSeparator}thumbs'));
    await api._loadKeptMissing();
    if (store.books.isEmpty) {
      await api.rescan(onBook: onBook);
    } else {
      unawaited(api.rescan());
    }
    return api;
  }

  /// No book in any of the libraries (a folder typed wrong, or empty).
  bool get isEmpty => store.books.isEmpty;

  /// Books scanned so far while a scan runs; null when none is running.
  final scanning = ValueNotifier<int?>(null);

  /// Counts up each time a scan has changed what's listed (screens showing the libraries look again).
  final changed = ValueNotifier<int>(0);

  /// The libraries the last scan couldn't read (their books are the scan before's) - by id.
  Set<String> unreadable = const {};

  /// What the last scan couldn't read, by library id (none: all read) - for Settings (and the app log).
  Map<String, LibraryScan> lastScan = const {};

  /// How many books a library has now.
  int booksIn(String libraryId) =>
      store.books.values.where((e) => (e['library'] as Map?)?['id'] == libraryId).length;

  /// Libraries whose folder looks deleted - not there, while the place it was in answers - to ask the user about:
  /// remove the library ([removeMissing]), or keep it as out of reach ([keepMissing]) (user, 2026-10-25).
  final toAsk = ValueNotifier<List<LocalLibrary>>(const []);

  /// The user's answer: the library goes, with its books.
  Future<void> removeMissing(LocalLibrary library) async {
    toAsk.value = [for (final l in toAsk.value) if (l.id != library.id) l];
    await setLibraries([for (final l in _folders) if (l.id != library.id) l]);
  }

  /// The user's answer: kept, as if out of reach - not asked again, read again once its folder is back.
  Future<void> keepMissing(LocalLibrary library) async {
    toAsk.value = [for (final l in toAsk.value) if (l.id != library.id) l];
    _keptMissing.add(library.id);
    await _saveKeptMissing();
  }

  static const _keptMissingKey = 'local.keptMissing';
  final Set<String> _keptMissing = {};

  Future<void> _loadKeptMissing() async =>
      _keptMissing.addAll((await SharedPreferences.getInstance()).getStringList(_keptMissingKey) ?? const []);

  Future<void> _saveKeptMissing() async =>
      (await SharedPreferences.getInstance()).setStringList(_keptMissingKey, _keptMissing.toList());

  @override
  Listenable? get localChanges => changed;

  /// A book, series or library of these folders.
  @override
  bool isLocal(String id) =>
      store.books.containsKey(id) || _folders.any((l) => l.id == id) || _seriesIds.contains(id);

  // the series' ids, worked out again after each change (asked about for every tile beside Komga's)
  Set<String> get _seriesIds {
    if (_seriesAt != changed.value || _seriesIdsKept == null) {
      _seriesAt = changed.value;
      _seriesIdsKept = {for (final e in store.books.values) (e['book'] as Map)['seriesId'] as String};
    }
    return _seriesIdsKept!;
  }

  Set<String>? _seriesIdsKept;
  int _seriesAt = -1;

  @override
  Future<Uint8List> Function()? localEpub(String bookId) {
    final e = store.books[bookId];
    if (e?['epub'] != true) return null;
    final path = e!['path'] as String;
    return () => Storage.instance.of(path).readAll(path);
  }

  Future<void>? _scan;

  /// The folders scanned again: new and changed files opened, the rest kept from the last scan; books whose files
  /// went, gone. One at a time (a second asked for while one runs waits for it, then runs).
  Future<void> rescan({void Function(int books)? onBook}) async {
    final before = _scan;
    final run = () async {
      await before?.catchError((Object _) {});
      scanning.value = 0;
      try {
        final known = {for (final e in store.books.values) e['path'] as String: e};
        final failed = <String>{};
        final gone = <LocalLibrary>[];
        final report = <String, LibraryScan>{};
        final fresh = await scanLibraries(_folders, known: known, onBook: (n) {
          scanning.value = n;
          onBook?.call(n);
        }, onUnreadable: (lib, error, {missing = false}) {
          failed.add(lib.id);
          if (missing && !_keptMissing.contains(lib.id)) gone.add(lib);
          report[lib.id] = LibraryScan(reached: false, missing: missing, error: error);
        }, onFile: (lib, path, trouble, error) {
          (report[lib.id] ??= LibraryScan()).files.add((path, trouble));
        });
        // what couldn't be read, a line per library (however many files: a share dropping part-way can be thousands)
        for (final lib in _folders) {
          if (report[lib.id] case final r? when r.summary != null) {
            AppLog.instance.warn('local', '"${lib.name}" (${lib.path}): ${r.summary}${r.examples}');
          }
        }
        lastScan = report;
        // read again: a "keep it" said while its folder wasn't there is done with
        if (_keptMissing.any((id) => !failed.contains(id))) {
          _keptMissing.removeWhere((id) => !failed.contains(id));
          await _saveKeptMissing();
        }
        toAsk.value = gone;
        // a library that couldn't be read keeps the books it had: a share out of reach (away from home, the NAS
        // restarting) emptied it until a later scan reached it (code review, 2026-10-25)
        for (final MapEntry(key: id, value: e) in store.books.entries) {
          if (failed.contains((e['library'] as Map?)?['id'])) fresh.putIfAbsent(id, () => e);
        }
        unreadable = failed;
        store.books
          ..clear()
          ..addAll(fresh);
        await store.save();
        changed.value++;
      } finally {
        scanning.value = null;
      }
    }();
    _scan = run;
    return run;
  }

  /// The libraries changed (Settings): kept, and scanned again.
  Future<void> setLibraries(List<LocalLibrary> libraries) async {
    _folders = List.of(libraries);
    await saveLibraries(libraries);
    final ids = {for (final l in libraries) l.id};
    store.books.removeWhere((_, e) => !ids.contains((e['library'] as Map?)?['id']));
    // a library renamed: its books carry the name
    for (final e in store.books.values) {
      final l = libraries.firstWhere((l) => l.id == (e['library'] as Map)['id']);
      e['library'] = {'id': l.id, 'name': l.name};
    }
    changed.value++;
    await rescan();
  }

  @override
  Future<Map<String, dynamic>?> me() async => {'email': 'local'};

  // ---- pages: straight out of the archive ------------------------------------------------------------------------------
  final Map<String, FileZip> _zips = {}; // the books open lately (their directories read once)

  Future<FileZip> _zip(String bookId) async {
    final have = _zips.remove(bookId);
    if (have != null) return _zips[bookId] = have; // (the newest last)
    final path = store.books[bookId]?['path'] as String?;
    if (path == null) throw NotAvailableOffline('This book');
    final z = await FileZip.open(Storage.instance.of(path), path);
    _zips[bookId] = z;
    while (_zips.length > 4) {
      _zips.remove(_zips.keys.first);
    }
    return z;
  }

  /// A comic's pages with their sizes (two pages up, a wide page is a spread, alone; a webtoon's strip is laid out
  /// by them): from its ComicInfo.xml when the scan found them there, else read from the start of each picture the
  /// first time the book is opened - and kept.
  @override
  Future<List<dynamic>> pages(String bookId) async {
    final e = store.books[bookId];
    final list = (e?['pages'] as List?) ?? const [];
    if (e != null && e['epub'] != true && list.any((p) => (p as Map)['width'] == null)) {
      try {
        await _measure(bookId, e);
      } catch (_) {
        // sizes not known: each page shown alone, as before
      }
    }
    return super.pages(bookId);
  }

  Future<void> _measure(String bookId, Map<String, dynamic> e) async {
    final zip = await _zip(bookId);
    final pages = [for (final p in e['pages'] as List) p as Map];
    final kept = ((e['inside'] as Map?)?['pages'] as List?) ?? const []; // (what a rescan keeps)
    var next = 0;
    Future<void> worker() async {
      while (next < pages.length) {
        final i = next++;
        final p = pages[i];
        if (p['width'] != null) continue;
        var size = imageSizeOf(await zip.head(p['file'] as String, 64 * 1024) ?? Uint8List(0));
        size ??= imageSizeOf(await zip.head(p['file'] as String, 1024 * 1024) ?? Uint8List(0)); // (a big header)
        if (size == null) continue;
        for (final m in [p, if (i < kept.length) kept[i] as Map]) {
          m['width'] = size.$1;
          m['height'] = size.$2;
        }
      }
    }

    await Future.wait([for (var k = 0; k < 8; k++) worker()]);
    await store.save();
  }

  @override
  Future<Uint8List> pageBytes(String bookId, int number) async {
    final page = ((store.books[bookId]?['pages'] as List?) ?? []).firstWhere((p) => p['number'] == number,
        orElse: () => throw NotAvailableOffline('Page $number of this book'));
    final bytes = await (await _zip(bookId)).read(page['file'] as String);
    if (bytes == null) throw NotAvailableOffline('Page $number of this book');
    return bytes;
  }

  // ---- EPUBs: their own file -----------------------------------------------------------------------------------------
  @override
  File? epubFile(String bookId) {
    final e = store.books[bookId];
    return e?['epub'] == true ? File(e!['path'] as String) : null;
  }

  /// No positions list (Komga's): the place is kept as it was read, the progress as a share of the book.
  @override
  Future<List<dynamic>> epubPositions(String bookId) async => const [];

  // ---- posters: each book's first page (an EPUB's cover), made small when first shown, and kept ---------------------
  String _thumbPath(String bookId) => '${_thumbs.path}${Platform.pathSeparator}$bookId.png';

  @override
  String bookThumb(String id) => _thumbPath(id);

  /// A series' poster: its first book's.
  @override
  String seriesThumb(String id) {
    final first = store.books.entries.where((e) => (e.value['book'] as Map)['seriesId'] == id).toList()
      ..sort((a, b) => ((a.value['book']['metadata']['numberSort'] as num?) ?? 0)
          .compareTo((b.value['book']['metadata']['numberSort'] as num?) ?? 0));
    return first.isEmpty ? '' : _thumbPath(first.first.key);
  }

  @override
  ImageProvider thumbImage(String ref) => _LocalThumb(ref, this);

  final Map<String, Future<bool>> _making = {}; // posters being made (one each, however many tiles ask)
  int _makingNow = 0;
  final List<Completer<void>> _waiting = []; // posters waiting for a turn (a few at a time: the files may be on a NAS)

  /// Makes the poster at [path] (a book's) if it isn't there yet. False: none could be made.
  Future<bool> thumbAt(String path) => _making[path] ??= () async {
        try {
          if (await File(path).exists()) return true;
          final id = path.split(Platform.pathSeparator).last.replaceAll('.png', '');
          final e = store.books[id];
          final cover = e?['cover'] as String?;
          if (e == null || cover == null) return false;
          if (_makingNow >= 3) {
            final turn = Completer<void>();
            _waiting.add(turn);
            await turn.future;
          }
          _makingNow++;
          try {
            final Uint8List? bytes = e['epub'] == true
                ? Zip(await Storage.instance.of(e['path'] as String).readAll(e['path'] as String)).read(cover)
                : await (await _zip(id)).read(cover);
            if (bytes == null) return false;
            final codec = await ui.instantiateImageCodec(bytes, targetWidth: 320);
            final frame = await codec.getNextFrame();
            final png = await frame.image.toByteData(format: ui.ImageByteFormat.png);
            frame.image.dispose();
            codec.dispose();
            if (png == null) return false;
            await _thumbs.create(recursive: true);
            await File(path).writeAsBytes(png.buffer.asUint8List(png.offsetInBytes, png.lengthInBytes));
            return true;
          } finally {
            _makingNow--;
            if (_waiting.isNotEmpty) _waiting.removeAt(0).complete();
          }
        } catch (_) {
          return false;
        } finally {
          unawaited(Future(() => _making.remove(path)));
        }
      }();

  // ---- no server: settings stay on this device, nothing to sync -----------------------------------------------------
  @override
  Future<Map<String, dynamic>> clientSettings() async => const {};
  @override
  Future<void> putClientSetting(String key, String value) async {}
}

/// What a scan couldn't read of one library: the whole library ([reached] false - out of reach, or [missing]: not
/// there, the place it was in answering), or some of its files, each with why.
class LibraryScan {
  LibraryScan({this.reached = true, this.missing = false, this.error});
  final bool reached, missing;
  final Object? error; // (the library's, when it wasn't reached)
  final List<(String, FileTrouble)> files = [];

  int count(FileTrouble t) => files.where((f) => f.$2 == t).length;

  /// The files left out (damaged, or gone since the listing): their paths.
  List<String> get leftOut => [for (final f in files) if (f.$2 != FileTrouble.noAnswer) f.$1];

  /// In a line ("not found on the last scan - …"; "3 files couldn't be read - 2 damaged, left out; …"), or null:
  /// nothing to say.
  String? get summary {
    if (!reached) {
      return missing
          ? 'not found on the last scan (it looks deleted) - its books are from the scan before'
          : "couldn't be reached on the last scan - its books are from the scan before";
    }
    if (files.isEmpty) return null;
    final parts = [
      if (count(FileTrouble.noAnswer) case final k when k > 0) "$k didn't answer (kept from the scan before)",
      if (count(FileTrouble.damaged) case final k when k > 0) '$k damaged or not readable yet (left out)',
      if (count(FileTrouble.gone) case final k when k > 0) '$k gone since the folder was listed (left out)',
    ];
    return '${files.length} file${files.length == 1 ? '' : 's'} couldn\'t be read - ${parts.join('; ')}';
  }

  /// For the log: up to 5 of the files left out, by name (": a.cbz, b.cbz and 3 more"); '' if none.
  String get examples {
    final names = [for (final p in leftOut) p.split(RegExp(r'[\\/]')).last];
    if (names.isEmpty) return '';
    return ': ${names.take(5).join(', ')}${names.length > 5 ? ' and ${names.length - 5} more' : ''}';
  }
}

/// A local book's poster: made (from the book) the first time it's shown, then read from its file.
@immutable
class _LocalThumb extends ImageProvider<_LocalThumb> {
  const _LocalThumb(this.path, this.api);
  final String path;
  final FolderKomga api;

  @override
  Future<_LocalThumb> obtainKey(ImageConfiguration configuration) => SynchronousFuture(this);

  @override
  ImageStreamCompleter loadImage(_LocalThumb key, ImageDecoderCallback decode) =>
      MultiFrameImageStreamCompleter(codec: _load(decode), scale: 1);

  Future<ui.Codec> _load(ImageDecoderCallback decode) async {
    if (path.isEmpty || !await api.thumbAt(path)) throw StateError('no poster for $path');
    return decode(await ui.ImmutableBuffer.fromUint8List(await File(path).readAsBytes()));
  }

  @override
  bool operator ==(Object other) => other is _LocalThumb && other.path == path;
  @override
  int get hashCode => path.hashCode;
}
