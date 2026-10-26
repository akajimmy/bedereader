import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/painting.dart' show FileImage, ImageProvider;
import 'package:http/http.dart' as http;

import '../api.dart';
import '../hidden_libraries.dart';
import '../epub/progress.dart' show komgaEpubPage;
import '../view_filter.dart';
import 'downloads.dart';
import 'store.dart';

/// Thrown for things that need the server (deleting files, ...) while offline.
class NotAvailableOffline implements Exception {
  NotAvailableOffline(this.what);
  final String what;
  @override
  String toString() => '$what is not available offline';
}

/// Komga, as if only the downloaded books existed (user's 1.1 decision): the same calls the screens already make,
/// answered from the [OfflineStore], so libraries / series / read lists / collections / books show the downloaded
/// part of the tree. Reading progress goes to the store's queue; server-only actions throw [NotAvailableOffline];
/// settings sync throws [KomgaUnreachable] so it retries once back online.
class OfflineKomga extends Komga {
  // no HTTP client of its own: it answers from the device (one was made per offline source and never used or closed -
  // code review 2026-10-05, #50)
  OfflineKomga(this.store, {String baseUrl = 'offline'}) : super(baseUrl, '', client: _NoNetwork());
  final OfflineStore store;

  // ---- helpers ------------------------------------------------------------------------------------------------------
  // downloaded books - those in a library hidden on this device left out, as online
  Iterable<MapEntry<String, Map<String, dynamic>>> get _done => store.books.entries.where((e) =>
      e.value['state'] == 'done' && !HiddenLibraries.instance.isHidden((e.value['library'] as Map?)?['id'] as String?));

  /// The book as Komga would return it, with the progress made on this device.
  Map<String, dynamic> _book(String id) {
    final b = Map<String, dynamic>.from(store.books[id]!['book'] as Map);
    b['readProgress'] = store.readProgressOf(id);
    return b;
  }

  static String _status(Map<String, dynamic>? rp) =>
      rp == null ? 'UNREAD' : (rp['completed'] == true ? 'READ' : 'IN_PROGRESS');

  bool _wanted(List<String>? readStatus, String status) => readStatus == null || readStatus.contains(status);

  static Map<String, dynamic> _page(List<dynamic> all, int page, int size) {
    final start = (page * size).clamp(0, all.length);
    final end = (start + size).clamp(0, all.length);
    return {'content': all.sublist(start, end), 'totalElements': all.length, 'last': end >= all.length};
  }

  static num _numberSort(Map b) => ((b['metadata'] as Map?)?['numberSort'] as num?) ?? 0;

  /// Sorts by a Komga sort param "field,dir" for the fields the app uses.
  static void _sort(List<dynamic> list, String sort, dynamic Function(Map item) key) {
    final desc = sort.endsWith(',desc');
    list.sort((a, b) {
      final ka = key(a as Map), kb = key(b as Map);
      final c = (ka is num && kb is num) ? ka.compareTo(kb) : '${ka ?? ''}'.toLowerCase().compareTo('${kb ?? ''}'.toLowerCase());
      return desc ? -c : c;
    });
  }

  static dynamic _sortKey(String sort, Map item) {
    final field = sort.split(',').first;
    return switch (field) {
      'metadata.titleSort' => (item['metadata'] as Map?)?['titleSort'] ?? (item['metadata'] as Map?)?['title'] ?? item['name'],
      'metadata.title' => (item['metadata'] as Map?)?['title'] ?? item['name'],
      'metadata.numberSort' => _numberSort(item),
      'metadata.releaseDate' => (item['metadata'] as Map?)?['releaseDate'],
      'booksMetadata.releaseDate' => (item['booksMetadata'] as Map?)?['releaseDate'],
      'readProgress.readDate' => (item['readProgress'] as Map?)?['readDate'],
      'createdDate' => item['created'] ?? item['createdDate'],
      'lastModifiedDate' => item['lastModified'] ?? item['lastModifiedDate'],
      _ => item['name'],
    };
  }

  List<String> _booksOfSeries(String seriesId) =>
      [for (final e in _done) if ((e.value['book'] as Map)['seriesId'] == seriesId) e.key];

  /// Every series' books, in one walk over them - for a list of series: each one's books looked for by walking all
  /// of them was series x books (a library of 1,098 series and 8,843 books took 11 s to list on the tablet).
  Map<String, List<String>> _seriesIndex() {
    final out = <String, List<String>>{};
    for (final e in _done) {
      (out[(e.value['book'] as Map)['seriesId'] as String] ??= []).add(e.key);
    }
    return out;
  }

