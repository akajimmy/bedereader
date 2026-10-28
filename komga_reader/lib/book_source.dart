import 'dart:typed_data';

import 'package:flutter/painting.dart' show ImageProvider;

import 'view_filter.dart';

/// Where the books come from, as the screens see it: Komga's server (lib/api.dart), and - offline - the downloads
/// (lib/offline/downloads_source.dart). What only talking to Komga over HTTP needs (its API key, headers, page URLs,
/// making a key, the reachability check) stays on the Komga class: sign-in, the connection and the app's start hold
/// one.
///
/// Lists come back as Komga's JSON pages ({content, totalElements, last}) and items as Komga's JSON for them, whatever
/// the source. A source that can't do what only a server can (its settings, an EPUB's manifest, the book's file)
/// throws as Komga does when it can't be reached (KomgaUnreachable: asked again later); one that can't do what only
/// the server's owner may (deleting files, renaming) throws NotAvailableOffline.
abstract interface class BookSource {
  /// The server it is, or stands in for (the downloads: the server their books came from) - what downloads, the error
  /// messages and the reader's EPUB cache are kept under.
  String get baseUrl;

  /// Done with for good (a failed sign-in, signing out): what it holds open is let go once what's on its way is done.
  void close();

  /// The signed-in account.
  Future<Map<String, dynamic>?> me();

  Future<List<dynamic>> libraries();

  /// The library list, kept: fetched once, then again after [forgetLibraries] (the app back in the foreground) or a
  /// fresh fetch ([visibleLibraries] - Home's load and Refresh). A failed fetch isn't kept.
  Future<List<dynamic>> keptLibraries();

  /// The kept library list is out of date (the app back in the foreground): the next use fetches it again.
  void forgetLibraries();

  /// A library's name, for breadcrumbs ("Ongoing › Absolute Flash"), from the kept list; null if it can't be had.
  Future<String?> libraryName(String? id);

  /// The libraries this device shows (Settings > Library & Home): Home, the library picker. Fetched fresh, and kept
  /// for the side menu ([kept]: the kept list, fetched only if there's none).
  Future<List<dynamic>> visibleLibraries({bool kept = false});

  Future<Map<String, dynamic>> series(
      {String? libraryId,
      String? collectionId,
      List<String>? readStatus,
      String sort = 'metadata.titleSort,asc',
      int page = 0,
      int size = 60});

  Future<Map<String, dynamic>> books(
      {String? libraryId,
      List<String>? readStatus,
      String sort = 'metadata.releaseDate,desc',
      int page = 0,
      int size = 60});

  /// Books you are part-way through, most recently read first.
  Future<Map<String, dynamic>> inProgress({String? libraryId, int size = 30});

  /// "On deck": the next unread book of series you have been reading.
  Future<Map<String, dynamic>> onDeck({String? libraryId, int size = 30});

  Future<Map<String, dynamic>> seriesBooks(String seriesId,
      {List<String>? readStatus, String sort = 'metadata.numberSort,asc', int page = 0, int size = 500});

  Future<Map<String, dynamic>> collections({String? libraryId, int page = 0, int size = 200});

  Future<Map<String, dynamic>> readLists({String? libraryId, int page = 0, int size = 200});

  Future<Map<String, dynamic>> searchSeries(String query, {String? libraryId, int size = 30});

  Future<Map<String, dynamic>> searchBooks(String query, {String? libraryId, int size = 30});

  /// The books of any of [seriesIds], by number, in one go (Search's Books row: a series found brings its books
  /// along).
  Future<Map<String, dynamic>> booksOfSeries(List<String> seriesIds, {int size = 300});

  Future<Map<String, dynamic>> searchReadLists(String query, {String? libraryId, int size = 30});

  Future<Map<String, dynamic>> searchCollections(String query, {String? libraryId, int size = 30});

  /// Books of a read list in the list's own order, optionally only unread / in progress / read.
  Future<Map<String, dynamic>> readListBooks(String readListId,
      {List<String>? readStatus, int page = 0, int size = 1000});

  /// A view's series with its read filter and filters: one library ([libraryId]; null = all shown libraries) or a
  /// collection. With no filter it's [series].
  Future<Map<String, dynamic>> filteredSeries(
      {String? libraryId,
      String? collectionId,
      ReadFilter read = ReadFilter.all,
      ViewFilter filter = ViewFilter.none,
      String sort = 'metadata.titleSort,asc',
      int page = 0,
      int size = 60});

  /// A view's books with its read filter and filters: a series' ([seriesId]), a read list's ([readListId]) or a
  /// library's (else; null = all shown libraries). The series filters (publisher, genre, status) don't apply to books.
  /// No filter: [seriesBooks], [readListBooks] (in list order: no [sort]) or [books]. [sort] / [size] null: that
  /// view's usual ones.
  Future<Map<String, dynamic>> filteredBooks(
      {String? libraryId,
      String? seriesId,
      String? readListId,
      ReadFilter read = ReadFilter.all,
      ViewFilter filter = ViewFilter.none,
      String? sort,
      int page = 0,
      int? size});

  /// The names of the authors in [roles] (any of them: Artist is penciller, inker or cover) in the view, A -> Z, each
  /// once; [search]: names containing it.
  Future<List<String>> authorNames(List<String> roles,
      {String? search, String? libraryId, String? collectionId, String? seriesId, String? readListId, int size = 1000});

