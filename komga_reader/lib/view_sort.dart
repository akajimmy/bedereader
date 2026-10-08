import 'package:flutter/foundation.dart';

import 'api.dart';
import 'view_filter.dart';

/// One way a browsing view can be sorted: its [key] (saved per view and in pins), its name in the Sort menu, and the
/// direction it starts in when picked ([desc]: titles A -> Z and issue / list order ascending, dates newest first).
@immutable
class SortField {
  const SortField(this.key, this.label, {this.desc = false, this.ascLabel = 'Oldest first',
      this.descLabel = 'Newest first'});
  final String key;
  final String label;
  final bool desc;
  final String ascLabel, descLabel; // the two directions, in words that suit the field

  const SortField.text(this.key, this.label)
      : desc = false, ascLabel = 'A → Z', descLabel = 'Z → A';
  const SortField.date(this.key, this.label)
      : desc = true, ascLabel = 'Oldest first', descLabel = 'Newest first';
  const SortField.order(this.key, this.label)
      : desc = false, ascLabel = 'First to last', descLabel = 'Last to first';
}

/// A view's sort: a field and a direction.
@immutable
class ViewSort {
  const ViewSort(this.key, this.desc);
  final String key;
  final bool desc;

  String get dir => desc ? 'desc' : 'asc';

  /// As pins keep it: "key:asc" / "key:desc".
  String get pinValue => '$key:$dir';

  /// The view's default: its first field, in that field's natural direction.
  static ViewSort first(List<SortField> fields) => ViewSort(fields.first.key, fields.first.desc);

  /// [key] / [desc] as saved; an unknown key is the default, a missing direction the field's natural one.
  static ViewSort of(List<SortField> fields, Object? key, Object? desc) {
    final f = fields.where((f) => f.key == key).firstOrNull;
    if (f == null) return first(fields);
    return ViewSort(f.key, desc is bool ? desc : f.desc);
  }

  /// A pin's sort, "key:dir" ("key" alone, or none: as [of]). A series pin's "number:desc" is newest first, as it
  /// always was; series pins without a sort open oldest first.
  static ViewSort fromPin(List<SortField> fields, String? pin) {
    final parts = (pin ?? '').split(':');
    return of(fields, parts.first, parts.length > 1 ? parts[1] == 'desc' : null);
  }

  bool isDefault(List<SortField> fields) => this == first(fields);

  /// For a pin's name: null when it's the view's default, else e.g. "release date, newest first" ("newest first"
  /// alone for the default field turned round).
  String? words(List<SortField> fields) {
    if (isDefault(fields)) return null;
    final f = fields.firstWhere((f) => f.key == key, orElse: () => fields.first);
    final dirWords = (desc ? f.descLabel : f.ascLabel).toLowerCase();
    return f.key == fields.first.key ? dirWords : '${f.label.toLowerCase()}, $dirWords';
  }

  @override
  bool operator ==(Object other) => other is ViewSort && other.key == key && other.desc == desc;
  @override
  int get hashCode => Object.hash(key, desc);
}

// ---- each view's sorts (Sort menu, ViewPrefs, pins) ----------------------------------------------------------------

/// The library's series mode (keys as pins.dart's seriesSortFields, which maps them to Komga's fields).
const librarySeriesSorts = [
  SortField.text('title', 'Title'),
  SortField.date('added', 'Date added'),
  SortField.date('updated', 'Date updated'),
];

/// The library's books mode (keys as pins.dart's bookSortFields).
const libraryBookSorts = [
  SortField.text('title', 'Title'),
  SortField.date('added', 'Date added'),
  SortField.date('release', 'Release date'),
];

/// A series' books: issue number (oldest first = the order it always had), release date, date added.
const seriesBookSorts = [
  SortField('number', 'Number'),
  SortField.date('release', 'Release date'),
  SortField.date('added', 'Date added'),
];

/// A collection's series: the collection's own order (Komga's: as arranged, or by title for an unordered one), then
/// title, release date, date added.
const collectionSeriesSorts = [
  SortField.order('order', 'Collection order'),
  SortField.text('title', 'Title'),
  SortField.date('release', 'Release date'),
  SortField.date('added', 'Date added'),
];

/// A read list's books: the list's own order, or by release date.
const readListBookSorts = [
  SortField.order('order', 'List order'),
  SortField.date('release', 'Release date'),
];

/// The library's collections and read lists modes: by name, or most recently updated.
const listSorts = [
  SortField.text('title', 'Name'),
  SortField.date('updated', 'Date updated'),
];

// ---- the requests (one definition for each screen and its pin's poster) --------------------------------------------

/// A page of a series' books in [s], with the eye ([read]) and the filter panel's [filter] (none: the request it
/// always was).
Future<Map<String, dynamic>> seriesBooksPage(Komga api, String seriesId, ViewSort s,
    {ReadFilter read = ReadFilter.all, ViewFilter filter = ViewFilter.none, required int page, required int size}) {
  final field = switch (s.key) { 'release' => 'metadata.releaseDate', 'added' => 'createdDate', _ => 'metadata.numberSort' };
  return api.filteredBooks(seriesId: seriesId, read: read, filter: filter, sort: '$field,${s.dir}', page: page,
      size: size);
}