  /// Series as Komga would return it, with book counts for the downloaded books only. [ids]: its books, if known.
  Map<String, dynamic> _series(String seriesId, [List<String>? ids]) {
    ids ??= _booksOfSeries(seriesId);
    final s = Map<String, dynamic>.from(store.books[ids.first]!['series'] as Map);
    var unread = 0, inProgress = 0, read = 0;
    for (final id in ids) {
      switch (_status(store.readProgressOf(id))) {
        case 'UNREAD':
          unread++;
        case 'IN_PROGRESS':
          inProgress++;
        default:
          read++;
      }
    }
    s['booksCount'] = ids.length;
    s['booksUnreadCount'] = unread;
    s['booksInProgressCount'] = inProgress;
    s['booksReadCount'] = read;
    return s;
  }

  /// Komga's series read status: READ when all read, UNREAD when none started, else IN_PROGRESS.
  static String _seriesStatus(Map<String, dynamic> s) {
    if (s['booksUnreadCount'] == s['booksCount']) return 'UNREAD';
    if (s['booksReadCount'] == s['booksCount']) return 'READ';
    return 'IN_PROGRESS';
  }

  // ---- account / libraries -------------------------------------------------------------------------------------------
  @override
  Future<Map<String, dynamic>?> me({via, Duration limit = Komga.timeout}) async => {'email': 'offline'};

  @override
  Future<List<dynamic>> libraries() async {
    final libs = <String, Map<String, dynamic>>{};
    for (final e in _done) {
      final l = e.value['library'] as Map?;
      if (l != null) libs[l['id'] as String] = Map<String, dynamic>.from(l);
    }
    return libs.values.toList()..sort((a, b) => '${a['name']}'.compareTo('${b['name']}'));
  }

  @override
  Future<List<dynamic>> keptLibraries() => libraries(); // read from the device each time: nothing to keep

  // ---- browsing ------------------------------------------------------------------------------------------------------
  @override
  Future<Map<String, dynamic>> series({String? libraryId, String? collectionId, List<String>? readStatus,
      String sort = 'metadata.titleSort,asc', int page = 0, int size = 60}) async {
    final ids = <String>{};
    for (final e in _done) {
      final v = e.value;
      if (libraryId != null && (v['library'] as Map?)?['id'] != libraryId) continue;
      if (collectionId != null && !((v['collections'] as List?) ?? []).any((c) => c['id'] == collectionId)) continue;
      ids.add((v['book'] as Map)['seriesId'] as String);
    }
    final index = _seriesIndex();
    final list = <dynamic>[
      for (final id in ids) _series(id, index[id]),
    ].where((s) => _wanted(readStatus, _seriesStatus(s as Map<String, dynamic>))).toList();
    _sort(list, sort, (m) => _sortKey(sort, m));
    return _page(list, page, size);
  }

  @override
  Future<Map<String, dynamic>> books({String? libraryId, List<String>? readStatus,
      String sort = 'metadata.releaseDate,desc', int page = 0, int size = 60}) async {
    final list = <dynamic>[
      for (final e in _done)
        if (libraryId == null || (e.value['library'] as Map?)?['id'] == libraryId) _book(e.key),
    ].where((b) => _wanted(readStatus, _status((b as Map)['readProgress'] as Map<String, dynamic>?))).toList();
    _sort(list, sort, (m) => _sortKey(sort, m));
    return _page(list, page, size);
  }

  @override
  Future<Map<String, dynamic>> onDeck({String? libraryId, int size = 30}) async {
    // the next unread downloaded book of series that have been started and have nothing in progress
    final picks = <dynamic>[];
    for (final ids in _seriesIndex().values) {
      final books = [for (final id in ids) _book(id)]..sort((a, b) => _numberSort(a).compareTo(_numberSort(b)));
      if (libraryId != null && (store.books[books.first['id']]!['library'] as Map?)?['id'] != libraryId) continue;
      final statuses = books.map((b) => _status(b['readProgress'] as Map<String, dynamic>?)).toList();
      if (!statuses.contains('READ') || statuses.contains('IN_PROGRESS')) continue;
      final next = books.firstWhere((b) => b['readProgress'] == null, orElse: () => <String, dynamic>{});
      if (next.isNotEmpty) picks.add(next);
    }
    return _page(picks, 0, size);
  }

