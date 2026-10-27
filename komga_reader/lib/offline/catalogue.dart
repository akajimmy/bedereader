/// One book in a [Catalogue]: its ids and number pulled out of its entry once, and the entry itself (Komga's JSON for
/// the book, its series and library, the read lists and collections it's in - lib/offline/store.dart).
class CatalogueBook {
  CatalogueBook._(this.id, this.entry)
      : book = entry['book'] as Map,
        seriesId = (entry['book'] as Map)['seriesId'] as String,
        libraryId = (entry['library'] as Map?)?['id'] as String?,
        numberSort = (((entry['book'] as Map)['metadata'] as Map?)?['numberSort'] as num?) ?? 0;

  final String id;
  final Map<String, dynamic> entry;
  final Map book;
  final String seriesId;
  final String? libraryId;
  final num numberSort;

  List<Map> get readLists => ((entry['readLists'] as List?) ?? const []).cast<Map>();
  List<Map> get collections => ((entry['collections'] as List?) ?? const []).cast<Map>();

  /// Its place in read list [readListId] (null: not in it).
  num? placeIn(String readListId) {
    for (final r in readLists) {
      if (r['id'] == readListId) return (r['index'] as num?) ?? 0;
    }
    return null;
  }
}

/// The books held on this device - the downloads, read without Komga - indexed in one walk over them: by series, by
/// read list (in the list's order), and what libraries, collections and read lists there are. Made afresh for each
/// question (a walk, not one per series or list: a list of series used to walk every book once per series - 11 s for
/// 1,098 series and 8,843 books on the tablet), so it always says what the store holds now.
///
/// Only finished books ('done'), and none in a library hidden on this device ([hidden]), as online.
class Catalogue {
  Catalogue(Map<String, Map<String, dynamic>> entries, {bool Function(String? libraryId)? hidden}) {
    for (final MapEntry(key: id, value: e) in entries.entries) {
      if (e['state'] != 'done') continue;
      final b = CatalogueBook._(id, e);
      if (hidden != null && hidden(b.libraryId)) continue;
      books.add(b);
      byId[id] = b;
      (bySeries[b.seriesId] ??= []).add(b);
      for (final r in b.readLists) {
        final rid = r['id'] as String;
        (_inReadList[rid] ??= []).add(b);
        readListNames.putIfAbsent(rid, () => r['name']);
      }
    }
  }

  /// In the store's order.
  final List<CatalogueBook> books = [];
  final Map<String, CatalogueBook> byId = {};

  /// Each series' books, in the store's order.
  final Map<String, List<CatalogueBook>> bySeries = {};

  final Map<String, List<CatalogueBook>> _inReadList = {};

  /// Each read list's name, as its books carry it; the lists in the order their first book came.
  final Map<String, Object?> readListNames = {};

  /// A read list's books in the list's order (the store's order where two share a place).
  List<CatalogueBook> readList(String readListId) {
    final inIt = [...?_inReadList[readListId]];
    final places = {for (final b in inIt) b.id: b.placeIn(readListId)!};
    mergeSort(inIt, (a, b) => places[a.id]!.compareTo(places[b.id]!));
    return inIt;
  }

  /// A series' books by number (the store's order where two share one).
  List<CatalogueBook> seriesInOrder(String seriesId) {
    final inIt = [...?bySeries[seriesId]];
    mergeSort(inIt, (a, b) => a.numberSort.compareTo(b.numberSort));
    return inIt;
  }

  /// The books in a view's scope (the narrowest given).
  Iterable<CatalogueBook> scoped({String? libraryId, String? collectionId, String? seriesId, String? readListId}) {
    if (seriesId != null) return bySeries[seriesId] ?? const [];
    if (readListId != null) return _inReadList[readListId] ?? const [];
    if (collectionId != null) return books.where((b) => b.collections.any((c) => c['id'] == collectionId));
    if (libraryId != null) return books.where((b) => b.libraryId == libraryId);
    return books;
  }
}

/// A stable sort (List.sort isn't): equal items keep their order.
void mergeSort<T>(List<T> list, int Function(T a, T b) compare) {
  if (list.length < 2) return;
  final indexed = [for (var i = 0; i < list.length; i++) (i, list[i])];
  indexed.sort((a, b) {
    final c = compare(a.$2, b.$2);
    return c != 0 ? c : a.$1.compareTo(b.$1);
  });
  for (var i = 0; i < list.length; i++) {
    list[i] = indexed[i].$2;
  }
}
