import 'dart:typed_data';

import 'package:flutter/painting.dart' show ImageProvider;

import 'api.dart' show Komga;
import 'book_source.dart';
import 'local/book_names.dart' show isLocalId;
import 'local/local_source.dart';
import 'offline/catalogue_source.dart';
import 'view_filter.dart';

/// The books as the screens see them: Komga's (online), or its downloads (offline) - [main] - with the local libraries
/// beside it ([local]), as one source. What's about one item goes to the source it's in (a local id is told by its
/// form); what's about several - a library's grid with none chosen, On deck, search - is asked of both and put
/// together. Offline, [main] is swapped for the downloads; the local libraries stay.
class CombinedSource implements BookSource {
  CombinedSource(this._main, {this.local});

  /// Komga, or - offline - its downloads.
  BookSource get main => _main;
  BookSource _main;

  /// Online / offline: the other one in its place (what was kept of its pages, let go).
  set main(BookSource to) {
    if (identical(to, _main)) return;
    _main = to;
    _merges.clear();
  }

  /// The source [id] is in, whatever [api] is - this or one source (the reader's, the server status's questions:
  /// "is it Komga's?", "is it the downloads'?").
  static BookSource of(BookSource api, String? id) => api is CombinedSource ? api.sourceOf(id) : api;

  /// [api]'s Komga or downloads - [main] - whatever [api] is.
  static BookSource mainOf(BookSource api) => api is CombinedSource ? api.main : api;

  /// The local libraries (null: none).
  LocalSource? local;

  /// No server mode: the local libraries are [main] - there's no Komga.
  bool get noServer => main is LocalSource;

  /// No server mode, whatever [api] is.
  static bool noServerOf(BookSource api) => mainOf(api) is LocalSource;

  /// The local libraries, when they have books and aren't [main] already (No server mode) - else nothing to put
  /// together ([main]'s answers as they are).
  LocalSource? get _local => (local?.isEmpty ?? true) || identical(local, main) ? null : local;

  /// The local libraries beside [main] - none in No server mode, where they are [main] (the library lists gave each
  /// library twice: the review, 2026-10-26).
  LocalSource? get _beside => identical(local, main) ? null : local;

  /// The source [id] (a book, series, library or read list) is in.
  BookSource sourceOf(String? id) => id != null && isLocalId(id) && local != null ? local! : main;

  // ---- putting lists together -----------------------------------------------------------------------------------------
  static const _all = 1 << 30;

  // a grid's merged order, kept from one page to the next: Komga's pages fetched so far, and the local list. Page 0
  // starts afresh (a refresh shows what's new); any later page reads on from what's kept - two views of the same list
  // read the same kept pages, not each other's resets (the experiment's review: one view's first page reset another's)
  final Map<String, _Merge> _merges = {};

  Future<Map<String, dynamic>> _merged(String key, String sort, int page, int size,
      Future<Map<String, dynamic>> Function(int page, int size) fromMain, Future<List<dynamic>> Function() fromLocal) async {
    var m = _merges.remove(key);
    if (page == 0 || m == null) m = _Merge(await fromLocal());
    _merges[key] = m; // (the newest last)
    while (_merges.length > 24) {
      _merges.remove(_merges.keys.first);
    }
    final compare = CatalogueSource.comparator(sort);
    final out = <dynamic>[];
    var i = 0, j = 0;
    final start = page * size, end = start + size;
    for (var at = 0; at < end; at++) {
      if (i >= m.main.length && !m.mainDone) {
        final r = await fromMain(m.pagesFetched++, size);
        final content = (r['content'] as List?) ?? const [];
        m.main.addAll(content);
        m.mainTotal = (r['totalElements'] as num?)?.toInt() ?? m.main.length;
        if (content.isEmpty || r['last'] == true) m.mainDone = true;
      }
      final a = i < m.main.length ? m.main[i] as Map : null, b = j < m.local.length ? m.local[j] as Map : null;
      if (a == null && b == null) break;
      final Map next;
      if (b == null || (a != null && compare(a, b) <= 0)) {
        next = a!;
        i++;
      } else {
        next = b;
        j++;
      }
      if (at >= start) out.add(next);
    }
    final total = (m.mainDone ? m.main.length : m.mainTotal) + m.local.length;
    return {'content': out, 'totalElements': total, 'last': end >= total};
  }