  @override
  Future<Map<String, dynamic>> seriesBooks(String seriesId, {List<String>? readStatus,
      String sort = 'metadata.numberSort,asc', int page = 0, int size = 500}) async {
    final list = <dynamic>[
      for (final id in _booksOfSeries(seriesId)) _book(id),
    ].where((b) => _wanted(readStatus, _status((b as Map)['readProgress'] as Map<String, dynamic>?))).toList();
    _sort(list, sort, (m) => _sortKey(sort, m));
    return _page(list, page, size);
  }

  @override
  Future<Map<String, dynamic>> collections({String? libraryId, int page = 0, int size = 200}) async {
    final cols = <String, Map<String, dynamic>>{};
    for (final e in _done) {
      if (libraryId != null && (e.value['library'] as Map?)?['id'] != libraryId) continue;
      for (final c in (e.value['collections'] as List?) ?? []) {
        final col = cols.putIfAbsent(c['id'] as String, () => {'id': c['id'], 'name': c['name'], 'seriesIds': <String>[]});
        final sid = (e.value['book'] as Map)['seriesId'] as String;
        if (!(col['seriesIds'] as List).contains(sid)) (col['seriesIds'] as List).add(sid);
      }
    }
    final list = cols.values.toList()..sort((a, b) => '${a['name']}'.compareTo('${b['name']}'));
    return _page(list, page, size);
  }

  /// Downloaded books of a read list, in the list's order.
  List<String> _readListOrder(String readListId) {
    final withIndex = <MapEntry<String, num>>[];
    for (final e in _done) {
      for (final rl in (e.value['readLists'] as List?) ?? []) {
        if (rl['id'] == readListId) withIndex.add(MapEntry(e.key, (rl['index'] as num?) ?? 0));
      }
    }
    withIndex.sort((a, b) => a.value.compareTo(b.value));
    return [for (final e in withIndex) e.key];
  }

  Map<String, dynamic>? _readListInfo(String readListId) {
    for (final e in _done) {
      for (final rl in (e.value['readLists'] as List?) ?? []) {
        if (rl['id'] == readListId) return {'id': rl['id'], 'name': rl['name'], 'bookIds': _readListOrder(readListId)};
      }
    }
    return null;
  }

  @override
  Future<Map<String, dynamic>> readLists({String? libraryId, int page = 0, int size = 200}) async {
    final ids = <String>{};
    for (final e in _done) {
      if (libraryId != null && (e.value['library'] as Map?)?['id'] != libraryId) continue;
      for (final rl in (e.value['readLists'] as List?) ?? []) {
        ids.add(rl['id'] as String);
      }
    }
    final list = [for (final id in ids) _readListInfo(id)!]..sort((a, b) => '${a['name']}'.compareTo('${b['name']}'));
    return _page(list, page, size);
  }

  @override
  Future<Map<String, dynamic>> readListBooks(String readListId, {List<String>? readStatus, int page = 0, int size = 1000}) async {
    final list = <dynamic>[
      for (final id in _readListOrder(readListId)) _book(id),
    ].where((b) => _wanted(readStatus, _status((b as Map)['readProgress'] as Map<String, dynamic>?))).toList();
    return _page(list, page, size);
  }

  /// A collection's downloaded series. Its own order isn't kept with the downloads: by title, as Komga orders an
  /// unordered collection.
  @override
  Future<Map<String, dynamic>> collectionSeries(String collectionId, {List<String>? readStatus, int page = 0,
      int size = 60}) =>
      series(collectionId: collectionId, readStatus: readStatus, page: page, size: size);

  /// A read list's downloaded books sorted by a book field, as Komga's search does.
  @override
  Future<Map<String, dynamic>> readListBooksSorted(String readListId, String sort, {List<String>? readStatus,
      int page = 0, int size = 500}) async {
    final list = <dynamic>[
      for (final id in _readListOrder(readListId)) _book(id),
    ].where((b) => _wanted(readStatus, _status((b as Map)['readProgress'] as Map<String, dynamic>?))).toList();
    _sort(list, sort, (m) => _sortKey(sort, m));
    return _page(list, page, size);
  }

  // ---- filtered views: the same filters, on the downloads' stored Komga JSON ------------------------------------------
  static const _all = 1 << 30; // "every one": a page as big as can be

