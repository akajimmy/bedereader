import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/painting.dart' show FileImage, ImageProvider;

import '../api.dart';
import '../epub/progress.dart' show komgaEpubPage;
import 'catalogue_source.dart';
import 'downloads.dart';
import 'store.dart';

export 'catalogue_source.dart' show NotAvailableOffline;

/// Komga, as if only the downloaded books existed (user's 1.1 decision): the same calls the screens already make,
/// answered from the [OfflineStore], so libraries / series / read lists / collections / books show the downloaded
/// part of the tree. Reading progress goes to the store's queue; server-only actions throw [NotAvailableOffline];
/// what only Komga can give (settings sync, an EPUB's manifest or file, a poster by its address) throws
/// [KomgaUnreachable], so it's asked again once back online.
///
/// A [BookSource] of its own, not a Komga that can't connect (it was one, with an HTTP client that always failed:
/// what it didn't answer itself went to it); each question is answered from one [Catalogue] of the downloads.
class DownloadsSource extends CatalogueSource {
  DownloadsSource(this.store, {this.baseUrl = 'offline'});
  final OfflineStore store;

  /// The server the downloads came from (what they're kept under) - 'offline' when not known.
  @override
  final String baseUrl;

  @override
  Map<String, Map<String, dynamic>> get entries => store.books;

  @override
  Map<String, dynamic>? readProgressOf(String bookId) => store.readProgressOf(bookId);

  // ---- account / libraries -------------------------------------------------------------------------------------------
  @override
  Future<Map<String, dynamic>?> me() async => {'email': 'offline'};

  @override
  void close() {} // (nothing held open)

  // ---- pages and posters: files on disk -------------------------------------------------------------------------------
  @override
  Future<List<dynamic>> pages(String bookId) async => [
        for (final p in (store.books[bookId]?['pages'] as List?) ?? []) Downloads.listed(p as Map),
      ];

  @override
  Future<Uint8List> pageBytes(String bookId, int number) async {
    final page = ((store.books[bookId]?['pages'] as List?) ?? []).firstWhere((p) => p['number'] == number,
        orElse: () => throw NotAvailableOffline('Page $number of this book'));
    return store.file('$bookId/${page['file']}').readAsBytes();
  }

  /// No thumbnails are downloaded: the page itself (the reader decodes it small).
  @override
  Future<Uint8List> pageThumbBytes(String bookId, int number) => pageBytes(bookId, number);

  @override
  String bookThumb(String id) => store.file('$id/thumb.jpg').path;
  @override
  String seriesThumb(String id) => store.file('series/$id.jpg').path;
  @override
  String readListThumb(String id) => store.file('readlists/$id.jpg').path;
  @override
  String collectionThumb(String id) => store.file('collections/$id.jpg').path;
  @override
  ImageProvider thumbImage(String ref) => FileImage(File(ref));

  // ---- reading progress: kept on the device, sent to Komga later ------------------------------------------------------
  @override
  Future<void> setProgress(String bookId, int page, {bool completed = false}) async {
    await store.setProgress(bookId, page: page, completed: completed);
    if (completed) Downloads.instance.bookFinished(bookId); // Delete once read (the progress stays queued for Komga)
  }

  // ---- EPUB books: the downloaded file, Komga's positions, the place saved here ----------------------------------------
  /// The downloaded EPUB file of [bookId] (null if it isn't one, or isn't downloaded whole).
  File? epubFile(String bookId) {
    final e = store.books[bookId];
    final f = e?['epubFile'];
    return f is String && e?['state'] == 'done' ? store.file('$bookId/$f') : null;
  }

  @override
  Future<List<dynamic>> epubPositions(String bookId) async =>
      (store.books[bookId]?['positions'] as List?) ?? (throw NotAvailableOffline('This book'));

  /// The place saved on this device while offline (null: the read progress's page through the positions).
  @override
  Future<Map<String, dynamic>?> epubProgression(String bookId) async => store.placeOf(bookId);

  /// Kept on the device: the exact place (for reopening here; sent to Komga as it is when back online), and the read
  /// progress page Komga makes of it - how far through the book times Komga's page count, not the position number
  /// (taken for one, page 233 of a 305-page count would have shown the book three quarters read).
  /// Both in the progress record, written to the small progress file only (it rewrote the whole index each time -
  /// EPUB review S7); always queued, even when no page can be worked out (the place itself goes to Komga - S10).
  @override
  Future<void> setEpubProgression(String bookId, Map<String, dynamic> progression) async {
    final entry = store.books[bookId];
    if (entry == null) throw NotAvailableOffline('This book');
    final at = (progression['locator'] as Map?)?['locations'] as Map?;
    final page = komgaEpubPage((at?['totalProgression'] as num?)?.toDouble(), _pagesCount(entry));
    await store.setProgress(bookId, page: page, completed: false, place: progression);
  }

  static int? _pagesCount(Map entry) => ((entry['book'] as Map?)?['media'] as Map?)?['pagesCount'] as int?;

  @override
  Future<void> markRead(String bookId) async {
    final entry = store.books[bookId];
    // an EPUB: Komga's page count for it (not its positions); a comic: its pages
    final pages = entry?['positions'] != null
        ? (_pagesCount(entry!) ?? (entry['positions'] as List).length)
        : (entry?['pages'] as List?)?.length;
    await store.setProgress(bookId, page: pages, completed: true);
    Downloads.instance.bookFinished(bookId);
  }

  @override
  Future<void> markUnread(String bookId) => store.setProgress(bookId, completed: false, clear: true);
  // ---- needs the server --------------------------------------------------------------------------------------------------
  // (only Komga has these: asked again once it's back)
  @override
  Future<Map<String, dynamic>> clientSettings() async => throw KomgaUnreachable(baseUrl);
  @override
  Future<void> putClientSetting(String key, String value) async => throw KomgaUnreachable(baseUrl);
  @override
  Future<Map<String, dynamic>?> epubManifest(String bookId) async => throw KomgaUnreachable(baseUrl);
  @override
  Future<Uint8List> epubResource(String bookId, String href) async => throw KomgaUnreachable(baseUrl);
  @override
  Future<Uint8List> bookFileBytes(String bookId) async => throw KomgaUnreachable(baseUrl);
  @override
  Future<Uint8List?> thumbBytes(String url) async => throw KomgaUnreachable(baseUrl);
  @override
  Future<List<dynamic>> bookReadLists(String bookId) async => throw KomgaUnreachable(baseUrl);
  @override
  Future<List<dynamic>> seriesCollections(String seriesId) async => throw KomgaUnreachable(baseUrl);
  @override
  Future<void> deleteBookFile(String bookId) async => throw NotAvailableOffline('Deleting a book');
  @override
  Future<void> renameReadList(String id, String name) async => throw NotAvailableOffline('Renaming a read list');
  @override
  Future<void> renameCollection(String id, String name) async => throw NotAvailableOffline('Renaming a collection');
  @override
  Future<void> deleteSeriesFiles(String seriesId) async => throw NotAvailableOffline('Deleting a series');
}