  /// Two short lists (On deck, search) made one of [size]: each source keeps at least half of it when it has that
  /// many (the experiment's put Komga's first and cut: with 30 of Komga's, no local one was ever shown).
  static Map<String, dynamic> _shared(Map<String, dynamic> a, Map<String, dynamic> b, int size) {
    final la = (a['content'] as List?) ?? const [], lb = (b['content'] as List?) ?? const [];
    final fromB = lb.length < size ~/ 2 ? lb.length : (la.length < size - size ~/ 2 ? size - la.length : size ~/ 2);
    final fromA = (size - fromB).clamp(0, la.length);
    final content = [...la.take(fromA), ...lb.take(fromB.clamp(0, size - fromA))];
    final total = ((a['totalElements'] as num?) ?? la.length) + ((b['totalElements'] as num?) ?? lb.length);
    return {'content': content, 'totalElements': total, 'last': content.length >= total};
  }

  /// Both sources' answers, asked at once (the local one while Komga's is on its way - the review, 2026-10-26); the
  /// first error as it is (a record's .wait wraps it, and explain() wouldn't know it).
  static Future<(Map<String, dynamic>, Map<String, dynamic>)> _both(
      Future<Map<String, dynamic>> a, Future<Map<String, dynamic>> b) async {
    final r = await Future.wait([a, b]);
    return (r[0], r[1]);
  }

  static String _key(String what, List<Object?> args) => '$what|${args.join('|')}';

  // ---- account / libraries ------------------------------------------------------------------------------------------
  @override
  String get baseUrl => main.baseUrl;

  /// (The local libraries are the app's: opened and closed by it, not with Komga's connection.)
  @override
  void close() => main.close();

  @override
  Future<Map<String, dynamic>?> me() => main.me();

  @override
  Future<List<dynamic>> libraries() async => [...await main.libraries(), ...?await _beside?.libraries()];

  @override
  Future<List<dynamic>> keptLibraries() async => [...await main.keptLibraries(), ...?await _beside?.libraries()];

  @override
  void forgetLibraries() => main.forgetLibraries();

  @override
  Future<String?> libraryName(String? id) => sourceOf(id).libraryName(id);

  @override
  Future<List<dynamic>> visibleLibraries({bool kept = false}) async =>
      [...await main.visibleLibraries(kept: kept), ...?await _beside?.visibleLibraries(kept: kept)];

  // ---- browsing -----------------------------------------------------------------------------------------------------
  @override
  Future<Map<String, dynamic>> series({String? libraryId, String? collectionId, List<String>? readStatus,
      String sort = 'metadata.titleSort,asc', int page = 0, int size = 60}) {
    final l = _local;
    if (libraryId != null || collectionId != null || l == null) {
      return sourceOf(libraryId ?? collectionId).series(libraryId: libraryId, collectionId: collectionId,
          readStatus: readStatus, sort: sort, page: page, size: size);
    }
    return _merged(_key('series', [readStatus, sort, size]), sort, page, size,
        (p, s) => main.series(readStatus: readStatus, sort: sort, page: p, size: s),
        () async => (await l.series(readStatus: readStatus, sort: sort, size: _all))['content'] as List);
  }

  @override
  Future<Map<String, dynamic>> books({String? libraryId, List<String>? readStatus,
      String sort = 'metadata.releaseDate,desc', int page = 0, int size = 60}) {
    final l = _local;
    if (libraryId != null || l == null) {
      return sourceOf(libraryId).books(libraryId: libraryId, readStatus: readStatus, sort: sort, page: page, size: size);
    }
    return _merged(_key('books', [readStatus, sort, size]), sort, page, size,
        (p, s) => main.books(readStatus: readStatus, sort: sort, page: p, size: s),
        () async => (await l.books(readStatus: readStatus, sort: sort, size: _all))['content'] as List);
  }

  /// Books part-way through, most recently read first - both sources' together.
  @override
  Future<Map<String, dynamic>> inProgress({String? libraryId, int size = 30}) async {
    final l = _local;
    if (libraryId != null || l == null) return sourceOf(libraryId).inProgress(libraryId: libraryId, size: size);
    final r = await _both(main.inProgress(size: size), l.inProgress(size: size));
    final both = [...r.$1['content'] as List, ...r.$2['content'] as List]..sort((a, b) => CatalogueSource.comparator('readProgress.readDate,desc')(a as Map, b as Map));
    return {'content': both.take(size).toList(), 'totalElements': both.length, 'last': both.length <= size};
  }

