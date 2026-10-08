import 'package:komga_reader/api.dart';

import 'no_network.dart';

/// A library (L1 "Events") to browse: [seriesCount] series (S1, S2, ... titled "Series 1", ...), three books - B1
/// read, B2 unread, B3 half read - one collection (C1, of S1) and three read lists. Answers in pages, honours the read filter, the library and the collection, records
/// what was asked and the sort it asked for, and deletes books (those in [failing] answer HTTP 403, as for a
/// non-admin account). A series' own books: none.
class BrowseServer extends TestKomga {
  BrowseServer({this.seriesCount = 3});
  final int seriesCount;

  final requests = <String>[]; // "series p0 all", "series C1 p0 UNREAD+IN_PROGRESS", "books p0 READ", ...
  final sorts = <String>[]; // the sort each series, books and series-books request asked for
  int libraryCalls = 0;
  final deleted = <String>[];
  final failing = <String>{};
  final shelf = <Map<String, dynamic>>[
    _book('B1', 1, {'completed': true, 'page': 10}),
    _book('B2', 2, null),
    _book('B3', 3, {'completed': false, 'page': 5}),
  ];

  static Map<String, dynamic> _book(String id, int n, Map<String, dynamic>? progress) => {
        'id': id, 'seriesId': 'S1', 'seriesTitle': 'Saga', 'name': id, 'metadata': {'number': '$n', 'title': 'T$id'},
        'media': {'pagesCount': 10}, 'readProgress': progress,
      };

  /// One Komga page of [all].
  Map<String, dynamic> _page(List<Map<String, dynamic>> all, int page, int size) {
    final from = (page * size).clamp(0, all.length), to = ((page + 1) * size).clamp(0, all.length);
    return {'content': all.sublist(from, to), 'totalElements': all.length, 'last': to >= all.length};
  }

  static String _filter(List<String>? readStatus) => readStatus == null ? 'all' : readStatus.join('+');

  @override
  Future<List<dynamic>> libraries() async {
    libraryCalls++;
    return [{'id': 'L1', 'name': 'Events'}];
  }

  /// [libraryId]: another library than L1 has nothing; [collectionId]: C1 has S1, any other nothing.
  @override
  Future<Map<String, dynamic>> series({String? libraryId, String? collectionId, List<String>? readStatus,
      String sort = 'metadata.titleSort,asc', int page = 0, int size = 60}) async {
    requests.add('series ${collectionId == null ? '' : '$collectionId '}p$page ${_filter(readStatus)}');
    sorts.add(sort);
    if (readStatus != null && !readStatus.contains('UNREAD')) return _page([], page, size); // (all of them unread)
    return _page([
      for (var i = 1; i <= seriesCount; i++)
        if ((libraryId ?? 'L1') == 'L1' && (collectionId == null || (collectionId == 'C1' && i == 1)))
          {'id': 'S$i', 'name': 'Series $i', 'libraryId': 'L1', 'metadata': {'title': 'Series $i'}, 'booksCount': 1,
              'booksUnreadCount': 1, 'booksInProgressCount': 0},
    ], page, size);
  }

  @override
  Future<Map<String, dynamic>> books({String? libraryId, List<String>? readStatus,
      String sort = 'metadata.releaseDate,desc', int page = 0, int size = 60}) async {
    requests.add('books p$page ${_filter(readStatus)}');
    sorts.add(sort);
    return _page([for (final b in shelf) if ((libraryId ?? 'L1') == 'L1' && _wanted(b, readStatus)) b], page, size);
  }

  /// A series' books: none (the series screen still asks, in its sort).
  @override
  Future<Map<String, dynamic>> seriesBooks(String seriesId, {List<String>? readStatus,
      String sort = 'metadata.numberSort,asc', int page = 0, int size = 500}) async {
    requests.add('seriesBooks $seriesId p$page ${_filter(readStatus)}');
    sorts.add(sort);
    return _page([], page, size);
  }

  /// Komga's read status of a book, against a read_status filter.
  static bool _wanted(Map<String, dynamic> b, List<String>? readStatus) {
    final rp = b['readProgress'] as Map?;
    final status = rp == null ? 'UNREAD' : rp['completed'] == true ? 'READ' : 'IN_PROGRESS';
    return readStatus == null || readStatus.contains(status);
  }

  @override
  Future<Map<String, dynamic>> collections({String? libraryId, int page = 0, int size = 200}) async {
    requests.add('collections p$page');
    return _page([{'id': 'C1', 'name': 'Marvel cosmic', 'seriesIds': ['S1']}], page, size);
  }

  @override
  Future<Map<String, dynamic>> readLists({String? libraryId, int page = 0, int size = 200}) async {
    requests.add('readLists p$page');
    return _page([
      {'id': 'RL1', 'name': 'Infinity', 'bookIds': ['B1']},
      {'id': 'RL2', 'name': 'Done', 'bookIds': ['B1']}, // all read
      {'id': 'RL3', 'name': 'Fresh', 'bookIds': ['B2']}, // nothing read
    ], page, size);
  }

  /// Read lists' books, filtered as Komga does (RL1: none, as before - the breadcrumb tests open it).
  @override
  Future<Map<String, dynamic>> readListBooks(String readListId, {List<String>? readStatus, int page = 0,
      int size = 1000}) async {
    final ids = switch (readListId) { 'RL2' => ['B1'], 'RL3' => ['B2'], _ => <String>[] };
    final books = [for (final b in shelf) if (ids.contains(b['id']) && _wanted(b, readStatus)) b];
    return {..._page(books, page, size)};
  }

  @override
  Future<void> deleteBookFile(String bookId) async {
    if (failing.contains(bookId)) throw KomgaError(403, '/api/v1/books/$bookId/file');
    deleted.add(bookId);
    shelf.removeWhere((b) => b['id'] == bookId);
  }
}