/// A page of a collection's series in [s], with [read] and [filter].
Future<Map<String, dynamic>> collectionSeriesPage(Komga api, String collectionId, ViewSort s,
    {ReadFilter read = ReadFilter.all, ViewFilter filter = ViewFilter.none, required int page, required int size}) {
  if (s.key == 'order') {
    if (filter.forView(seriesView: true).isNotEmpty) return _filteredInOrder(api, collectionId, s, read, filter, page);
    Future<Map<String, dynamic>> fetch(int p, int n) =>
        api.collectionSeries(collectionId, readStatus: read.api, page: p, size: n);
    return s.desc ? _reversed(fetch, page) : fetch(page, size);
  }
  final field = switch (s.key) {
    'release' => 'booksMetadata.releaseDate', 'added' => 'createdDate', _ => 'metadata.titleSort',
  };
  return api.filteredSeries(collectionId: collectionId, read: read, filter: filter, sort: '$field,${s.dir}',
      page: page, size: size);
}

/// A filtered collection in its own order: Komga's search can't sort by a collection's order, so the series that
/// match (one search) are kept in the order of the whole collection (its own listing) - all of it as the first page.
Future<Map<String, dynamic>> _filteredInOrder(Komga api, String collectionId, ViewSort s, ReadFilter read,
    ViewFilter filter, int page) async {
  if (page > 0) return const {'content': [], 'last': true};
  final matching = <Object?>{};
  for (var p = 0;; p++) {
    final r = await api.filteredSeries(collectionId: collectionId, read: read, filter: filter, page: p, size: 500);
    final content = (r['content'] as List?) ?? const [];
    matching.addAll([for (final x in content) (x as Map)['id']]);
    if (r['last'] != false || content.isEmpty) break;
  }
  final inOrder = await _whole((p, n) => api.collectionSeries(collectionId, page: p, size: n));
  final kept = [for (final x in inOrder) if (matching.contains((x as Map)['id'])) x];
  final list = s.desc ? kept.reversed.toList() : kept;
  return {'content': list, 'totalElements': list.length, 'last': true};
}

/// A page of a read list's books in [s], with [read] and [filter].
Future<Map<String, dynamic>> readListBooksPage(Komga api, String readListId, ViewSort s,
    {ReadFilter read = ReadFilter.all, ViewFilter filter = ViewFilter.none, required int page, required int size}) {
  if (filter.forView(seriesView: false).isNotEmpty) {
    // Komga's book search, in the list's order ("readList.number") or by release date
    final field = s.key == 'release' ? 'metadata.releaseDate' : 'readList.number';
    return api.filteredBooks(readListId: readListId, read: read, filter: filter, sort: '$field,${s.dir}', page: page,
        size: size);
  }
  if (s.key == 'release') {
    return api.readListBooksSorted(readListId, 'metadata.releaseDate,${s.dir}', readStatus: read.api, page: page,
        size: size);
  }
  Future<Map<String, dynamic>> fetch(int p, int n) => api.readListBooks(readListId, readStatus: read.api, page: p, size: n);
  return s.desc ? _reversed(fetch, page) : fetch(page, size);
}

/// How many a view's listing holds with [filter] (the filter panel's live count): one item asked for, its total.
Future<int> countOf(Future<Map<String, dynamic>> Function(int page, int size) fetch) async {
  final r = await fetch(0, 1);
  return (r['totalElements'] as int?) ?? ((r['content'] as List?)?.length ?? 0);
}

/// A list Komga only gives in its own order, last to first: all of it as the first page (Komga can't reverse it, and
/// a page from the end needs the whole list anyway).
Future<Map<String, dynamic>> _reversed(Future<Map<String, dynamic>> Function(int page, int size) fetch, int page) async {
  if (page > 0) return const {'content': [], 'last': true};
  final all = await _whole(fetch);
  return {'content': all.reversed.toList(), 'totalElements': all.length, 'last': true};
}

/// Every page of a listing, in order.
Future<List<dynamic>> _whole(Future<Map<String, dynamic>> Function(int page, int size) fetch) async {
  final all = <dynamic>[];
  for (var p = 0;; p++) {
    final r = await fetch(p, 500);
    final content = (r['content'] as List?) ?? const [];
    all.addAll(content);
    if (r['last'] != false || content.isEmpty) break;
  }
  return all;
}

/// Collections or read lists (Komga's answers, all of them) in [s] - sorted here, so it doesn't depend on which
/// fields Komga sorts lists by. Ties (and lists without the date, offline) keep their name order.
List<dynamic> sortLists(List<dynamic> lists, ViewSort s) {
  String name(dynamic l) => '${l['name'] ?? ''}'.toLowerCase();
  final indexed = [for (var i = 0; i < lists.length; i++) (i, lists[i])];
  indexed.sort((a, b) {
    var c = 0;
    if (s.key == 'updated') {
      c = '${a.$2['lastModifiedDate'] ?? ''}'.compareTo('${b.$2['lastModifiedDate'] ?? ''}');
      if (s.desc) c = -c;
      if (c == 0) c = name(a.$2).compareTo(name(b.$2));
    } else {
      c = name(a.$2).compareTo(name(b.$2));
      if (s.desc) c = -c;
    }
    return c != 0 ? c : a.$1.compareTo(b.$1);
  });
  return [for (final e in indexed) e.$2];
}