  @override
  Future<Map<String, dynamic>> onDeck({String? libraryId, int size = 30}) async {
    final l = _local;
    if (libraryId != null || l == null) return sourceOf(libraryId).onDeck(libraryId: libraryId, size: size);
    final (a, b) = await _both(main.onDeck(size: size), l.onDeck(size: size));
    return _shared(a, b, size);
  }

  @override
  Future<Map<String, dynamic>> seriesBooks(String seriesId, {List<String>? readStatus,
      String sort = 'metadata.numberSort,asc', int page = 0, int size = 500}) =>
      sourceOf(seriesId).seriesBooks(seriesId, readStatus: readStatus, sort: sort, page: page, size: size);

  @override
  Future<Map<String, dynamic>> collections({String? libraryId, int page = 0, int size = 200}) =>
      sourceOf(libraryId).collections(libraryId: libraryId, page: page, size: size);

  @override
  Future<Map<String, dynamic>> readLists({String? libraryId, int page = 0, int size = 200}) async {
    final l = _local;
    final mine = sourceOf(libraryId).readLists(libraryId: libraryId, page: page, size: size);
    if (libraryId != null || l == null || page > 0) return mine;
    final theirs = (await l.readLists(size: _all))['content'] as List;
    if (theirs.isEmpty) return mine;
    final r = await mine;
    final content = [...r['content'] as List, ...theirs];
    return {'content': content, 'totalElements': ((r['totalElements'] as num?) ?? 0) + theirs.length,
        'last': r['last'] ?? true};
  }

  @override
  Future<Map<String, dynamic>> searchSeries(String query, {String? libraryId, int size = 30}) async {
    final l = _local;
    if (libraryId != null || l == null) return sourceOf(libraryId).searchSeries(query, libraryId: libraryId, size: size);
    final (a, b) = await _both(main.searchSeries(query, size: size), l.searchSeries(query, size: size));
    return _shared(a, b, size);
  }

  @override
  Future<Map<String, dynamic>> searchBooks(String query, {String? libraryId, int size = 30}) async {
    final l = _local;
    if (libraryId != null || l == null) return sourceOf(libraryId).searchBooks(query, libraryId: libraryId, size: size);
    final (a, b) = await _both(main.searchBooks(query, size: size), l.searchBooks(query, size: size));
    return _shared(a, b, size);
  }

  /// Each source asked for its own series' books.
  @override
  Future<Map<String, dynamic>> booksOfSeries(List<String> seriesIds, {int size = 300}) async {
    final l = local;
    final mine = [for (final id in seriesIds) if (l == null || !isLocalId(id)) id];
    final theirs = [for (final id in seriesIds) if (l != null && isLocalId(id)) id];
    final a = mine.isEmpty ? const <dynamic>[] : (await main.booksOfSeries(mine, size: size))['content'] as List;
    final b = theirs.isEmpty ? const <dynamic>[] : (await l!.booksOfSeries(theirs, size: size))['content'] as List;
    final content = [...a, ...b].take(size).toList();
    return {'content': content, 'totalElements': a.length + b.length, 'last': true};
  }

  @override
  Future<Map<String, dynamic>> searchReadLists(String query, {String? libraryId, int size = 30}) async {
    final l = _local;
    if (libraryId != null || l == null) {
      return sourceOf(libraryId).searchReadLists(query, libraryId: libraryId, size: size);
    }
    final (a, b) = await _both(main.searchReadLists(query, size: size), l.searchReadLists(query, size: size));
    return _shared(a, b, size);
  }

  @override
  Future<Map<String, dynamic>> searchCollections(String query, {String? libraryId, int size = 30}) =>
      sourceOf(libraryId).searchCollections(query, libraryId: libraryId, size: size);

  @override
  Future<Map<String, dynamic>> readListBooks(String readListId,
          {List<String>? readStatus, int page = 0, int size = 1000}) =>
      sourceOf(readListId).readListBooks(readListId, readStatus: readStatus, page: page, size: size);

