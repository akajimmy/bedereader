import 'dart:typed_data';

import 'package:komga_reader/api.dart';

import 'no_network.dart';

/// A Komga for downloading: two books of 3 pages (100 bytes each; [pageCount] to change), B1 and B2, in series S1
/// ("Silver Surfer"), library L1 ("Archive"), read list RL1 and collection C1. Answers [me] while [up] (the
/// reachability check).
/// Build with `noNetwork(LibraryServer.new)`.
///
/// Was downloads_test's FakeKomga, imported from there by five other test files (test audit, 2026-09-30).
class LibraryServer extends TestKomga {
  /// [baseUrl]: another server's address (per-server download folders).
  LibraryServer([super.baseUrl]);

  int pageRequests = 0;
  bool slow = false;
  void Function(int number)? onPage; // called after serving a page (tests use it to pause at an exact point)

  Map<String, dynamic> _book(String id, int n) => {
        'id': id, 'seriesId': 'S1', 'seriesTitle': 'Silver Surfer', 'libraryId': 'L1', 'name': id,
        'metadata': {'title': 'T$id', 'number': '$n', 'numberSort': n}, 'media': {'pagesCount': 3}, 'sizeBytes': 300,
        'readProgress': id == 'B1' ? {'page': 2, 'completed': false} : null,
      };

  bool booksFail = false; // book requests answered with Komga's own error (HTTP 500): the download fails
  @override
  Future<Map<String, dynamic>?> book(String id) async {
    if (booksFail) throw KomgaError(500, '/api/v1/books/$id');
    return _book(id, id == 'B1' ? 1 : 2);
  }
  @override
  Future<List<dynamic>> pages(String bookId) async =>
      [for (var n = 1; n <= pageCount; n++) {'number': n, 'mediaType': 'image/jpeg', 'sizeBytes': 100}];
  int pageCount = 3; // more than 5: the worker's every-5-pages checks (Wi-Fi) happen mid-book
  bool pagesDown = false; // pages can't be fetched (Komga or the network gone)
  @override
  Future<Uint8List> pageBytes(String bookId, int number) async {
    if (pagesDown) throw KomgaUnreachable(baseUrl);
    pageRequests++;
    if (slow) await Future<void>.delayed(const Duration(milliseconds: 20));
    onPage?.call(number);
    return Uint8List(100);
  }

  @override
  Future<Map<String, dynamic>?> oneSeries(String id) async => {'id': id, 'name': 'Silver Surfer', 'metadata': {'title': 'Silver Surfer'}};
  @override
  Future<List<dynamic>> libraries() async => [{'id': 'L1', 'name': 'Archive'}];
  @override
  Future<List<dynamic>> bookReadLists(String bookId) async => [{'id': 'RL1', 'name': 'Cosmic', 'bookIds': ['B0', bookId]}];
  @override
  Future<List<dynamic>> seriesCollections(String seriesId) async => [{'id': 'C1', 'name': 'Marvel cosmic'}];
  @override
  Future<Uint8List?> thumbBytes(String url) async => Uint8List(10);
  @override
  Future<Map<String, dynamic>?> nextBook(String bookId, {String? readListId}) async =>
      bookId == 'B1' ? _book('B2', 2) : null; // B2 is the series' last

  /// Reachability check: answers while [up], else "can't reach" - reported like every real server call.
  bool up = true;
  int meCalls = 0; // how often Komga was asked whether it's there
  @override
  Future<Map<String, dynamic>?> me() async {
    meCalls++;
    Komga.onReachability?.call(this, up);
    if (!up) throw KomgaUnreachable(baseUrl);
    return {'id': 'U1'};
  }
}