  @override
  Future<Map<String, dynamic>> filteredSeries({String? libraryId, String? collectionId,
      ReadFilter read = ReadFilter.all, ViewFilter filter = ViewFilter.none, String sort = 'metadata.titleSort,asc',
      int page = 0, int size = 60}) async {
    final f = filter.forView(seriesView: true);
    final all = (await series(libraryId: libraryId, collectionId: collectionId, readStatus: read.api, sort: sort,
        size: _all))['content'] as List;
    final index = f.isEmpty ? const <String, List<String>>{} : _seriesIndex();
    return _page([for (final s in all) if (_seriesMatches(s as Map, f, index[s['id']])) s], page, size);
  }

  @override
  Future<Map<String, dynamic>> filteredBooks({String? libraryId, String? seriesId, String? readListId,
      ReadFilter read = ReadFilter.all, ViewFilter filter = ViewFilter.none, String? sort, int page = 0,
      int? size}) async {
    final f = filter.forView(seriesView: false);
    final List<dynamic> all;
    if (seriesId != null) {
      all = (await seriesBooks(seriesId, readStatus: read.api, sort: sort ?? 'metadata.numberSort,asc',
          size: _all))['content'] as List;
    } else if (readListId != null) {
      all = List.of((await readListBooks(readListId, readStatus: read.api, size: _all))['content'] as List);
      if (sort != null && sort.startsWith('readList.number')) {
        if (sort.endsWith(',desc')) all.setAll(0, all.reversed.toList());
      } else if (sort != null) {
        _sort(all, sort, (m) => _sortKey(sort, m));
      }
    } else {
      all = (await books(libraryId: libraryId, readStatus: read.api, sort: sort ?? 'metadata.releaseDate,desc',
          size: _all))['content'] as List;
    }
    return _page([for (final b in all) if (_bookMatches(b as Map, f)) b], page,
        size ?? (seriesId != null ? 500 : readListId != null ? 1000 : 60));
  }

  static List<dynamic> _authorsOf(Map? item, String metadataKey) =>
      ((item?[metadataKey] as Map?)?['authors'] as List?) ?? const [];

  static String? _releaseDateOf(Map? item, String metadataKey) =>
      (item?[metadataKey] as Map?)?['releaseDate'] as String?;

  /// A downloaded book against the filter: its authors and release date (Komga's book JSON).
  static bool _bookMatches(Map b, ViewFilter f) {
    final authors = _authorsOf(b, 'metadata');
    return ViewFilter.authorsMatch(authors, f.writers, writerRoles) &&
        ViewFilter.authorsMatch(authors, f.artists, artistRoles) &&
        f.yearMatches(_releaseDateOf(b, 'metadata'));
  }

  /// A series against the filter, as Komga does it: the authors of its books (Komga's booksMetadata, and those of the
  /// downloaded books), its release date (its first book's), its publisher, genres and status.
  bool _seriesMatches(Map s, ViewFilter f, [List<String>? ids]) {
    if (f.isEmpty) return true;
    final books = [for (final id in ids ?? _booksOfSeries(s['id'] as String)) store.books[id]!['book'] as Map];
    final authors = [..._authorsOf(s, 'booksMetadata'), for (final b in books) ..._authorsOf(b, 'metadata')];
    final dates = [for (final b in books) _releaseDateOf(b, 'metadata')].whereType<String>().toList()..sort();
    final meta = (s['metadata'] as Map?) ?? const {};
    return ViewFilter.authorsMatch(authors, f.writers, writerRoles) &&
        ViewFilter.authorsMatch(authors, f.artists, artistRoles) &&
        f.yearMatches(_releaseDateOf(s, 'booksMetadata') ?? dates.firstOrNull) &&
        ViewFilter.oneOf(meta['publisher'], f.publishers) &&
        ViewFilter.anyIn((meta['genres'] as List?) ?? const [], f.genres) &&
        ViewFilter.oneOf(meta['status'], f.statuses);
  }

  /// The downloaded books in a view's scope (the narrowest given).
  Iterable<Map<String, dynamic>> _scoped({String? libraryId, String? collectionId, String? seriesId,
      String? readListId}) sync* {
    for (final e in _done) {
      final v = e.value;
      if (seriesId != null) {
        if ((v['book'] as Map)['seriesId'] != seriesId) continue;
      } else if (readListId != null) {
        if (!((v['readLists'] as List?) ?? const []).any((r) => (r as Map)['id'] == readListId)) continue;
      } else if (collectionId != null) {
        if (!((v['collections'] as List?) ?? const []).any((c) => (c as Map)['id'] == collectionId)) continue;
      } else if (libraryId != null && (v['library'] as Map?)?['id'] != libraryId) {
        continue;
      }
      yield v;
    }
  }

