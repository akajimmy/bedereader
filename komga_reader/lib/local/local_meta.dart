import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'book_names.dart';
import 'library_fs.dart' show FsEntry;
import 'local_library.dart';
import 'local_store.dart';

// Metadata edits of local and network books (user, 2026-10-27; reports\10-27-metadata-plan.md), kept alongside the
// books - nothing in a book file touched:
//   series.json       a series' own folder: its edits, in the Mylar format Komga also reads (name, publisher,
//                     status), with what that format has no place for under "bedereader" (sort title, reading
//                     direction, the status exactly). One written by Mylar counts too.
//   .bedereader.json  any folder: its books' edits, by file name, and the series with no folder of their own - a
//                     one-shot's ("file:<its file name>"), one a book was moved to, a read list's ("name:<its name,
//                     lower case>").
// The scan reads them; the books and series are listed with them applied ([withEdits]) - what the scan found stays as
// the files say.

/// Settings > Libraries > Metadata edits (user, 2026-10-27): kept alongside the books (the default) or written into
/// the book files (a CBZ's ComicInfo.xml, an EPUB's package file - what can't go there goes alongside). This device's
/// own setting.
class EditsInFiles extends ValueNotifier<bool> {
  EditsInFiles._() : super(false);
  static final instance = EditsInFiles._();
  static const _key = 'local.editsInFiles';

  Future<void> load() async => value = (await SharedPreferences.getInstance()).getBool(_key) ?? false;

  Future<void> set(bool on) async {
    value = on;
    await (await SharedPreferences.getInstance()).setBool(_key, on);
  }
}

/// The two file names.
const seriesFileName = 'series.json', editsFileName = '.bedereader.json';

/// One of the metadata files (listed with the books - the scan reads them).
bool isMetaFile(String name) => name.toLowerCase() == seriesFileName || name == editsFileName;

/// A series' edits: what's set replaces what the scan found.
class SeriesEdits {
  const SeriesEdits({this.title, this.titleSort, this.readingDirection, this.status, this.publisher});
  final String? title, titleSort, readingDirection, status, publisher;

  bool get isEmpty =>
      title == null && titleSort == null && readingDirection == null && status == null && publisher == null;

  /// [changes] (Komga's names - the app's edit screen) on top of these; a field changed to '' or null is unset.
  SeriesEdits plus(Map<String, Object?> changes) {
    String? pick(String key, String? was) {
      if (!changes.containsKey(key)) return was;
      final v = changes[key] as String?;
      return v == null || v.isEmpty ? null : v;
    }

    return SeriesEdits(title: pick('title', title), titleSort: pick('titleSort', titleSort),
        readingDirection: pick('readingDirection', readingDirection), status: pick('status', status),
        publisher: pick('publisher', publisher));
  }

  Map<String, Object?> toJson() => {
        if (title != null) 'title': title, if (titleSort != null) 'titleSort': titleSort,
        if (readingDirection != null) 'readingDirection': readingDirection, if (status != null) 'status': status,
        if (publisher != null) 'publisher': publisher,
      };

  factory SeriesEdits.fromJson(Map j) => SeriesEdits(title: _text(j['title']), titleSort: _text(j['titleSort']),
      readingDirection: _text(j['readingDirection']), status: _text(j['status']), publisher: _text(j['publisher']));
}

/// A book's edits: what's set replaces what its file and name say. [releaseDate]: set (a 'yyyy-MM-dd', or null - its
/// date taken away) only when [dateSet].
class BookEdits {
  const BookEdits({this.title, this.number, this.numberSort, this.dateSet = false, this.releaseDate, this.series});
  final String? title, number;
  final num? numberSort;
  final bool dateSet;
  final String? releaseDate;

  /// The series it's moved to, by name (one of the library's, or a new one).
  final String? series;

  bool get isEmpty => title == null && number == null && numberSort == null && !dateSet && series == null;

  /// [changes] (Komga's names, and seriesName) on top of these.
  BookEdits plus(Map<String, Object?> changes) => BookEdits(
        title: changes.containsKey('title') ? _text(changes['title']) : title,
        number: changes.containsKey('number') ? changes['number'] as String? : number,
        numberSort: changes.containsKey('numberSort') ? changes['numberSort'] as num? : numberSort,
        dateSet: dateSet || changes.containsKey('releaseDate'),
        releaseDate: changes.containsKey('releaseDate') ? changes['releaseDate'] as String? : releaseDate,
        series: changes.containsKey('seriesName') ? _text(changes['seriesName']) : series,
      );

