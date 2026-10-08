import 'package:flutter/foundation.dart';

/// The filters of the filter panel (user, 2026-10-08). Writer / author and artist go by Komga's author roles; release
/// years by the release date; publisher, genre and status are the series' own (series views only).
enum FilterField {
  writer,
  artist,
  years,
  publisher,
  genre,
  status;

  /// Only in series views (library Series mode, a collection); left out of book views (library Books mode, a series'
  /// books, a read list).
  bool get seriesOnly => this == publisher || this == genre || this == status;

  /// Whether this filter is offered in a view of series ([seriesView]) or of books.
  bool appliesTo({required bool seriesView}) => seriesView || !seriesOnly;
}

/// Komga's author role for Writer / Author (EPUB authors are stored as writer too).
const writerRoles = ['writer'];

/// The roles the Artist filter covers: any of them.
const artistRoles = ['penciller', 'inker', 'cover'];

/// Komga's series statuses, in the order the panel offers them.
const seriesStatuses = ['ONGOING', 'ENDED', 'HIATUS', 'ABANDONED'];

/// What a view is filtered by, besides read status (the eye, [ReadFilter]): several values in one filter = any of
/// them; different filters all apply. Immutable; lists compare as sets (the order values were picked in doesn't make
/// a different view).
@immutable
class ViewFilter {
  const ViewFilter({this.writers = const [], this.artists = const [], this.fromYear, this.toYear,
      this.publishers = const [], this.genres = const [], this.statuses = const []});

  /// No filter.
  static const none = ViewFilter();

  final List<String> writers; // author names, role writer
  final List<String> artists; // author names, role penciller / inker / cover
  final int? fromYear, toYear; // released in or after / in or before (either may be empty)
  final List<String> publishers, genres; // series filters
  final List<String> statuses; // series filter: ONGOING | ENDED | HIATUS | ABANDONED

  bool get isEmpty =>
      writers.isEmpty && artists.isEmpty && fromYear == null && toYear == null && publishers.isEmpty &&
      genres.isEmpty && statuses.isEmpty;

  bool get isNotEmpty => !isEmpty;

  /// The part of this filter that applies to a view of series ([seriesView]) or of books: book views drop the series
  /// filters (publisher, genre, status).
  ViewFilter forView({required bool seriesView}) => seriesView
      ? this
      : ViewFilter(writers: writers, artists: artists, fromYear: fromYear, toYear: toYear);

  /// A copy with some filters replaced. Years: pass [years] (from, to) to change them - (null, null) clears both.
  ViewFilter copyWith({List<String>? writers, List<String>? artists, (int?, int?)? years, List<String>? publishers,
          List<String>? genres, List<String>? statuses}) =>
      ViewFilter(
        writers: writers ?? this.writers,
        artists: artists ?? this.artists,
        fromYear: years != null ? years.$1 : fromYear,
        toYear: years != null ? years.$2 : toYear,
        publishers: publishers ?? this.publishers,
        genres: genres ?? this.genres,
        statuses: statuses ?? this.statuses,
      );

  /// Saved form (ViewPrefs, pins): only what's set.
  Map<String, dynamic> toJson() => {
        if (writers.isNotEmpty) 'writers': writers,
        if (artists.isNotEmpty) 'artists': artists,
        if (fromYear != null) 'from': fromYear,
        if (toYear != null) 'to': toYear,
        if (publishers.isNotEmpty) 'publishers': publishers,
        if (genres.isNotEmpty) 'genres': genres,
        if (statuses.isNotEmpty) 'statuses': statuses,
      };

  /// Read back from [toJson]; anything unreadable is no filter (no saved form older than this one exists).
  factory ViewFilter.fromJson(Object? j) {
    if (j is! Map) return none;
    List<String> strings(Object? v) => v is List ? [for (final e in v) if (e is String && e.isNotEmpty) e] : const [];
    int? year(Object? v) => v is int ? v : (v is num ? v.toInt() : null);
    return ViewFilter(
      writers: strings(j['writers']),
      artists: strings(j['artists']),
      fromYear: year(j['from']),
      toYear: year(j['to']),
      publishers: strings(j['publishers']),
      genres: strings(j['genres']),
      statuses: strings(j['statuses']),
    );
  }

  /// One short line per filter that's set, for chips and pin names, e.g. ['Writer: Hickman, Ewing', '2015-2026',
  /// 'Marvel']. [writerLabel]: "Writer", "Author" or "Writer / author" as the view's books are.
  List<String> summary({String writerLabel = 'Writer'}) {
    String names(List<String> l) => l.map(_shortName).join(', ');
    return [
      if (writers.isNotEmpty) '$writerLabel: ${names(writers)}',
      if (artists.isNotEmpty) 'Artist: ${names(artists)}',
      if (fromYear != null || toYear != null) yearsText(fromYear, toYear),
      if (publishers.isNotEmpty) publishers.join(', '),
      if (genres.isNotEmpty) genres.join(', '),
      if (statuses.isNotEmpty) statuses.map(statusLabel).join(', '),
    ];
  }

