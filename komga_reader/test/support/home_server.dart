import 'helpers.dart';
import 'no_network.dart';

/// What Home and the side menu ask for: one library (L1 "Events"), Continue reading [inProgressBooks] and On deck
/// [onDeckBooks] (empty unless given), one recently added book ("New Series #1", recording the sort each books request
/// asks for), no series. Build with `noNetwork(HomeServer.new)` or `noNetwork(() => HomeServer(...))`.
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

  final booksSorts = <String>[];
  @override
  Future<Map<String, dynamic>> books({String? libraryId, List<String>? readStatus,
      String sort = 'metadata.releaseDate,desc', int page = 0, int size = 60}) async {
    booksSorts.add(sort);
    return onePage([
      {'id': 'N1', 'seriesTitle': 'New Series', 'name': 'n1', 'metadata': {'number': '1', 'title': 'Fresh'}},
    ]);
  }

  @override
  Future<Map<String, dynamic>> series({String? libraryId, String? collectionId, List<String>? readStatus,
          String sort = 'metadata.titleSort,asc', int page = 0, int size = 60}) async =>
      onePage([]);
}
