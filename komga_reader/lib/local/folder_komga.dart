import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:shared_preferences/shared_preferences.dart';


import '../epub/source.dart' show Zip;
import '../offline/offline_komga.dart';
import '../offline/store.dart';
import 'file_zip.dart';
import 'folder_scan.dart';

/// Local mode (experimental/sources): Komga as if it were a few folders on this device - no server at all. The
/// libraries are folders ([LocalLibrary]), scanned into entries shaped as downloads' ([scanLibraries]), and answered
/// as the offline source answers for downloads: browsing, filters, sort, reading progress (kept on the device). Pages
/// come out of the CBZ files where they are; an EPUB is opened from its own file.
class FolderKomga extends OfflineKomga {
  FolderKomga._(super.store, this.folders, this._thumbs) : super(baseUrl: address);

  /// Its "server address" (saved as the server, so the app knows to start in local mode).
  static const address = 'local';

  /// The libraries: folders.
  final List<LocalLibrary> folders;
  final Directory _thumbs;

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

  /// [libraries] scanned, with the progress kept in [dataDir] (local\ in the app's storage) - the posters made for
  /// any book that hasn't one yet.
  static Future<FolderKomga> open(List<LocalLibrary> libraries, {required Directory dataDir}) async {
    final store = OfflineStore(dataDir);
    await dataDir.create(recursive: true);
    await store.load(); // the progress kept here
    final scanned = await scanLibraries(libraries);
    store.books
      ..clear()
      ..addAll(scanned);
    final api = FolderKomga._(store, libraries, Directory('${dataDir.path}${Platform.pathSeparator}thumbs'));
    await api._makeThumbs();
    return api;
  }

  /// No book in any of the libraries (a folder typed wrong, or empty).
  bool get isEmpty => store.books.isEmpty;

  @override
  Future<Map<String, dynamic>?> me() async => {'email': 'local'};

  // ---- pages: straight out of the archive ------------------------------------------------------------------------------
  final Map<String, FileZip> _zips = {}; // the books open lately (their directories read once)

  Future<FileZip> _zip(String bookId) async {
    final have = _zips.remove(bookId);
    if (have != null) return _zips[bookId] = have; // (the newest last)
    final path = store.books[bookId]?['path'] as String?;
    if (path == null) throw NotAvailableOffline('This book');
    final z = await FileZip.open(File(path));
    _zips[bookId] = z;
    while (_zips.length > 4) {
      _zips.remove(_zips.keys.first);
    }
    return z;
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

  // ---- posters: each book's first page (an EPUB's cover), made small once and kept ---------------------------------
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

  Future<void> _makeThumbs() async {
    await _thumbs.create(recursive: true);
    for (final e in store.books.entries) {
      final f = File(_thumbPath(e.key));
      if (await f.exists()) continue;
      try {
        final cover = e.value['cover'] as String?;
        if (cover == null) continue;
        final Uint8List? bytes;
        if (e.value['epub'] == true) {
          bytes = Zip(await File(e.value['path'] as String).readAsBytes()).read(cover);
        } else {
          bytes = await (await _zip(e.key)).read(cover);
        }
        if (bytes == null) continue;
        final codec = await ui.instantiateImageCodec(bytes, targetWidth: 320);
        final frame = await codec.getNextFrame();
        final png = await frame.image.toByteData(format: ui.ImageByteFormat.png);
        frame.image.dispose();
        codec.dispose();
        if (png != null) await f.writeAsBytes(png.buffer.asUint8List(png.offsetInBytes, png.lengthInBytes));
      } catch (_) {
        // no poster: the tile shows its placeholder
      }
    }
  }

  // ---- no server: settings stay on this device, nothing to sync -----------------------------------------------------
  @override
  Future<Map<String, dynamic>> clientSettings() async => const {};
  @override
  Future<void> putClientSetting(String key, String value) async {}
}