  /// The publishers of the series in a library (null = all shown) or a collection, A -> Z.
  Future<List<String>> publishers({String? libraryId, String? collectionId});

  /// The genres of the series in a library (null = all shown) or a collection, A -> Z.
  Future<List<String>> genres({String? libraryId, String? collectionId});

  /// Whether a library ([libraryId]; null = all shown), a series or a read list holds comics, eBooks or both - for the
  /// filter panel's words (Writer / Author) and whether it offers Artist. Can't be had: [ViewKind.mixed].
  Future<ViewKind> viewKind({String? libraryId, String? seriesId, String? readListId});

  Future<Map<String, dynamic>?> oneSeries(String id);

  Future<Map<String, dynamic>?> readList(String id);

  /// Renames a read list (user, 2026-10-18) - Komga: admin accounts only, and not to a name another list has.
  Future<void> renameReadList(String id, String name);

  /// Renames a collection, as [renameReadList].
  Future<void> renameCollection(String id, String name);

  Future<Map<String, dynamic>?> book(String id);

  /// A collection's series in the collection's own order (as arranged for an ordered collection, by title otherwise),
  /// optionally only unread / read; the shown libraries only, when some are hidden.
  Future<Map<String, dynamic>> collectionSeries(String collectionId,
      {List<String>? readStatus, int page = 0, int size = 60});

  /// A read list's books sorted by a book field ([sort], e.g. "metadata.releaseDate,asc") instead of the list's
  /// order.
  Future<Map<String, dynamic>> readListBooksSorted(String readListId, String sort,
      {List<String>? readStatus, int page = 0, int size = 500});

  /// A comic's pages: {number, mediaType, width?, height?} each. Komga's: a book downloaded on this device is read
  /// from the device, online too (user, 2026-10-12).
  Future<List<dynamic>> pages(String bookId);

  String seriesThumb(String id);

  String bookThumb(String id);

  String readListThumb(String id);

  String collectionThumb(String id);

  /// The image for a thumbnail reference from the methods above. Screens go through this rather than building
  /// network images themselves, so a source can hand back images from disk.
  ImageProvider thumbImage(String ref);

  Future<void> setProgress(String bookId, int page, {bool completed = false});

  Future<void> markRead(String bookId);

  Future<void> markUnread(String bookId);

  Future<void> markSeriesRead(String seriesId);

  Future<void> markSeriesUnread(String seriesId);

  Future<Map<String, dynamic>?> nextBook(String bookId, {String? readListId});

  Future<Map<String, dynamic>?> previousBook(String bookId, {String? readListId});

  /// The settings this account keeps on the server (reader settings, pins, On deck hidden...), all of them.
  Future<Map<String, dynamic>> clientSettings();

  Future<void> putClientSetting(String key, String value);

  /// An EPUB's Readium manifest (reading order, table of contents).
  Future<Map<String, dynamic>?> epubManifest(String bookId);

  /// One file of an EPUB (a chapter, a stylesheet, a picture, a font) by its path inside the book.
  Future<Uint8List> epubResource(String bookId, String path);

  /// Where reading stopped in an EPUB (Readium's progression: a locator - chapter file, how far in it - with the
  /// device and time); null if never read.
  Future<Map<String, dynamic>?> epubProgression(String bookId);

  /// Saves where reading stopped in an EPUB, and the book's read progress made of it (page = how far through the
  /// book x its page count for it - see epub/progress.dart komgaEpubPage).
  Future<void> setEpubProgression(String bookId, Map<String, dynamic> progression);

  /// The book's own file (an EPUB, for reading offline).
  Future<Uint8List> bookFileBytes(String bookId);

  /// The book's positions (Readium): roughly one per screenful, numbered from 1.
  Future<List<dynamic>> epubPositions(String bookId);

  Future<Uint8List> pageBytes(String bookId, int number);

  /// A small picture of a page - the reader's slider previews. Can be slow (made from the book as it's asked for).
  Future<Uint8List> pageThumbBytes(String bookId, int number);

  Future<List<dynamic>> bookReadLists(String bookId);

  Future<List<dynamic>> seriesCollections(String seriesId);

  /// A poster's image bytes (null if it has none).
  Future<Uint8List?> thumbBytes(String url);

  Future<void> deleteBookFile(String bookId);

  // ---- metadata editing (user, 2026-10-27; reports-27-metadata-plan.md)
  /// Whether a book's or a series' ([id]) metadata can be edited here: Komga - an admin account (Komga's rule), not
  /// offline; a local or network book - its library's files.
  Future<bool> canEditMetadata(String id);

  /// Saves [changes] to a book's metadata, by Komga's names: title, number, numberSort, releaseDate ('yyyy-MM-dd', or
  /// null for none). A local or network book also takes seriesName (its series, an existing one's name or a new one).
  Future<void> editBookMetadata(String bookId, Map<String, Object?> changes);

  /// Saves [changes] to a series' metadata, by Komga's names: title, titleSort, readingDirection (LEFT_TO_RIGHT,
  /// RIGHT_TO_LEFT, VERTICAL, WEBTOON), status (ONGOING, ENDED, HIATUS, ABANDONED), publisher.
  Future<void> editSeriesMetadata(String seriesId, Map<String, Object?> changes);

  Future<void> deleteSeriesFiles(String seriesId);
}
