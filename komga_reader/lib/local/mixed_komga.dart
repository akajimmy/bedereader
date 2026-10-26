import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart' show ImageProvider;

import '../api.dart';
import '../hidden_libraries.dart';
import '../offline/offline_komga.dart';
import '../screen.dart' show appStorageDir;
import '../view_filter.dart';
import 'folder_komga.dart';

/// Signed in to Komga, with local libraries beside its own (experimental/sources): the Komga client, with the folders
/// this device has as libraries ([LocalBeside.local], the same ones as local mode's) answered from them.
class MixedKomga extends Komga with LocalBeside {
  MixedKomga(super.baseUrl, super.apiKey, {super.client});
}

/// Offline (Komga out of reach, or switched off by hand): the downloaded books, with the same local libraries
/// beside them - a folder on the device, or a share that answers, doesn't need Komga (user, 2026-10-25: "local
/// libraries should always be available ... any combination should be possible").
class OfflineBeside extends OfflineKomga with LocalBeside {
  OfflineBeside(super.store, {super.baseUrl});
}

/// The local libraries beside another source - Komga ([MixedKomga]) or the downloads offline ([OfflineBeside]): a
/// call about one book, series or library goes to whichever has it; a call across every library asks both and
/// merges what they give, in the order asked for. (`super` is the other source.)
mixin LocalBeside on Komga {
  /// The local libraries (none until [attachLocal], or given).
  FolderKomga? local;

  /// The local libraries saved on this device, opened (their last scan at once; scanned again in the background) -
  /// with none kept yet, not waited for: Komga's Home shows meanwhile, the local books come in when they're read
  /// (code review, 2026-10-25: the start waited for the whole first scan).
  Future<void> attachLocal() async {
    final dir = await appStorageDir();
    if (dir == null || local != null) return;
    try {
      local = await FolderKomga.open(await FolderKomga.savedLibraries(),
          dataDir: Directory('$dir${Platform.pathSeparator}local'), waitForFirstScan: false);
    } catch (_) {
      // no local libraries this time
    }
  }

  FolderKomga? _of(String? id) => id != null && (local?.isLocal(id) ?? false) ? local : null;

  /// Nothing local to merge in.
  bool get _alone => local == null || local!.isEmpty;

  @override
  bool isLocal(String id) => local?.isLocal(id) ?? false;
  @override
  Future<Uint8List> Function()? localEpub(String bookId) => _of(bookId)?.localEpub(bookId);
  @override
  Listenable? get localChanges => local?.changed;

  // ---- libraries: Komga's, then the local ones -----------------------------------------------------------------------
  // (the kept list stays Komga's own: it's what Komga is asked about - "the shown libraries" - so no local id goes there)
  @override
  Future<List<dynamic>> visibleLibraries({bool kept = false}) async {
    final komga = await super.visibleLibraries(kept: kept);
    final mine = local == null ? const [] : await local!.libraries();
    return [...komga, for (final l in mine) if (!HiddenLibraries.instance.isHidden(l['id'] as String?)) l];
  }

  @override
  Future<String?> libraryName(String? id) async {
    final l = _of(id);
    if (l != null) {
      for (final x in await l.libraries()) {
        if (x['id'] == id) return x['name'] as String?;
      }
    }
    return super.libraryName(id);
  }

  // ---- merging: Komga's page and the local items, in one order ------------------------------------------------------
  /// Page [page] of [size] of both together, sorted by [sort] (null: Komga's first, then the local ones). Komga is
  /// asked for everything up to that page, so the merged page is the true one.
  Future<Map<String, dynamic>> _merged(Future<Map<String, dynamic>> Function(int size) komga,
      Future<Map<String, dynamic>> Function() mine, String? sort, int page, int size) async {
    final results = await Future.wait([komga((page + 1) * size), mine()]);
    final all = [...(results[0]['content'] as List? ?? const []), ...(results[1]['content'] as List? ?? const [])];
    if (sort != null) OfflineKomga.sortItems(all, sort);
    final total = ((results[0]['totalElements'] as num?) ?? 0) + ((results[1]['totalElements'] as num?) ?? 0);
    final start = (page * size).clamp(0, all.length), end = (start + size).clamp(0, all.length);
    return {'content': all.sublist(start, end), 'totalElements': total, 'last': page * size + size >= total};
  }

  static const _all = 100000;

  @override
  Future<Map<String, dynamic>> series({String? libraryId, String? collectionId, List<String>? readStatus,
      String sort = 'metadata.titleSort,asc', int page = 0, int size = 60}) {
    final l = _of(libraryId);
    if (l != null) {
      return l.series(libraryId: libraryId, readStatus: readStatus, sort: sort, page: page, size: size);
    }
    if (libraryId != null || collectionId != null || _alone) {
      return super.series(libraryId: libraryId, collectionId: collectionId, readStatus: readStatus, sort: sort,
          page: page, size: size);
    }
    return _merged((n) => super.series(readStatus: readStatus, sort: sort, size: n),
        () => local!.series(readStatus: readStatus, sort: sort, size: _all), sort, page, size);
  }

  @override
  Future<Map<String, dynamic>> books({String? libraryId, List<String>? readStatus,
      String sort = 'metadata.releaseDate,desc', int page = 0, int size = 60}) {
    final l = _of(libraryId);
    if (l != null) return l.books(libraryId: libraryId, readStatus: readStatus, sort: sort, page: page, size: size);
    if (libraryId != null || _alone) {
      return super.books(libraryId: libraryId, readStatus: readStatus, sort: sort, page: page, size: size);
    }
    return _merged((n) => super.books(readStatus: readStatus, sort: sort, size: n),
        () => local!.books(readStatus: readStatus, sort: sort, size: _all), sort, page, size);
  }

  @override
  Future<Map<String, dynamic>> onDeck({String? libraryId, int size = 30}) {
    final l = _of(libraryId);
    if (l != null) return l.onDeck(libraryId: libraryId, size: size);
    if (libraryId != null || _alone) return super.onDeck(libraryId: libraryId, size: size);
    return _merged((n) => super.onDeck(size: n), () => local!.onDeck(size: size), null, 0, size);
  }

  @override
  Future<Map<String, dynamic>> searchSeries(String query, {String? libraryId, int size = 30}) {
    final l = _of(libraryId);
    if (l != null) return l.searchSeries(query, libraryId: libraryId, size: size);
    if (libraryId != null || _alone) return super.searchSeries(query, libraryId: libraryId, size: size);
    return _merged((n) => super.searchSeries(query, size: n), () => local!.searchSeries(query, size: size), null, 0,
        size);
  }

  @override
  Future<Map<String, dynamic>> searchBooks(String query, {String? libraryId, int size = 30}) {
    final l = _of(libraryId);
    if (l != null) return l.searchBooks(query, libraryId: libraryId, size: size);
    if (libraryId != null || _alone) return super.searchBooks(query, libraryId: libraryId, size: size);
    return _merged((n) => super.searchBooks(query, size: n), () => local!.searchBooks(query, size: size), null, 0,
        size);
  }

  @override
  Future<Map<String, dynamic>> booksOfSeries(List<String> seriesIds, {int size = 300}) async {
    final mine = [for (final id in seriesIds) if (isLocal(id)) id];
    final theirs = [for (final id in seriesIds) if (!isLocal(id)) id];
    if (mine.isEmpty) return super.booksOfSeries(seriesIds, size: size);
    final a = theirs.isEmpty ? const <String, dynamic>{'content': []} : await super.booksOfSeries(theirs, size: size);
    final b = await local!.booksOfSeries(mine, size: size);
    final all = [...a['content'] as List, ...b['content'] as List];
    return {'content': all.take(size).toList(), 'totalElements': all.length, 'last': all.length <= size};
  }

  @override
  Future<Map<String, dynamic>> filteredSeries({String? libraryId, String? collectionId,
      ReadFilter read = ReadFilter.all, ViewFilter filter = ViewFilter.none, String sort = 'metadata.titleSort,asc',
      int page = 0, int size = 60}) {
    final l = _of(libraryId);
    if (l != null) {
      return l.filteredSeries(libraryId: libraryId, read: read, filter: filter, sort: sort, page: page, size: size);
    }
    if (libraryId != null || collectionId != null || _alone) {
      return super.filteredSeries(libraryId: libraryId, collectionId: collectionId, read: read, filter: filter,
          sort: sort, page: page, size: size);
    }
    return _merged((n) => super.filteredSeries(read: read, filter: filter, sort: sort, size: n),
        () => local!.filteredSeries(read: read, filter: filter, sort: sort, size: _all), sort, page, size);
  }

  @override
  Future<Map<String, dynamic>> filteredBooks({String? libraryId, String? seriesId, String? readListId,
      ReadFilter read = ReadFilter.all, ViewFilter filter = ViewFilter.none, String? sort, int page = 0,
      int? size}) {
    final l = _of(seriesId) ?? _of(libraryId);
    if (l != null) {
      return l.filteredBooks(libraryId: libraryId, seriesId: seriesId, read: read, filter: filter, sort: sort,
          page: page, size: size);
    }
    if (libraryId != null || seriesId != null || readListId != null || _alone) {
      return super.filteredBooks(libraryId: libraryId, seriesId: seriesId, readListId: readListId, read: read,
          filter: filter, sort: sort, page: page, size: size);
    }
    final s = sort ?? 'metadata.releaseDate,desc', n = size ?? 60;
    return _merged((k) => super.filteredBooks(read: read, filter: filter, sort: s, size: k),
        () => local!.filteredBooks(read: read, filter: filter, sort: s, size: _all), s, page, n);
  }

  // ---- what the filter panel offers: both, where the view spans both -------------------------------------------------
  @override
  Future<List<String>> authorNames(List<String> roles, {String? search, String? libraryId, String? collectionId,
      String? seriesId, String? readListId, int size = 1000}) async {
    final l = _of(seriesId) ?? _of(libraryId);
    if (l != null) {
      return l.authorNames(roles, search: search, libraryId: libraryId, seriesId: seriesId, size: size);
    }
    final komga = await super.authorNames(roles, search: search, libraryId: libraryId, collectionId: collectionId,
        seriesId: seriesId, readListId: readListId, size: size);
    if (libraryId != null || seriesId != null || readListId != null || collectionId != null || _alone) return komga;
    return Komga.sortedValues([...komga, ...await local!.authorNames(roles, search: search, size: size)]);
  }

  @override
  Future<List<String>> publishers({String? libraryId, String? collectionId}) async {
    final l = _of(libraryId);
    if (l != null) return l.publishers(libraryId: libraryId);
    final komga = await super.publishers(libraryId: libraryId, collectionId: collectionId);
    if (libraryId != null || collectionId != null || _alone) return komga;
    return Komga.sortedValues([...komga, ...await local!.publishers()]);
  }

  @override
  Future<List<String>> genres({String? libraryId, String? collectionId}) async {
    final l = _of(libraryId);
    if (l != null) return l.genres(libraryId: libraryId);
    final komga = await super.genres(libraryId: libraryId, collectionId: collectionId);
    if (libraryId != null || collectionId != null || _alone) return komga;
    return Komga.sortedValues([...komga, ...await local!.genres()]);
  }

  @override
  Future<ViewKind> viewKind({String? libraryId, String? seriesId, String? readListId}) {
    final l = _of(seriesId) ?? _of(libraryId);
    if (l != null) return l.viewKind(libraryId: libraryId, seriesId: seriesId);
    return super.viewKind(libraryId: libraryId, seriesId: seriesId, readListId: readListId);
  }

  // ---- one item: whichever has it ----------------------------------------------------------------------------------------
  @override
  Future<Map<String, dynamic>> seriesBooks(String seriesId, {List<String>? readStatus,
          String sort = 'metadata.numberSort,asc', int page = 0, int size = 500}) =>
      _of(seriesId)?.seriesBooks(seriesId, readStatus: readStatus, sort: sort, page: page, size: size) ??
      super.seriesBooks(seriesId, readStatus: readStatus, sort: sort, page: page, size: size);

  @override
  Future<Map<String, dynamic>?> oneSeries(String id) => _of(id)?.oneSeries(id) ?? super.oneSeries(id);
  @override
  Future<Map<String, dynamic>?> book(String id) => _of(id)?.book(id) ?? super.book(id);
  @override
  Future<List<dynamic>> pages(String bookId) => _of(bookId)?.pages(bookId) ?? super.pages(bookId);
  @override
  Future<Uint8List> pageBytes(String bookId, int number) =>
      _of(bookId)?.pageBytes(bookId, number) ?? super.pageBytes(bookId, number);
  @override
  Future<Uint8List> pageThumbBytes(String bookId, int number) =>
      _of(bookId)?.pageThumbBytes(bookId, number) ?? super.pageThumbBytes(bookId, number);
  @override
  String seriesThumb(String id) => _of(id)?.seriesThumb(id) ?? super.seriesThumb(id);
  @override
  String bookThumb(String id) => _of(id)?.bookThumb(id) ?? super.bookThumb(id);
  @override
  ImageProvider thumbImage(String ref) =>
      local != null && !ref.startsWith('http') ? local!.thumbImage(ref) : super.thumbImage(ref);

  @override
  Future<void> setProgress(String bookId, int page, {bool completed = false}) =>
      _of(bookId)?.setProgress(bookId, page, completed: completed) ??
      super.setProgress(bookId, page, completed: completed);
  @override
  Future<void> markRead(String bookId) => _of(bookId)?.markRead(bookId) ?? super.markRead(bookId);
  @override
  Future<void> markUnread(String bookId) => _of(bookId)?.markUnread(bookId) ?? super.markUnread(bookId);
  @override
  Future<void> markSeriesRead(String seriesId) =>
      _of(seriesId)?.markSeriesRead(seriesId) ?? super.markSeriesRead(seriesId);
  @override
  Future<void> markSeriesUnread(String seriesId) =>
      _of(seriesId)?.markSeriesUnread(seriesId) ?? super.markSeriesUnread(seriesId);

  @override
  Future<Map<String, dynamic>?> nextBook(String bookId, {String? readListId}) =>
      _of(bookId)?.nextBook(bookId) ?? super.nextBook(bookId, readListId: readListId);
  @override
  Future<Map<String, dynamic>?> previousBook(String bookId, {String? readListId}) =>
      _of(bookId)?.previousBook(bookId) ?? super.previousBook(bookId, readListId: readListId);

  @override
  Future<Map<String, dynamic>?> epubProgression(String bookId) =>
      _of(bookId)?.epubProgression(bookId) ?? super.epubProgression(bookId);
  @override
  Future<void> setEpubProgression(String bookId, Map<String, dynamic> progression) =>
      _of(bookId)?.setEpubProgression(bookId, progression) ?? super.setEpubProgression(bookId, progression);
  @override
  Future<List<dynamic>> epubPositions(String bookId) =>
      _of(bookId)?.epubPositions(bookId) ?? super.epubPositions(bookId);

  @override
  Future<List<dynamic>> bookReadLists(String bookId) async =>
      isLocal(bookId) ? const [] : super.bookReadLists(bookId);
  @override
  Future<List<dynamic>> seriesCollections(String seriesId) async =>
      isLocal(seriesId) ? const [] : super.seriesCollections(seriesId);

  // a local book's files are the user's own: not deleted from here
  @override
  Future<void> deleteBookFile(String bookId) =>
      isLocal(bookId) ? Future.error(NotAvailableOffline('Deleting a local book')) : super.deleteBookFile(bookId);
  @override
  Future<void> deleteSeriesFiles(String seriesId) => isLocal(seriesId)
      ? Future.error(NotAvailableOffline('Deleting a local series'))
      : super.deleteSeriesFiles(seriesId);
}