  /// The same edits without [title], [number] (its sort number too) or [date] - what's been written into the file
  /// itself, read from there now.
  BookEdits without({bool title = false, bool number = false, bool date = false}) => BookEdits(
        title: title ? null : this.title, number: number ? null : this.number,
        numberSort: number ? null : numberSort, dateSet: date ? false : dateSet,
        releaseDate: date ? null : releaseDate, series: series,
      );

  Map<String, Object?> toJson() => {
        if (title != null) 'title': title, if (number != null) 'number': number,
        if (numberSort != null) 'numberSort': numberSort, if (dateSet) 'releaseDate': releaseDate,
        if (series != null) 'series': series,
      };

  factory BookEdits.fromJson(Map j) => BookEdits(
        title: _text(j['title']), number: j['number'] is String ? j['number'] as String : null,
        numberSort: j['numberSort'] is num ? j['numberSort'] as num : null, dateSet: j.containsKey('releaseDate'),
        releaseDate: _date(j['releaseDate']), series: _text(j['series']),
      );
}

String? _text(Object? v) => v is String && v.trim().isNotEmpty ? v.trim() : null;
String? _date(Object? v) => v is String && DateTime.tryParse(v) != null ? v : null;

/// Mylar's statuses, as Komga reads them.
const _mylarStatus = {'continuing': 'ONGOING', 'ended': 'ENDED'};

/// One folder's metadata files, as read: its series' edits (series.json), its books' and its other series' edits
/// (.bedereader.json), and the files' sizes and dates (unchanged since: not read again).
class FolderMeta {
  const FolderMeta({this.folderSeries, this.books = const {}, this.series = const {}, this.stamps = const {}});
  final SeriesEdits? folderSeries;
  final Map<String, BookEdits> books; // by file name
  final Map<String, SeriesEdits> series; // 'file:<name>' / 'name:<lower case name>'
  final Map<String, String> stamps; // file name -> "size|modified"

  static String stampOf(FsEntry f) => '${f.size}|${f.modified.toUtc().toIso8601String()}';

  /// Read from the folder's files' text ([seriesJson], [editsJson]: null - not there); what can't be read is left out.
  factory FolderMeta.read({String? seriesJson, String? editsJson, Map<String, String> stamps = const {}}) {
    SeriesEdits? folderSeries;
    if (seriesJson != null) {
      try {
        final j = jsonDecode(seriesJson) as Map;
        final m = (j['metadata'] as Map?) ?? const {};
        final own = (j['bedereader'] as Map?) ?? const {};
        folderSeries = SeriesEdits(
          title: _text(m['name']), publisher: _text(m['publisher']),
          status: _text(own['status']) ?? _mylarStatus['${m['status'] ?? ''}'.toLowerCase()],
          titleSort: _text(own['titleSort']), readingDirection: _text(own['readingDirection']),
        );
        if (folderSeries.isEmpty) folderSeries = null;
      } catch (_) {
        // (not JSON, or not Mylar's: no edits)
      }
    }
    var books = <String, BookEdits>{}, series = <String, SeriesEdits>{};
    if (editsJson != null) {
      try {
        final j = jsonDecode(editsJson) as Map;
        books = {
          for (final MapEntry(:key, :value) in ((j['books'] as Map?) ?? const {}).entries)
            if (value is Map) '$key': BookEdits.fromJson(value),
        };
        series = {
          for (final MapEntry(:key, :value) in ((j['series'] as Map?) ?? const {}).entries)
            if (value is Map) '$key': SeriesEdits.fromJson(value),
        };
      } catch (_) {
        // (not JSON: no edits)
      }
    }
    return FolderMeta(folderSeries: folderSeries, books: books, series: series, stamps: stamps);
  }

  bool get isEmpty => folderSeries == null && books.isEmpty && series.isEmpty;

