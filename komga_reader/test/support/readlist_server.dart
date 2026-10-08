import 'no_network.dart';

/// A book of a read list: series "S", number [id] (shown "S #id"), 20 pages - unread, [read], or in progress at [page].
Map<String, dynamic> listBook(String id, {bool read = false, int? page}) => {
      'id': id, 'seriesTitle': 'S', 'name': id, 'metadata': {'number': id, 'title': 'T$id'},
      'media': {'pagesCount': 20},
      'readProgress': read ? {'completed': true, 'page': 20} : page != null ? {'completed': false, 'page': page} : null,
    };

/// A read list (whichever is asked for) of [list]. Answers each page as Komga does - `size` books from `page * size`,
/// last only on the final page - honours the read filter, records what was asked ([asked]: "UNREAD p0", "all p1") and
/// the books marked read / unread. Build with `noNetwork(() => ReadListServer([...]))`.
///
/// One copy of readlist_test's two fakes and select_test's (test audit, 2026-10-07).
class ReadListServer extends TestKomga {
  ReadListServer(this.list);
  final List<Map<String, dynamic>> list;
  final asked = <String>[], readCalls = <String>[], unreadCalls = <String>[];

  /// Komga's read status of a book.
  static String status(Map<String, dynamic> b) {
    final rp = b['readProgress'] as Map?;
    return rp == null ? 'UNREAD' : rp['completed'] == true ? 'READ' : 'IN_PROGRESS';
  }

  @override
  Future<Map<String, dynamic>> readListBooks(String readListId, {List<String>? readStatus, int page = 0,
      int size = 1000}) async {
    asked.add('${readStatus?.join('+') ?? 'all'} p$page');
    final match = [for (final b in list) if (readStatus == null || readStatus.contains(status(b))) b];
    final from = (page * size).clamp(0, match.length), to = ((page + 1) * size).clamp(0, match.length);
    return {'content': match.sublist(from, to), 'totalElements': match.length, 'last': to >= match.length};
  }

  @override
  Future<void> markRead(String bookId) async => readCalls.add(bookId);
  @override
  Future<void> markUnread(String bookId) async => unreadCalls.add(bookId);
}
