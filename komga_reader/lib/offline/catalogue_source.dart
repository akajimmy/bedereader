import '../api.dart' show Komga;
import '../book_source.dart';
import '../hidden_libraries.dart';
import '../view_filter.dart';
import 'catalogue.dart';

/// Thrown for things that need the server (deleting files, ...) while offline.
class NotAvailableOffline implements Exception {
  NotAvailableOffline(this.what);
  final String what;
  @override
  String toString() => '$what is not available offline';
}

/// Thrown for what only Komga can do (deleting files, renaming, ...) asked of a book in a local library.
class NeedsKomga implements Exception {
  NeedsKomga(this.what);
  final String what;
  @override
  String toString() => '$what needs Komga';
}

/// A source answering from books held on this device - the downloads (downloads_source.dart) and the local libraries:
/// libraries, series, books, read lists, collections, On deck, filters, search, next and previous, all from one
/// [Catalogue] of [entries] per question. What's the source's own - pages, posters, saving progress, EPUBs, what only
/// a server has - each source answers itself.
abstract class CatalogueSource implements BookSource {
  /// bookId -> its entry: Komga's JSON for the book, its series and library, the read lists and collections it's in,
  /// and 'state' ('done': there to read).
  Map<String, Map<String, dynamic>> get entries;

  /// The book's reading progress as Komga would give it (null: never opened, or marked unread).
  Map<String, dynamic>? readProgressOf(String bookId);

  // ---- helpers ------------------------------------------------------------------------------------------------------
  // the books held here - those in a library hidden on this device left out, as online
  Catalogue get _catalogue => Catalogue(entries, hidden: HiddenLibraries.instance.isHidden);

