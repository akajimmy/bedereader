import 'dart:typed_data';

import 'package:flutter/painting.dart' show ImageProvider;

import 'api.dart' show ReadFilter;
import 'view_filter.dart';

/// Where the books come from, as the screens see it: Komga's server (lib/api.dart), and - offline - the downloads
/// (lib/offline/downloads_source.dart). What only talking to Komga over HTTP needs (its API key, headers, page URLs,
/// making a key, the reachability check) stays on [Komga]: sign-in, the connection and the app's start hold one.
/// A source that can't do something only Komga does (deleting files, renaming, its settings) answers as the offline
/// source does: not available.
abstract interface class BookSource {
  /// The server it is, or stands in for (the offline source: the server its books came from) - what downloads, the
  /// error messages and the reader's EPUB cache are kept under.
  String get baseUrl;

  /// This connection is dropped for good (a failed sign-in, signing out): its HTTP client - and the sockets it keeps
  /// open - is closed once the requests on their way have finished (code review 2026-10-05, #50: none was ever
  /// closed). Anything asked after that fails as unreachable.
  void close();

  /// The signed-in account.
  Future<Map<String, dynamic>?> me();

  Future<List<dynamic>> libraries();

  /// The library list, kept: fetched once, then again after [forgetLibraries] (the app back in the foreground) or a
  /// fresh fetch ([visibleLibraries] - Home's load and Refresh). A failed fetch isn't kept (asked again next time).
  /// Libraries change rarely; the side menu asked for them on every opening (code review 2026-10-05, #43).
  Future<List<dynamic>> keptLibraries();

  /// The kept library list is out of date (the app back in the foreground): the next use fetches it again.
  void forgetLibraries();

  /// A library's name, for breadcrumbs ("Ongoing › Absolute Flash"), from the kept list; null if it can't be had
  /// (tried again next time).
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

  /// Komga's "On deck": the next unread book of series you have been reading.
  Future<Map<String, dynamic>> onDeck({String? libraryId, int size = 30});

  Future<Map<String, dynamic>> seriesBooks(String seriesId,
      {List<String>? readStatus, String sort = 'metadata.numberSort,asc', int page = 0, int size = 500});

  Future<Map<String, dynamic>> collections({String? libraryId, int page = 0, int size = 200});

  Future<Map<String, dynamic>> readLists({String? libraryId, int page = 0, int size = 200});

  Future<Map<String, dynamic>> searchSeries(String query, {String? libraryId, int size = 30});

  Future<Map<String, dynamic>> searchBooks(String query, {String? libraryId, int size = 30});

  /// The books of any of [seriesIds], by number - one request, however many series (Search's Books row: a series
  /// found brings its books along - bug #15).
  Future<Map<String, dynamic>> booksOfSeries(List<String> seriesIds, {int size = 300});

  Future<Map<String, dynamic>> searchReadLists(String query, {String? libraryId, int size = 30});

  Future<Map<String, dynamic>> searchCollections(String query, {String? libraryId, int size = 30});

  /// Books of a read list in the list's own order, optionally only unread / in progress / read.
  Future<Map<String, dynamic>> readListBooks(String readListId,
      {List<String>? readStatus, int page = 0, int size = 1000});

  /// A view's series with its read filter and filters: one library ([libraryId]; null = all shown libraries) or a
  /// collection. With no filter (or only book-less ones) this is [series] - the same request as before filters existed;
  /// with one, Komga's search (POST /api/v1/series/list) with all of them as one condition.
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
  /// No filter: the same request as before filters existed - [seriesBooks], [readListBooks] (in list order: no
  /// [sort]) or [books]. [sort] / [size] null: that view's usual ones.
  /// With a filter (or a read list sorted otherwise than in list order): Komga's search, POST /api/v1/books/list.
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
  /// once; [search]: names containing it. Komga gives no book counts here.
  Future<List<String>> authorNames(List<String> roles,
      {String? search, String? libraryId, String? collectionId, String? seriesId, String? readListId, int size = 1000});

  /// The publishers of the series in a library (null = all shown) or a collection, A -> Z.
  Future<List<String>> publishers({String? libraryId, String? collectionId});

  /// The genres of the series in a library (null = all shown) or a collection, A -> Z.
  Future<List<String>> genres({String? libraryId, String? collectionId});

  /// Whether a library ([libraryId]; null = all shown), a series or a read list holds comics, eBooks or both - for the
  /// filter panel's words (Writer / Author) and whether it offers Artist. Komga keeps no kind per library, so it's
  /// asked once per view and kept while this connection lasts: two one-book searches (EPUB, and not EPUB), whose
  /// totals say which there are. Can't be had: [ViewKind.mixed] (asked again next time).
  Future<ViewKind> viewKind({String? libraryId, String? seriesId, String? readListId});

