import 'dart:async';
import 'dart:typed_data';

import 'package:clock/clock.dart';
import 'package:flutter/painting.dart';

import 'local/book_names.dart';
import 'local/file_zip.dart';
import 'local/library_fs.dart';
import 'local/local_scan.dart';
import 'local/local_source.dart';
import 'local/local_store.dart';
import 'offline/catalogue_source.dart';

/// A book file opened from outside the app - Windows' Open with, Android's Open with and Share, iOS's Open in (user,
/// 2026-10-27: "it opens straight into the reader, bypassing the library. it does not ingest or download anything").
/// The reader's source for that one book, read straight from its file: no progress kept (user: never), no copy, in
/// no list. [close]d when the reader closes.
class OpenedFile extends CatalogueSource {
  OpenedFile._(this.path, this.loose, this._fs, this._archive, this._onClose);

  /// Opens the book at [path] ([name]: the file's name, when the path doesn't end in it - Android hands a file over
  /// as /proc/self/fd/N). [onClose]: what the platform holds open for it let go (Android's file, iOS's access).
  /// [fs]: where it's read from (tests give their own; else this device's files).
  /// Throws if it isn't a comic or an eBook this app reads.
  static Future<OpenedFile> open(String path, {String? name, void Function()? onClose, LibraryFs? fs}) async {
    final files = fs ?? LocalFs();
    try {
      final file = await files.open(path);
      final size = await file.length();
      await file.close();
      final book = await readLooseBook(files, FsEntry(path, size, clock.now()), fileName: name);
      final archive = book.epub ? null : await ComicArchive.open(files, path);
      return OpenedFile._(path, book, files, archive, onClose);
    } catch (_) {
      onClose?.call();
      rethrow;
    }
  }

  final String path;
  final LocalBook loose;
  final LibraryFs _fs;
  final ComicArchive? _archive; // a comic's, open while it's read
  final void Function()? _onClose;
  List<int>? _sizes;
  bool _closed = false;

  /// The book as Komga would list it (what the reader opens).
  Map<String, dynamic> get bookJson => entries[loose.id]!['book'] as Map<String, dynamic>;

  @override
  String get baseUrl => 'opened file';

  @override
  late final Map<String, Map<String, dynamic>> entries = () {
    final series = LocalSeries(id: loose.seriesId, libraryId: loose.libraryId, name: loose.title, oneshot: true);
    return {
      loose.id: {
        'book': LocalSource.bookJson(loose, series), 'series': LocalSource.seriesJson(series),
        'library': {'id': loose.libraryId, 'name': ''}, 'readLists': const [], 'collections': const [],
        'state': 'done',
      },
    };
  }();

  @override
  Map<String, dynamic>? readProgressOf(String bookId) => null; // (never kept)

  @override
  void close() {
    if (_closed) return;
    _closed = true;
    unawaited(_archive?.close().catchError((Object _) {}).whenComplete(() => _onClose?.call()) ??
        Future.sync(() => _onClose?.call()));
  }

  // ---- the pages: straight out of the file --------------------------------------------------------------------------
  @override
  Future<List<dynamic>> pages(String bookId) async {
    final archive = _archive;
    if (archive == null) return const [];
    final names = comicPages(archive.names);
    final sizes = _sizes ??= await LocalSource.measurePages(archive, names);
    return [
      for (final (i, n) in names.indexed)
        {
          'number': i + 1, 'mediaType': imageType(n),
          if (sizes[2 * i] > 0) ...{'width': sizes[2 * i], 'height': sizes[2 * i + 1]},
        },
    ];
  }

  @override
  Future<Uint8List> pageBytes(String bookId, int number) async {
    final archive = _archive;
    final names = archive == null ? const <String>[] : comicPages(archive.names);
    if (number < 1 || number > names.length) throw FormatException('No page $number');
    final bytes = await archive!.read(names[number - 1]);
    if (bytes == null) throw FormatException('No page $number');
    return bytes;
  }

  @override
  Future<Uint8List> pageThumbBytes(String bookId, int number) => pageBytes(bookId, number);

  /// An EPUB's whole file (the reader reads it from this).
  Future<Uint8List> epubBytes() => readWhole(_fs, path);

  @override
  Future<Uint8List> bookFileBytes(String bookId) => epubBytes();

  // ---- nothing kept: progress, marks, places ------------------------------------------------------------------------
  @override
  Future<void> setProgress(String bookId, int page, {bool completed = false}) async {}
  @override
  Future<void> markRead(String bookId) async {}
  @override
  Future<void> markUnread(String bookId) async {}
  @override
  Future<List<dynamic>> epubPositions(String bookId) async => const [];
  @override
  Future<Map<String, dynamic>?> epubProgression(String bookId) async => null;
  @override
  Future<void> setEpubProgression(String bookId, Map<String, dynamic> progression) async {}

  // ---- no posters, no account, nothing only Komga has ---------------------------------------------------------------
  @override
  String bookThumb(String id) => '';
  @override
  String seriesThumb(String id) => '';
  @override
  String readListThumb(String id) => '';
  @override
  String collectionThumb(String id) => '';
  @override
  ImageProvider thumbImage(String ref) => MemoryImage(_blank);
  static final _blank = Uint8List.fromList(const [
    0x47, 0x49, 0x46, 0x38, 0x39, 0x61, 1, 0, 1, 0, 0x80, 0, 0, 0, 0, 0, 0xff, 0xff, 0xff, 0x21, 0xf9, 4, 1, 0, 0, 0,
    0, 0x2c, 0, 0, 0, 0, 1, 0, 1, 0, 0, 2, 2, 0x44, 1, 0, 0x3b, // a 1x1 transparent GIF
  ]);
  @override
  Future<Uint8List?> thumbBytes(String url) async => null;
  @override
  Future<Map<String, dynamic>?> me() async => null;
  @override
  Future<List<dynamic>> libraries() async => const [];
  @override
  Future<List<dynamic>> visibleLibraries({bool kept = false}) async => const [];
  @override
  Future<Map<String, dynamic>> clientSettings() async => const {};
  @override
  Future<void> putClientSetting(String key, String value) async {}
  @override
  Future<Map<String, dynamic>?> epubManifest(String bookId) async => throw NeedsKomga('This book');
  @override
  Future<Uint8List> epubResource(String bookId, String path) async => throw NeedsKomga('This book');
  @override
  Future<List<dynamic>> bookReadLists(String bookId) async => const [];
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