  /// "2015-2026", "2015 on", "to 2026", "2020".
  static String yearsText(int? from, int? to) {
    if (from != null && to != null) return from == to ? '$from' : '$from-$to';
    if (from != null) return '$from on';
    return 'to $to';
  }

  /// ONGOING -> Ongoing.
  static String statusLabel(String s) => s.isEmpty ? s : s[0].toUpperCase() + s.substring(1).toLowerCase();

  /// A person's surname for a chip ("Jonathan Hickman" -> "Hickman"); a one-word name as it is.
  static String _shortName(String n) {
    final parts = n.trim().split(RegExp(r'\s+'));
    return parts.length > 1 ? parts.last : n.trim();
  }

  // ---- Komga's search conditions (POST /api/v1/series/list and /api/v1/books/list) ---------------------------------
  /// The conditions this filter adds to a search, one per filter that's set (all of them apply): several values in
  /// one filter are an anyOf. [seriesView]: a series search (the series filters apply) or a books search (they are
  /// left out - Komga's book search has no publisher, genre or status).
  List<Map<String, dynamic>> conditions({required bool seriesView}) {
    final f = forView(seriesView: seriesView);
    Map<String, dynamic> author(String name, String role) =>
        {'author': {'operator': 'is', 'value': {'name': name, 'role': role}}};
    Map<String, dynamic> isValue(String field, String value) => {field: {'operator': 'is', 'value': value}};
    return [
      if (f.writers.isNotEmpty) anyOf([for (final w in f.writers) for (final r in writerRoles) author(w, r)]),
      if (f.artists.isNotEmpty) anyOf([for (final a in f.artists) for (final r in artistRoles) author(a, r)]),
      // year precision: in or after fromYear = after the last moment of the year before; in or before toYear = before
      // the first moment of the year after
      if (f.fromYear != null)
        {'releaseDate': {'operator': 'after', 'dateTime': '${_y(f.fromYear! - 1)}-12-31T23:59:59Z'}},
      if (f.toYear != null) {'releaseDate': {'operator': 'before', 'dateTime': '${_y(f.toYear! + 1)}-01-01T00:00:00Z'}},
      if (f.publishers.isNotEmpty) anyOf([for (final p in f.publishers) isValue('publisher', p)]),
      if (f.genres.isNotEmpty) anyOf([for (final g in f.genres) isValue('genre', g)]),
      if (f.statuses.isNotEmpty) anyOf([for (final s in f.statuses) isValue('seriesStatus', s)]),
    ];
  }

  static String _y(int y) => '$y'.padLeft(4, '0');

  /// One condition, or an anyOf of several.
  static Map<String, dynamic> anyOf(List<Map<String, dynamic>> conditions) =>
      conditions.length == 1 ? conditions.single : {'anyOf': conditions};

  /// One condition, or an allOf of several; null for none.
  static Map<String, dynamic>? allOf(List<Map<String, dynamic>> conditions) => conditions.isEmpty
      ? null
      : conditions.length == 1
          ? conditions.single
          : {'allOf': conditions};

  // ---- matching a downloaded book / series (the offline source) -----------------------------------------------------
  /// Whether a release date ('YYYY-MM-DD', or null) is within the years; no years set = any (even none).
  bool yearMatches(String? releaseDate) {
    if (fromYear == null && toYear == null) return true;
    final y = releaseDate == null || releaseDate.length < 4 ? null : int.tryParse(releaseDate.substring(0, 4));
    if (y == null) return false;
    return (fromYear == null || y >= fromYear!) && (toYear == null || y <= toYear!);
  }

  /// Whether a list of Komga authors ({name, role}) has one of [names] in one of [roles]; no names = any.
  static bool authorsMatch(Iterable<Object?> authors, List<String> names, List<String> roles) {
    if (names.isEmpty) return true;
    final wanted = {for (final n in names) n.toLowerCase()};
    return authors.any((a) =>
        a is Map && roles.contains('${a['role']}'.toLowerCase()) && wanted.contains('${a['name']}'.toLowerCase()));
  }

  /// Whether [value] is one of [wanted] (case aside); nothing wanted = any.
  static bool oneOf(Object? value, List<String> wanted) =>
      wanted.isEmpty || (value is String && wanted.any((w) => w.toLowerCase() == value.toLowerCase()));

  /// Whether any of [values] is one of [wanted] (case aside); nothing wanted = any.
  static bool anyIn(Iterable<Object?> values, List<String> wanted) => wanted.isEmpty || values.any((v) => oneOf(v, wanted));

  @override
  bool operator ==(Object other) =>
      other is ViewFilter &&
      _same(writers, other.writers) &&
      _same(artists, other.artists) &&
      fromYear == other.fromYear &&
      toYear == other.toYear &&
      _same(publishers, other.publishers) &&
      _same(genres, other.genres) &&
      _same(statuses, other.statuses);

  static bool _same(List<String> a, List<String> b) => setEquals(a.toSet(), b.toSet());

  static int _setHash(List<String> l) => Object.hashAllUnordered(l.toSet());

  @override
  int get hashCode => Object.hash(_setHash(writers), _setHash(artists), fromYear, toYear, _setHash(publishers),
      _setHash(genres), _setHash(statuses));

  @override
  String toString() => 'ViewFilter(${toJson()})';
}