  /// The book as Komga would return it, with the progress made on this device.
  Map<String, dynamic> _book(String id) {
    final b = Map<String, dynamic>.from(entries[id]!['book'] as Map);
    b['readProgress'] = readProgressOf(id);
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
  static void _sort(List<dynamic> list, String sort, dynamic Function(Map item) key) =>
      list.sort((a, b) => _compare(sort, key(a as Map), key(b as Map)));

  static int _compare(String sort, Object? ka, Object? kb) {
    final c = (ka is num && kb is num) ? ka.compareTo(kb) : '${ka ?? ''}'.toLowerCase().compareTo('${kb ?? ''}'.toLowerCase());
    return sort.endsWith(',desc') ? -c : c;
  }

  /// The order of a Komga sort param "field,dir", for two items (Komga's JSON) - for merging two sources' lists.
  static int Function(Map a, Map b) comparator(String sort) =>
      (a, b) => _compare(sort, _sortKey(sort, a), _sortKey(sort, b));

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

  /// Series as Komga would return it, with book counts for the books held here only.
  Map<String, dynamic> _series(List<CatalogueBook> books) {
    final s = Map<String, dynamic>.from(books.first.entry['series'] as Map);
    var unread = 0, inProgress = 0, read = 0;
    for (final b in books) {
      switch (_status(readProgressOf(b.id))) {
        case 'UNREAD':
          unread++;
        case 'IN_PROGRESS':
          inProgress++;
        default:
          read++;
      }
    }
    s['booksCount'] = books.length;
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

  // ---- libraries -------------------------------------------------------------------------------------------------
  @override
  Future<List<dynamic>> libraries() async {
    final libs = <String, Map<String, dynamic>>{};
    for (final b in _catalogue.books) {
      final l = b.entry['library'] as Map?;
      if (l != null) libs[l['id'] as String] = Map<String, dynamic>.from(l);
    }
    return libs.values.toList()..sort((a, b) => '${a['name']}'.compareTo('${b['name']}'));
  }

  @override
  Future<List<dynamic>> keptLibraries() => libraries(); // read from the device each time: nothing to keep

  @override
  void forgetLibraries() {} // (nothing kept)

  @override
  Future<String?> libraryName(String? id) async {
    if (id == null) return null;
    for (final l in await libraries()) {
      if (l['id'] == id) return l['name'] as String?;
    }
    return null;
  }

  @override
  Future<List<dynamic>> visibleLibraries({bool kept = false}) async =>
      [for (final l in await libraries()) if (!HiddenLibraries.instance.isHidden(l['id'] as String?)) l];

  // ---- browsing ------------------------------------------------------------------------------------------------------
  @override
  Future<Map<String, dynamic>> series({String? libraryId, String? collectionId, List<String>? readStatus,
      String sort = 'metadata.titleSort,asc', int page = 0, int size = 60}) async =>
      _page(_seriesList(_catalogue, libraryId, collectionId, readStatus, sort), page, size);

  List<dynamic> _seriesList(Catalogue c, String? libraryId, String? collectionId, List<String>? readStatus,
      String sort) {
    final ids = <String>{
      for (final b in c.scoped(libraryId: libraryId, collectionId: collectionId))
        if (libraryId == null || b.libraryId == libraryId) b.seriesId,
    };
    final list = <dynamic>[
      for (final id in ids) _series(c.bySeries[id]!),
    ].where((s) => _wanted(readStatus, _seriesStatus(s as Map<String, dynamic>))).toList();
    _sort(list, sort, (m) => _sortKey(sort, m));
    return list;
  }

  @override
  Future<Map<String, dynamic>> books({String? libraryId, List<String>? readStatus,
      String sort = 'metadata.releaseDate,desc', int page = 0, int size = 60}) async {
    final list = <dynamic>[
      for (final b in _catalogue.scoped(libraryId: libraryId)) _book(b.id),
    ].where((b) => _wanted(readStatus, _status((b as Map)['readProgress'] as Map<String, dynamic>?))).toList();
    _sort(list, sort, (m) => _sortKey(sort, m));
    return _page(list, page, size);
  }

  /// Books you are part-way through, most recently read first.
  @override
  Future<Map<String, dynamic>> inProgress({String? libraryId, int size = 30}) =>
      books(libraryId: libraryId, readStatus: const ['IN_PROGRESS'], sort: 'readProgress.readDate,desc', size: size);

  @override
  Future<Map<String, dynamic>> onDeck({String? libraryId, int size = 30}) async {
    // the next unread book of series that have been started and have nothing in progress
    final c = _catalogue;
    final picks = <dynamic>[];
    for (final sid in c.bySeries.keys) {
      final inOrder = c.seriesInOrder(sid);
      if (libraryId != null && inOrder.first.libraryId != libraryId) continue;
      final books = [for (final b in inOrder) _book(b.id)];
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
      for (final b in _catalogue.scoped(seriesId: seriesId)) _book(b.id),
    ].where((b) => _wanted(readStatus, _status((b as Map)['readProgress'] as Map<String, dynamic>?))).toList();
    _sort(list, sort, (m) => _sortKey(sort, m));
    return _page(list, page, size);
  }

  @override
  Future<Map<String, dynamic>> collections({String? libraryId, int page = 0, int size = 200}) async {
    final cols = <String, Map<String, dynamic>>{};
    for (final b in _catalogue.scoped(libraryId: libraryId)) {
      for (final c in b.collections) {
        final col = cols.putIfAbsent(c['id'] as String, () => {'id': c['id'], 'name': c['name'], 'seriesIds': <String>[]});
        if (!(col['seriesIds'] as List).contains(b.seriesId)) (col['seriesIds'] as List).add(b.seriesId);
      }
    }
    final list = cols.values.toList()..sort((a, b) => '${a['name']}'.compareTo('${b['name']}'));
    return _page(list, page, size);
  }

  /// A read list as Komga gives it: the ids of its books held here, in the list's order.
  static Map<String, dynamic>? _readListInfo(Catalogue c, String readListId) => c.readListNames.containsKey(readListId)
      ? {'id': readListId, 'name': c.readListNames[readListId], 'bookIds': [for (final b in c.readList(readListId)) b.id]}
      : null;

  @override
  Future<Map<String, dynamic>> readLists({String? libraryId, int page = 0, int size = 200}) async {
    final c = _catalogue;
    final ids = <String>{
      for (final b in c.scoped(libraryId: libraryId))
        for (final r in b.readLists) r['id'] as String,
    };
    final list = [for (final id in ids) _readListInfo(c, id)!]..sort((a, b) => '${a['name']}'.compareTo('${b['name']}'));
    return _page(list, page, size);
  }

  @override
  Future<Map<String, dynamic>> readListBooks(String readListId, {List<String>? readStatus, int page = 0, int size = 1000}) async {
    final list = <dynamic>[
      for (final b in _catalogue.readList(readListId)) _book(b.id),
    ].where((b) => _wanted(readStatus, _status((b as Map)['readProgress'] as Map<String, dynamic>?))).toList();
    return _page(list, page, size);
  }

  /// A collection's series held here. Its own order isn't kept here: by title, as Komga orders an
  /// unordered collection.
  @override
  Future<Map<String, dynamic>> collectionSeries(String collectionId, {List<String>? readStatus, int page = 0,
      int size = 60}) =>
      series(collectionId: collectionId, readStatus: readStatus, page: page, size: size);

  /// A read list's books held here sorted by a book field, as Komga's search does.
  @override
  Future<Map<String, dynamic>> readListBooksSorted(String readListId, String sort, {List<String>? readStatus,
      int page = 0, int size = 500}) async {
    final list = <dynamic>[
      for (final b in _catalogue.readList(readListId)) _book(b.id),
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
    final c = _catalogue; // (one for the list and the filter)
    final all = _seriesList(c, libraryId, collectionId, read.api, sort);
    if (f.isEmpty) return _page(all, page, size);
    return _page([for (final s in all) if (_seriesMatches(s as Map, f, c.bySeries[s['id']] ?? const [])) s], page,
        size);
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

  /// A book against the filter: its authors and release date (Komga's book JSON).
  static bool _bookMatches(Map b, ViewFilter f) {
    final authors = _authorsOf(b, 'metadata');
    return ViewFilter.authorsMatch(authors, f.writers, writerRoles) &&
        ViewFilter.authorsMatch(authors, f.artists, artistRoles) &&
        f.yearMatches(_releaseDateOf(b, 'metadata'));
  }

  /// A series against the filter, as Komga does it: the authors of its books (Komga's booksMetadata, and those of the
  /// books held here), its release date (its first book's), its publisher, genres and status.
  static bool _seriesMatches(Map s, ViewFilter f, List<CatalogueBook> books) {
    final authors = [..._authorsOf(s, 'booksMetadata'), for (final b in books) ..._authorsOf(b.book, 'metadata')];
    final dates = [for (final b in books) _releaseDateOf(b.book, 'metadata')].whereType<String>().toList()..sort();
    final meta = (s['metadata'] as Map?) ?? const {};
    return ViewFilter.authorsMatch(authors, f.writers, writerRoles) &&
        ViewFilter.authorsMatch(authors, f.artists, artistRoles) &&
        f.yearMatches(_releaseDateOf(s, 'booksMetadata') ?? dates.firstOrNull) &&
        ViewFilter.oneOf(meta['publisher'], f.publishers) &&
        ViewFilter.anyIn((meta['genres'] as List?) ?? const [], f.genres) &&
        ViewFilter.oneOf(meta['status'], f.statuses);
  }

  @override
  Future<List<String>> authorNames(List<String> roles, {String? search, String? libraryId, String? collectionId,
      String? seriesId, String? readListId, int size = 1000}) async {
    final q = search?.trim().toLowerCase() ?? '';
    final names = <String, String>{};
    final scope = _catalogue.scoped(libraryId: libraryId, collectionId: collectionId, seriesId: seriesId,
        readListId: readListId);
    for (final b in scope) {
      for (final a in _authorsOf(b.book, 'metadata')) {
        final n = (a as Map)['name'];
        if (n is! String || n.trim().isEmpty || !roles.contains('${a['role']}'.toLowerCase())) continue;
        if (q.isNotEmpty && !n.toLowerCase().contains(q)) continue;
        names.putIfAbsent(n.toLowerCase(), () => n);
      }
    }
    return Komga.sortedValues(names.values).take(size).toList();
  }

  /// The series JSON of the books held here in scope, one per series.
  Iterable<Map> _scopedSeries({String? libraryId, String? collectionId}) => {
        for (final b in _catalogue.scoped(libraryId: libraryId, collectionId: collectionId))
          b.seriesId: b.entry['series'] as Map,
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

  /// The kinds (media profiles) of the books held here, in the view's scope.
  @override
  Future<ViewKind> viewKind({String? libraryId, String? seriesId, String? readListId}) async => ViewKind.ofProfiles([
        for (final b in _catalogue.scoped(libraryId: libraryId, seriesId: seriesId, readListId: readListId))
          (b.book['media'] as Map?)?['mediaProfile'] ?? 'DIVINA', // (no profile: a comic, as Komga's default)
      ]);

  @override
  Future<Map<String, dynamic>?> oneSeries(String id) async {
    final books = _catalogue.bySeries[id];
    return books == null ? null : _series(books);
  }

  @override
  Future<Map<String, dynamic>?> readList(String id) async => _readListInfo(_catalogue, id);

  @override
  Future<Map<String, dynamic>?> book(String id) async =>
      entries[id]?['state'] == 'done' ? _book(id) : null;

  @override
  Future<void> markSeriesRead(String seriesId) async {
    for (final b in [...?_catalogue.bySeries[seriesId]]) {
      await markRead(b.id);
    }
  }

  @override
  Future<void> markSeriesUnread(String seriesId) async {
    for (final b in [...?_catalogue.bySeries[seriesId]]) {
      await markUnread(b.id);
    }
  }

  // ---- next / previous: within the read list it was opened from, else the series ----------------------------------------
  List<String> _order(Catalogue c, String bookId, String? readListId) {
    if (readListId != null) return [for (final b in c.readList(readListId)) b.id];
    final sid = (entries[bookId]?['book'] as Map?)?['seriesId'] as String?;
    if (sid == null) return [];
    return [for (final b in c.seriesInOrder(sid)) b.id];
  }

  /// The next book only if it's downloaded: when the one that comes next isn't, this says so
  /// ([NotAvailableOffline]) rather than skipping ahead to the next one that is (user, 2026-09-29). Books downloaded
  /// before the next one was recorded fall back to the next downloaded book.
  @override
  Future<Map<String, dynamic>?> nextBook(String bookId, {String? readListId}) async {
    final entry = entries[bookId];
    final c = _catalogue;
    if (readListId != null) {
      Map? place(Map<String, dynamic>? e) =>
          ((e?['readLists'] as List?) ?? []).cast<Map>().where((r) => r['id'] == readListId).firstOrNull;
      final index = (place(entry)?['index'] as num?)?.toInt();
      if (index == null || index < 0) return null;
      final inList = c.scoped(readListId: readListId);
      final next = inList.where((b) => b.placeIn(readListId)?.toInt() == index + 1).firstOrNull;
      if (next != null) return _book(next.id);
      final count = (place(entry)?['count'] as num?)?.toInt();
      final later = inList.any((b) => (b.placeIn(readListId)?.toInt() ?? -1) > index + 1);
      if (count != null ? index + 1 >= count : !later) return null; // the list's last book (or can't tell)
      throw NotAvailableOffline('The next book');
    }
    if (entry != null && entry.containsKey('nextId')) {
      final next = entry['nextId'] as String?;
      if (next == null) return null; // the series' last book
      if (entries[next]?['state'] == 'done') return _book(next);
      throw NotAvailableOffline('The next book');
    }
    final order = _order(c, bookId, null); // (a read list's next is found above)
    final i = order.indexOf(bookId);
    return i >= 0 && i + 1 < order.length ? _book(order[i + 1]) : null;
  }

  @override
  Future<Map<String, dynamic>?> previousBook(String bookId, {String? readListId}) async {
    final order = _order(_catalogue, bookId, readListId);
    final i = order.indexOf(bookId);
    return i > 0 ? _book(order[i - 1]) : null;
  }

  // ---- search: titles of the books held here, series, lists and collections -----------------------------------------------
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

}
