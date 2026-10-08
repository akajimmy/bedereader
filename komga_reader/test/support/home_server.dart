import 'helpers.dart';
import 'no_network.dart';

/// What Home and the side menu ask for: one library (L1 "Events"), Continue reading [inProgressBooks] and On deck
/// [onDeckBooks] (empty unless given), no other books, no series. Build with `noNetwork(HomeServer.new)` or
/// `noNetwork(() => HomeServer(...))`.
///
/// Was home_test's FakeKomga (imported by dock_test, row_arrows_test and ondeck_hidden_test, which subclassed it for
/// their lists) and drawer_edge_test's libraries-only copy (test audit, 2026-09-30).
class HomeServer extends TestKomga {
  HomeServer({this.inProgressBooks = const [], this.onDeckBooks = const []});
  final List<Map<String, dynamic>> inProgressBooks, onDeckBooks;

  @override
  Future<List<dynamic>> libraries() async => [{'id': 'L1', 'name': 'Events'}];
  @override
  Future<Map<String, dynamic>> inProgress({String? libraryId, int size = 30}) async => onePage(inProgressBooks);
  @override
  Future<Map<String, dynamic>> onDeck({String? libraryId, int size = 30}) async => onePage(onDeckBooks);

  @override
  Future<Map<String, dynamic>> books({String? libraryId, List<String>? readStatus,
          String sort = 'metadata.releaseDate,desc', int page = 0, int size = 60}) async =>
      onePage([]);

  @override
  Future<Map<String, dynamic>> series({String? libraryId, String? collectionId, List<String>? readStatus,
          String sort = 'metadata.titleSort,asc', int page = 0, int size = 60}) async =>
      onePage([]);
}