  @override
  Future<Map<String, dynamic>> filteredSeries({String? libraryId, String? collectionId,
      ReadFilter read = ReadFilter.all, ViewFilter filter = ViewFilter.none, String sort = 'metadata.titleSort,asc',
      int page = 0, int size = 60}) {
    final l = _local;
    if (libraryId != null || collectionId != null || l == null) {
      return sourceOf(libraryId ?? collectionId).filteredSeries(libraryId: libraryId, collectionId: collectionId,
          read: read, filter: filter, sort: sort, page: page, size: size);
    }
    return _merged(_key('filteredSeries', [read, filter, sort, size]), sort, page, size,
        (p, s) => main.filteredSeries(read: read, filter: filter, sort: sort, page: p, size: s),
        () async => (await l.filteredSeries(read: read, filter: filter, sort: sort, size: _all))['content'] as List);
  }

  @override
  Future<Map<String, dynamic>> filteredBooks({String? libraryId, String? seriesId, String? readListId,
      ReadFilter read = ReadFilter.all, ViewFilter filter = ViewFilter.none, String? sort, int page = 0,
      int? size}) {
    final l = _local;
    if (libraryId != null || seriesId != null || readListId != null || l == null) {
      return sourceOf(seriesId ?? readListId ?? libraryId).filteredBooks(libraryId: libraryId, seriesId: seriesId,
          readListId: readListId, read: read, filter: filter, sort: sort, page: page, size: size);
    }
    final s = sort ?? 'metadata.releaseDate,desc', n = size ?? 60;
    return _merged(_key('filteredBooks', [read, filter, s, n]), s, page, n,
        (p, sz) => main.filteredBooks(read: read, filter: filter, sort: s, page: p, size: sz),
        () async => (await l.filteredBooks(read: read, filter: filter, sort: s, size: _all))['content'] as List);
  }

  @override
  Future<List<String>> authorNames(List<String> roles, {String? search, String? libraryId, String? collectionId,
      String? seriesId, String? readListId, int size = 1000}) async {
    final l = _local;
    final scope = seriesId ?? readListId ?? collectionId ?? libraryId;
    if (scope != null || l == null) {
      return sourceOf(scope).authorNames(roles, search: search, libraryId: libraryId, collectionId: collectionId,
          seriesId: seriesId, readListId: readListId, size: size);
    }
    return Komga.sortedValues({
      ...await main.authorNames(roles, search: search, size: size),
      ...await l.authorNames(roles, search: search, size: size),
    }).take(size).toList();
  }

  @override
  Future<List<String>> publishers({String? libraryId, String? collectionId}) async {
    final l = _local;
    if (libraryId != null || collectionId != null || l == null) {
      return sourceOf(libraryId ?? collectionId).publishers(libraryId: libraryId, collectionId: collectionId);
    }
    return Komga.sortedValues({...await main.publishers(), ...await l.publishers()});
  }

  @override
  Future<List<String>> genres({String? libraryId, String? collectionId}) async {
    final l = _local;
    if (libraryId != null || collectionId != null || l == null) {
      return sourceOf(libraryId ?? collectionId).genres(libraryId: libraryId, collectionId: collectionId);
    }
    return Komga.sortedValues({...await main.genres(), ...await l.genres()});
  }

  @override
  Future<ViewKind> viewKind({String? libraryId, String? seriesId, String? readListId}) async {
    final l = _local;
    final scope = seriesId ?? readListId ?? libraryId;
    if (scope != null || l == null) {
      return sourceOf(scope).viewKind(libraryId: libraryId, seriesId: seriesId, readListId: readListId);
    }
    return ViewKind.combine([await main.viewKind(), await l.viewKind()]);
  }