  @override
  Future<List<String>> authorNames(List<String> roles, {String? search, String? libraryId, String? collectionId,
      String? seriesId, String? readListId, int size = 1000}) async {
    final q = search?.trim().toLowerCase() ?? '';
    final names = <String, String>{};
    for (final v in _scoped(libraryId: libraryId, collectionId: collectionId, seriesId: seriesId, readListId: readListId)) {
      for (final a in _authorsOf(v['book'] as Map, 'metadata')) {
        final n = (a as Map)['name'];
        if (n is! String || n.trim().isEmpty || !roles.contains('${a['role']}'.toLowerCase())) continue;
        if (q.isNotEmpty && !n.toLowerCase().contains(q)) continue;
        names.putIfAbsent(n.toLowerCase(), () => n);
      }
    }
    return Komga.sortedValues(names.values).take(size).toList();
  }

  /// The series JSON of the downloaded books in scope, one per series.
  Iterable<Map> _scopedSeries({String? libraryId, String? collectionId}) => {
        for (final v in _scoped(libraryId: libraryId, collectionId: collectionId))
          (v['book'] as Map)['seriesId']: v['series'] as Map,
      }.values;

  @override
  Future<List<String>> publishers({String? libraryId, String? collectionId}) async => Komga.sortedValues([
        for (final s in _scopedSeries(libraryId: libraryId, collectionId: collectionId))
          if ((s['metadata'] as Map?)?['publisher'] case final String p when p.trim().isNotEmpty) p,
      ]);

  @override
  Future<List<String>> genres({String? libraryId, String? collectionId}) async => Komga.sortedValues([
        for (final s in _scopedSeries(libraryId: libraryId, collectionId: collectionId))
          for (final g in ((s['metadata'] as Map?)?['genres'] as List?) ?? const [])
            if (g is String && g.trim().isNotEmpty) g,
      ]);

  /// The downloaded books' kinds (their media profiles), in the view's scope.
  @override
  Future<ViewKind> viewKind({String? libraryId, String? seriesId, String? readListId}) async => ViewKind.ofProfiles([
        for (final v in _scoped(libraryId: libraryId, seriesId: seriesId, readListId: readListId))
          ((v['book'] as Map)['media'] as Map?)?['mediaProfile'] ?? 'DIVINA', // (no profile: a comic, as Komga's default)
      ]);

  @override
  Future<Map<String, dynamic>?> oneSeries(String id) async => _booksOfSeries(id).isEmpty ? null : _series(id);

  @override
  Future<Map<String, dynamic>?> readList(String id) async => _readListInfo(id);

  @override
  Future<Map<String, dynamic>?> book(String id) async =>
      store.books[id]?['state'] == 'done' ? _book(id) : null;

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
  @override
  Future<void> markSeriesRead(String seriesId) async {
    for (final id in _booksOfSeries(seriesId)) {
      await markRead(id);
    }
  }

  @override
  Future<void> markSeriesUnread(String seriesId) async {
    for (final id in _booksOfSeries(seriesId)) {
      await markUnread(id);
    }
  }

  // ---- next / previous: within the read list it was opened from, else the series ----------------------------------------
  List<String> _order(String bookId, String? readListId) {
    if (readListId != null) return _readListOrder(readListId);
    final sid = (store.books[bookId]?['book'] as Map?)?['seriesId'] as String?;
    if (sid == null) return [];
    return _booksOfSeries(sid)..sort((a, b) => _numberSort(store.books[a]!['book'] as Map).compareTo(_numberSort(store.books[b]!['book'] as Map)));
  }