  Future<Map<String, dynamic>?> oneSeries(String id);

  Future<Map<String, dynamic>?> readList(String id);

  /// Renames a read list (user, 2026-10-18). Komga allows it to admin accounts only (403 otherwise), and answers 400
  /// to a name another read list already has.
  Future<void> renameReadList(String id, String name);

  /// Renames a collection - as [renameReadList] (admin accounts only; 400 for a name taken).
  Future<void> renameCollection(String id, String name);

  Future<Map<String, dynamic>?> book(String id);

  /// A collection's series in the collection's own order (Komga's: as arranged for an ordered collection, by title
  /// otherwise), optionally only unread / read; the shown libraries only, when some are hidden.
  Future<Map<String, dynamic>> collectionSeries(String collectionId,
      {List<String>? readStatus, int page = 0, int size = 60});

  /// A read list's books sorted by a book field ([sort], e.g. "metadata.releaseDate,asc") instead of the list's
  /// order: Komga's book search with the list as the condition.
  Future<Map<String, dynamic>> readListBooksSorted(String readListId, String sort,
      {List<String>? readStatus, int page = 0, int size = 500});

  /// A book downloaded on this device is read from the device, online too (user, 2026-10-12: "use a downloaded
  /// version of a comic if present, even if online") - its page list and pages ([localPages]: the downloads, for
  /// this server); anything else asks Komga.
  Future<List<dynamic>> pages(String bookId);

  String seriesThumb(String id);

  String bookThumb(String id);

  String readListThumb(String id);

  String collectionThumb(String id);

  /// The image for a thumbnail reference from the methods above. Screens go through this rather than building
  /// network images themselves, so the offline source can hand back images from disk (lib/offline/).
  ImageProvider thumbImage(String ref);

  Future<void> setProgress(String bookId, int page, {bool completed = false});

  Future<void> markRead(String bookId);

  Future<void> markUnread(String bookId);

  Future<void> markSeriesRead(String seriesId);

  Future<void> markSeriesUnread(String seriesId);

  Future<Map<String, dynamic>?> nextBook(String bookId, {String? readListId});

  Future<Map<String, dynamic>?> previousBook(String bookId, {String? readListId});

  /// The whole store. Callers asking while a request for it is on its way share that one answer: reader settings,
  /// pins and On deck hidden each refresh from it, and a Home reload asked three times (code review 2026-10-05, #35).
  /// A write starts afresh: nobody joins a request that went out before it.
  Future<Map<String, dynamic>> clientSettings();

  Future<void> putClientSetting(String key, String value);

  /// Komga answers 406 to Accept: application/json here (its API docs list it; the server doesn't serve it), so it's
  /// asked for as Readium's own type.
  Future<Map<String, dynamic>?> epubManifest(String bookId);

  /// One file of an EPUB (a chapter, a stylesheet, a picture, a font) by its path inside the book.
  Future<Uint8List> epubResource(String bookId, String path);

  /// Where reading stopped in an EPUB (Readium's progression: a locator - chapter file, how far in it - with the
  /// device and time); null if never read. Shared with Komga's own web reader.
  Future<Map<String, dynamic>?> epubProgression(String bookId);

  /// Saves where reading stopped in an EPUB; Komga turns it into the book's read progress (page = how far through the
  /// book x its page count for it - see epub/progress.dart komgaEpubPage).
  Future<void> setEpubProgression(String bookId, Map<String, dynamic> progression);

  /// The book's own file (an EPUB, for reading offline).
  Future<Uint8List> bookFileBytes(String bookId);

  /// The book's positions (Readium): roughly one per screenful, numbered from 1; Komga's page count for an EPUB.
  Future<List<dynamic>> epubPositions(String bookId);

  Future<Uint8List> pageBytes(String bookId, int number);

  /// A small picture of a page (Komga makes it, about 300 px wide) - the reader's slider previews. Komga makes each
  /// one from the book file as it's asked, so on a slow share they can take seconds (2026-09-30: 0.2-3.7 s each, and
  /// some queued past the time limit): one running out of time means slow, not gone - Komga isn't reported
  /// unreachable for it.
  Future<Uint8List> pageThumbBytes(String bookId, int number);

  Future<List<dynamic>> bookReadLists(String bookId);

  Future<List<dynamic>> seriesCollections(String seriesId);

  /// A poster's image bytes (null if it has none).
  Future<Uint8List?> thumbBytes(String url);

  Future<void> deleteBookFile(String bookId);

  Future<void> deleteSeriesFiles(String seriesId);
}