  // ---- one item: the source it's in ---------------------------------------------------------------------------------
  @override
  Future<Map<String, dynamic>?> oneSeries(String id) => sourceOf(id).oneSeries(id);
  @override
  Future<Map<String, dynamic>?> readList(String id) => sourceOf(id).readList(id);
  @override
  Future<void> renameReadList(String id, String name) => sourceOf(id).renameReadList(id, name);
  @override
  Future<void> renameCollection(String id, String name) => sourceOf(id).renameCollection(id, name);
  @override
  Future<Map<String, dynamic>?> book(String id) => sourceOf(id).book(id);
  @override
  Future<Map<String, dynamic>> collectionSeries(String collectionId,
          {List<String>? readStatus, int page = 0, int size = 60}) =>
      sourceOf(collectionId).collectionSeries(collectionId, readStatus: readStatus, page: page, size: size);
  @override
  Future<Map<String, dynamic>> readListBooksSorted(String readListId, String sort,
          {List<String>? readStatus, int page = 0, int size = 500}) =>
      sourceOf(readListId).readListBooksSorted(readListId, sort, readStatus: readStatus, page: page, size: size);
  @override
  Future<List<dynamic>> pages(String bookId) => sourceOf(bookId).pages(bookId);
  @override
  String seriesThumb(String id) => sourceOf(id).seriesThumb(id);
  @override
  String bookThumb(String id) => sourceOf(id).bookThumb(id);
  @override
  String readListThumb(String id) => sourceOf(id).readListThumb(id);
  @override
  String collectionThumb(String id) => sourceOf(id).collectionThumb(id);

  /// A poster reference: the local libraries' own, or [main]'s.
  @override
  ImageProvider thumbImage(String ref) =>
      local != null && local!.ownsPoster(ref) ? local!.thumbImage(ref) : main.thumbImage(ref);

  @override
  Future<void> setProgress(String bookId, int page, {bool completed = false}) =>
      sourceOf(bookId).setProgress(bookId, page, completed: completed);
  @override
  Future<void> markRead(String bookId) => sourceOf(bookId).markRead(bookId);
  @override
  Future<void> markUnread(String bookId) => sourceOf(bookId).markUnread(bookId);
  @override
  Future<void> markSeriesRead(String seriesId) => sourceOf(seriesId).markSeriesRead(seriesId);
  @override
  Future<void> markSeriesUnread(String seriesId) => sourceOf(seriesId).markSeriesUnread(seriesId);
  @override
  Future<Map<String, dynamic>?> nextBook(String bookId, {String? readListId}) =>
      sourceOf(bookId).nextBook(bookId, readListId: readListId);
  @override
  Future<Map<String, dynamic>?> previousBook(String bookId, {String? readListId}) =>
      sourceOf(bookId).previousBook(bookId, readListId: readListId);

  // settings are the account's: Komga's
  @override
  Future<Map<String, dynamic>> clientSettings() => main.clientSettings();
  @override
  Future<void> putClientSetting(String key, String value) => main.putClientSetting(key, value);

  @override
  Future<Map<String, dynamic>?> epubManifest(String bookId) => sourceOf(bookId).epubManifest(bookId);
  @override
  Future<Uint8List> epubResource(String bookId, String path) => sourceOf(bookId).epubResource(bookId, path);
  @override
  Future<Map<String, dynamic>?> epubProgression(String bookId) => sourceOf(bookId).epubProgression(bookId);
  @override
  Future<void> setEpubProgression(String bookId, Map<String, dynamic> progression) =>
      sourceOf(bookId).setEpubProgression(bookId, progression);
  @override
  Future<Uint8List> bookFileBytes(String bookId) => sourceOf(bookId).bookFileBytes(bookId);
  @override
  Future<List<dynamic>> epubPositions(String bookId) => sourceOf(bookId).epubPositions(bookId);
  @override
  Future<Uint8List> pageBytes(String bookId, int number) => sourceOf(bookId).pageBytes(bookId, number);
  @override
  Future<Uint8List> pageThumbBytes(String bookId, int number) => sourceOf(bookId).pageThumbBytes(bookId, number);
  @override
  Future<List<dynamic>> bookReadLists(String bookId) => sourceOf(bookId).bookReadLists(bookId);
  @override
  Future<List<dynamic>> seriesCollections(String seriesId) => sourceOf(seriesId).seriesCollections(seriesId);
  @override
  Future<Uint8List?> thumbBytes(String url) => main.thumbBytes(url);
  @override
  Future<void> deleteBookFile(String bookId) => sourceOf(bookId).deleteBookFile(bookId);
  @override
  Future<void> deleteSeriesFiles(String seriesId) => sourceOf(seriesId).deleteSeriesFiles(seriesId);
}

class _Merge {
  _Merge(this.local);
  final List<dynamic> local;
  final List<dynamic> main = [];
  int pagesFetched = 0, mainTotal = 0;
  bool mainDone = false;
}
