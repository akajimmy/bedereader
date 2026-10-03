import 'package:komga_reader/api.dart';

import 'helpers.dart';
import 'no_network.dart';

/// A library (L1 "Events") to browse: [seriesCount] series (S1, S2, ... titled "Series 1", ...), three books - B1
/// read, B2 unread, B3 half read - one collection and one read list. Answers in pages, honours the read filter,
/// records what was asked, and deletes books (those in [failing] answer HTTP 403, as for a non-admin account).
class BrowseServer extends TestKomga {
  BrowseServer({this.seriesCount = 3});
  final int seriesCount;

  final requests = <String>[]; // "series p0 all", "books p0 hideRead", ...
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
  Future<List<dynamic>> libraries() async => [{'id': 'L1', 'name': 'Events'}];

  @override
  Future<Map<String, dynamic>> series({String? libraryId, String? collectionId, List<String>? readStatus,
      String sort = 'metadata.titleSort,asc', int page = 0, int size = 60}) async {
    requests.add('series p$page ${_filter(readStatus)}');
    return _page([
      for (var i = 1; i <= seriesCount; i++)
        {'id': 'S$i', 'name': 'Series $i', 'libraryId': 'L1', 'metadata': {'title': 'Series $i'}, 'booksCount': 1, 'booksUnreadCount': 1,
            'booksInProgressCount': 0},
    ], page, size);
  }

  @override
  Future<Map<String, dynamic>> books({String? libraryId, List<String>? readStatus,
      String sort = 'metadata.releaseDate,desc', int page = 0, int size = 60}) async {
    requests.add('books p$page ${_filter(readStatus)}');
    bool unread(Map<String, dynamic> b) => b['readProgress']?['completed'] != true;
    return _page([for (final b in shelf) if (readStatus == null || unread(b)) b], page, size);
  }

  @override
  Future<Map<String, dynamic>> collections({String? libraryId, int page = 0, int size = 200}) async {
    requests.add('collections p$page');
    return _page([{'id': 'C1', 'name': 'Marvel cosmic', 'seriesIds': ['S1']}], page, size);
  }

  @override
  Future<Map<String, dynamic>> readLists({String? libraryId, int page = 0, int size = 200}) async {
    requests.add('readLists p$page');
    return _page([{'id': 'RL1', 'name': 'Infinity', 'bookIds': ['B1']}], page, size);
  }

  @override
  Future<Map<String, dynamic>> readListBooks(String readListId, {List<String>? readStatus, int page = 0,
          int size = 1000}) async =>
      onePage([]); // the read list poster's books

  @override
  Future<void> deleteBookFile(String bookId) async {
    if (failing.contains(bookId)) throw KomgaError(403, '/api/v1/books/$bookId/file');
    deleted.add(bookId);
    shelf.removeWhere((b) => b['id'] == bookId);
  }
}