  Map<String, Object?> toJson() => {
        if (folderSeries != null) 'folderSeries': folderSeries!.toJson(),
        if (books.isNotEmpty) 'books': {for (final MapEntry(:key, :value) in books.entries) key: value.toJson()},
        if (series.isNotEmpty) 'series': {for (final MapEntry(:key, :value) in series.entries) key: value.toJson()},
        if (stamps.isNotEmpty) 'stamps': stamps,
      };

  factory FolderMeta.fromJson(Map j) => FolderMeta(
        folderSeries: j['folderSeries'] is Map ? SeriesEdits.fromJson(j['folderSeries'] as Map) : null,
        books: {
          for (final MapEntry(:key, :value) in ((j['books'] as Map?) ?? const {}).entries)
            '$key': BookEdits.fromJson(value as Map),
        },
        series: {
          for (final MapEntry(:key, :value) in ((j['series'] as Map?) ?? const {}).entries)
            '$key': SeriesEdits.fromJson(value as Map),
        },
        stamps: {for (final MapEntry(:key, :value) in ((j['stamps'] as Map?) ?? const {}).entries) '$key': '$value'},
      );
}

String folderOf(String path) => path.substring(0, path.lastIndexOf(RegExp(r'[\\/]')));
String fileNameOf(String path) => path.substring(path.lastIndexOf(RegExp(r'[\\/]')) + 1);

/// Where a series' edits are kept: its folder, and - for one with no folder of its own - its key in that folder's
/// .bedereader.json (null: the folder's series.json).
typedef SeriesPlace = ({String folder, String? key});

/// A series made by moving a book to a name no series of the library has: its id.
String movedSeriesId(LocalLibrary library, String name) =>
    localSeriesId('${library.path}|moved|${name.trim().toLowerCase()}');

/// [index]'s series and books with the edits in [meta] (folder -> its files) applied: a book's own fields, a book moved
/// to another series (an existing one by name - its title as edited - else a new one), each series' fields. Also
/// where each series' edits are kept ([places]), for saving more.
({Map<String, LocalSeries> series, Map<String, LocalBook> books, Map<String, SeriesPlace> places}) withEdits(
    LibraryIndex index, LocalLibrary library, Map<String, FolderMeta> meta) {
  final root = library.path.replaceAll(RegExp(r'[\\/]+$'), '');
  final ownFolder = library.kind != LibraryKind.readList; // series made from folders (not by name: a read list's)

  // where each series' edits are, from its first book
  final places = <String, SeriesPlace>{};
  for (final b in index.books.values) {
    if (places.containsKey(b.seriesId)) continue;
    final s = index.series[b.seriesId];
    if (s == null) continue;
    final folder = folderOf(b.path);
    places[s.id] = s.oneshot
        ? (folder: folder, key: 'file:${fileNameOf(b.path)}')
        : ownFolder
            ? (folder: library.kind == LibraryKind.oneSeries ? root : folder, key: null)
            : (folder: root, key: 'name:${s.name.trim().toLowerCase()}');
  }
  SeriesEdits? editsAt(SeriesPlace p) {
    final m = meta[p.folder];
    return p.key == null ? m?.folderSeries : m?.series[p.key];
  }

  final series = <String, LocalSeries>{
    for (final s in index.series.values) s.id: places[s.id] == null ? s : s.edited(editsAt(places[s.id]!)),
  };
  final byName = <String, String>{for (final s in series.values) s.name.trim().toLowerCase(): s.id};

  final books = <String, LocalBook>{};
  for (final b in index.books.values) {
    final e = meta[folderOf(b.path)]?.books[fileNameOf(b.path)];
    if (e == null || e.isEmpty) {
      books[b.id] = b;
      continue;
    }
    var seriesId = b.seriesId;
    if (e.series case final name? when name.toLowerCase() != series[b.seriesId]?.name.toLowerCase()) {
      seriesId = byName[name.toLowerCase()] ?? movedSeriesId(library, name);
      if (!series.containsKey(seriesId)) {
        final place = (folder: root, key: 'name:${name.toLowerCase()}');
        places[seriesId] = place;
        series[seriesId] = LocalSeries(id: seriesId, libraryId: library.id, name: name).edited(editsAt(place));
        byName[name.toLowerCase()] = seriesId;
      }
    }
    books[b.id] = b.edited(e, seriesId: seriesId);
  }
  return (series: series, books: books, places: places);
}