  /// The next book only if it's downloaded: when the one that comes next isn't, this says so
  /// ([NotAvailableOffline]) rather than skipping ahead to the next one that is (user, 2026-09-29). Books downloaded
  /// before the next one was recorded fall back to the next downloaded book.
  @override
  Future<Map<String, dynamic>?> nextBook(String bookId, {String? readListId}) async {
    final entry = store.books[bookId];
    if (readListId != null) {
      Map? place(Map<String, dynamic>? e) =>
          ((e?['readLists'] as List?) ?? []).cast<Map>().where((r) => r['id'] == readListId).firstOrNull;
      final index = (place(entry)?['index'] as num?)?.toInt();
      if (index == null || index < 0) return null;
      String? at(int i) => _done.where((e) => (place(e.value)?['index'] as num?)?.toInt() == i).firstOrNull?.key;
      final next = at(index + 1);
      if (next != null) return _book(next);
      final count = (place(entry)?['count'] as num?)?.toInt();
      final later = _done.any((e) => ((place(e.value)?['index'] as num?)?.toInt() ?? -1) > index + 1);
      if (count != null ? index + 1 >= count : !later) return null; // the list's last book (or can't tell)
      throw NotAvailableOffline('The next book');
    }
    if (entry != null && entry.containsKey('nextId')) {
      final next = entry['nextId'] as String?;
      if (next == null) return null; // the series' last book
      if (store.books[next]?['state'] == 'done') return _book(next);
      throw NotAvailableOffline('The next book');
    }
    final order = _order(bookId, readListId);
    final i = order.indexOf(bookId);
    return i >= 0 && i + 1 < order.length ? _book(order[i + 1]) : null;
  }

  @override
  Future<Map<String, dynamic>?> previousBook(String bookId, {String? readListId}) async {
    final order = _order(bookId, readListId);
    final i = order.indexOf(bookId);
    return i > 0 ? _book(order[i - 1]) : null;
  }

  // ---- search: titles of the downloaded books, series, lists and collections -----------------------------------------------
  static bool _matches(String query, Iterable<Object?> fields) {
    final q = query.toLowerCase().trim();
    return q.isNotEmpty && fields.any((f) => f != null && '$f'.toLowerCase().contains(q));
  }

  @override
  Future<Map<String, dynamic>> searchSeries(String query, {String? libraryId, int size = 30}) async {
    final all = (await series(libraryId: libraryId, size: 100000))['content'] as List;
    return _page([for (final s in all) if (_matches(query, [s['name'], (s['metadata'] as Map?)?['title']])) s], 0, size);
  }

  @override
  Future<Map<String, dynamic>> searchBooks(String query, {String? libraryId, int size = 30}) async {
    final all = (await books(libraryId: libraryId, sort: 'metadata.title,asc', size: 100000))['content'] as List;
    return _page([
      for (final b in all)
        if (_matches(query, [b['name'], b['seriesTitle'], (b['metadata'] as Map?)?['title']])) b,
    ], 0, size);
  }

  @override
  Future<Map<String, dynamic>> booksOfSeries(List<String> seriesIds, {int size = 300}) async {
    final all = (await books(sort: 'metadata.numberSort,asc', size: 100000))['content'] as List;
    return _page([for (final b in all) if (seriesIds.contains(b['seriesId'])) b], 0, size);
  }

  @override
  Future<Map<String, dynamic>> searchReadLists(String query, {String? libraryId, int size = 30}) async {
    final all = (await readLists(libraryId: libraryId, size: 100000))['content'] as List;
    return _page([for (final r in all) if (_matches(query, [r['name']])) r], 0, size);
  }

  @override
  Future<Map<String, dynamic>> searchCollections(String query, {String? libraryId, int size = 30}) async {
    final all = (await collections(libraryId: libraryId, size: 100000))['content'] as List;
    return _page([for (final c in all) if (_matches(query, [c['name']])) c], 0, size);
  }

  // ---- needs the server --------------------------------------------------------------------------------------------------
  @override
  Future<Map<String, dynamic>> clientSettings() async => throw KomgaUnreachable(baseUrl);
  @override
  Future<void> putClientSetting(String key, String value) async => throw KomgaUnreachable(baseUrl);
  @override
  Future<void> deleteBookFile(String bookId) async => throw NotAvailableOffline('Deleting a book');
  @override
  Future<void> renameReadList(String id, String name) async => throw NotAvailableOffline('Renaming a read list');
  @override
  Future<void> renameCollection(String id, String name) async => throw NotAvailableOffline('Renaming a collection');
  @override
  Future<void> deleteSeriesFiles(String seriesId) async => throw NotAvailableOffline('Deleting a series');
}

/// The offline source's HTTP client: holds no sockets, and anything that would go to the server fails as unreachable.
class _NoNetwork extends http.BaseClient {
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async =>
      throw http.ClientException('offline: nothing goes to the server', request.url);
}
