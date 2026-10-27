import 'dart:convert';

import 'book_names.dart';
import 'file_zip.dart';
import 'library_fs.dart';
import 'local_library.dart';
import 'local_store.dart';

/// Which version of the scan's rules read the inside of a file: a book read by older rules is opened again.
const scanVersion = 1;

/// Folders whose files are each a book of its own (Komga's convention, as on the NAS's E-Books\_oneshots).
const oneshotFolders = {'_oneshots'};

/// What a scan couldn't read of a library: the whole library ([reached] false - out of reach, or [missing]: not
/// there while the place it was in answers - it looks deleted), or some of its files and folders, each with why.
class LibraryScan {
  LibraryScan({this.reached = true, this.missing = false, this.error});
  final bool reached, missing;
  final Object? error; // (the library's own, when it wasn't reached)
  final List<(String, FileTrouble)> files = [];

  int count(FileTrouble t) => files.where((f) => f.$2 == t).length;

  /// The files left out (damaged, or gone since the folder was listed): their paths.
  List<String> get leftOut => [for (final f in files) if (f.$2 == FileTrouble.damaged || f.$2 == FileTrouble.gone) f.$1];

  /// Nothing to say about it.
  bool get clean => reached && files.isEmpty;
}

/// A library's scan: its books and series as found, and what couldn't be read.
typedef ScanResult = ({LibraryIndex index, LibraryScan report});

/// Scans [library] through [fs]: every book file in it, one folder per series (a book loose in the library, or in a
/// _oneshots folder, is a book of its own). A file unchanged since [previous] (the same size and date, read by these
/// rules) isn't opened again; others are, [parallel] at a time (on a share, opening is mostly waiting).
///
/// What can't be read keeps what [previous] had of it where that's the share's doing, not the file's: a library out
/// of reach keeps all its books, a folder that couldn't be listed keeps those under it, a file that didn't answer (or
/// was refused) keeps its book; a damaged file, or one gone since the listing, is left out. Told: [onFound] (book
/// files found so far, while listing) and [onBook] (books done so far).
Future<ScanResult> scanLibrary(LibraryFs fs, LocalLibrary library, LibraryIndex? previous,
    {void Function(int found)? onFound, void Function(int done)? onBook, int parallel = 8}) async {
  final kept = previous ?? LibraryIndex(library.id, const [], const []);
  final byPath = {for (final b in kept.books.values) b.path: b};

  // the library's own folder: there, or out of reach, or looking deleted
  try {
    if (!await fs.exists(library.path)) {
      final missing = await fs.placeAnswers(library.path).catchError((Object _) => false);
      return (index: kept, report: LibraryScan(reached: false, missing: missing));
    }
  } catch (e) {
    return (index: kept, report: LibraryScan(reached: false, error: e));
  }

  final report = LibraryScan();
  final unreadFolders = <String>[];
  final files = <FsEntry>[];
  try {
    await for (final e in fs.list(library.path, onUnreadable: (folder, error) {
      unreadFolders.add(folder);
      report.files.add((folder, fs.classify(error)));
    })) {
      files.add(e);
      onFound?.call(files.length);
    }
  } catch (e) {
    return (index: kept, report: LibraryScan(reached: false, error: e)); // (cut off part-way: as out of reach)
  }

  final root = library.path.replaceAll(RegExp(r'[\\/]+$'), '');
  String parentOf(String p) => p.substring(0, p.lastIndexOf(RegExp(r'[\\/]')));
  String baseOf(String p) => p.substring(p.lastIndexOf(RegExp(r'[\\/]')) + 1);
  String stemOf(String p) {
    final b = baseOf(p), i = b.lastIndexOf('.');
    return i <= 0 ? b : b.substring(0, i);
  }

  // each series' files in natural order: a series folder's, or a one-shot's own
  final groups = <(String, bool), List<FsEntry>>{};
  for (final f in files) {
    final parent = parentOf(f.path);
    final oneshot = parent.toLowerCase() == root.toLowerCase() || oneshotFolders.contains(baseOf(parent).toLowerCase());
    groups.putIfAbsent(oneshot ? (f.path, true) : (parent, false), () => []).add(f);
  }
  final series = <LocalSeries>[];
  final jobs = <(FsEntry, int, String, String, bool)>[]; // (file, its place in its series, series id, name, one-shot)
  for (final MapEntry(key: (where, oneshot), value: inIt) in groups.entries) {
    inIt.sort((a, b) => naturalCompare(a.path, b.path));
    final id = localSeriesId(where), name = oneshot ? stemOf(where) : baseOf(where);
    series.add(LocalSeries(id: id, libraryId: library.id, name: name, oneshot: oneshot));
    for (final (i, f) in inIt.indexed) {
      jobs.add((f, i, id, name, oneshot));
    }
  }

  final books = <LocalBook>[];
  var next = 0, done = 0;
  Future<void> worker() async {
    while (next < jobs.length) {
      final (f, place, seriesId, seriesName, oneshot) = jobs[next++];
      final was = byPath[f.path];
      try {
        books.add(was != null && was.sameFile(f.size, f.modified) && was.inside == scanVersion
            ? was
            : await _readBook(fs, f, library, seriesId, seriesName, place, oneshot));
      } catch (e) {
        final trouble = fs.classify(e);
        report.files.add((f.path, trouble));
        // the share's doing, not the file's: the book as it was
        if ((trouble == FileTrouble.noAnswer || trouble == FileTrouble.refused) && was != null) books.add(was);
      }
      onBook?.call(++done);
    }
  }

  await Future.wait([for (var k = 0; k < parallel; k++) worker()]);
  // a folder that couldn't be listed keeps the books it had
  for (final folder in unreadFolders) {
    for (final b in kept.books.values) {
      if (b.path.startsWith(folder) && !books.any((x) => x.id == b.id)) books.add(b);
    }
  }
  final seriesIds = {for (final b in books) b.seriesId};
  return (
    index: LibraryIndex(library.id, [
      ...series.where((s) => seriesIds.contains(s.id)),
      for (final s in kept.series.values)
        if (seriesIds.contains(s.id) && !series.any((x) => x.id == s.id)) s,
    ], books),
    report: report,
  );
}

/// Opens a book's file: its pages (a comic) or its metadata (an EPUB), its ComicInfo, and what its name says.
Future<LocalBook> _readBook(LibraryFs fs, FsEntry f, LocalLibrary library, String seriesId, String seriesName, int place,
    bool oneshot) async {
  final name = f.path.substring(f.path.lastIndexOf(RegExp(r'[\\/]')) + 1);
  final dot = name.lastIndexOf('.');
  final stem = dot <= 0 ? name : name.substring(0, dot);
  final epub = name.toLowerCase().endsWith('.epub');
  final archive = await ComicArchive.open(fs, f.path);
  try {
    final parsed = parseBookName(stem, seriesName);
    // its own title: what follows the number, else the name without its tags ("(2025) (Digital) (Shan-Empire)")
    final untagged = stem.replaceAll(RegExp(r'\([^)]*\)|\[[^\]]*\]'), ' ').replaceAll(RegExp(r'\s+'), ' ').trim();
    var title = oneshot ? stem : (parsed.title ?? (untagged.isEmpty ? stem : untagged));
    if (epub) {
      final meta = await epubMetadata(archive);
      return LocalBook(
        id: localBookId(f.path), libraryId: library.id, seriesId: seriesId, path: f.path, size: f.size,
        modified: f.modified, title: meta.title ?? title, epub: true, mediaType: 'application/epub+zip',
        cover: meta.cover, numberSort: _sortOf(null, parsed.number, place, oneshot),
        released: parsed.year == null ? null : DateTime.utc(parsed.year!),
        precision: parsed.year == null ? null : DatePrecision.year,
        authors: [if (meta.author != null) (meta.author!, 'writer')], inside: scanVersion,
      );
    }
    final pages = comicPages(archive.names);
    if (pages.isEmpty) throw const FormatException('No pages');
    final infoName = archive.find('ComicInfo.xml');
    final infoBytes = infoName == null ? null : await archive.read(infoName);
    final info = infoBytes == null ? null : ComicInfo.parse(utf8.decode(infoBytes, allowMalformed: true));
    title = info?.title ?? title;
    final infoNumber = double.tryParse(info?.number ?? '');
    final shown = oneshot ? '' : info?.number ?? (parsed.number == null ? '' : _numberText(parsed.number!));
    return LocalBook(
      id: localBookId(f.path), libraryId: library.id, seriesId: seriesId, path: f.path, size: f.size,
      modified: f.modified, title: title, mediaType: archive.mediaType, pages: pages.length, cover: pages.first,
      number: shown, numberSort: _sortOf(infoNumber, parsed.number, place, oneshot),
      released: info?.released ?? (parsed.year == null ? null : DateTime.utc(parsed.year!)),
      precision: info?.released != null ? info!.precision : (parsed.year == null ? null : DatePrecision.year),
      authors: info?.authors ?? const [], summary: info?.summary ?? '', inside: scanVersion,
      rightToLeft: info?.rightToLeft ?? false, publisher: info?.publisher, genres: info?.genres ?? const [],
      count: info?.count,
    );
  } finally {
    await archive.close();
  }
}

/// What a book sorts by: its ComicInfo number, else its name's; one with neither goes after the numbered ones, in
/// its place in the folder (it took its place as its number, and could tie with #1 - the experiment's review).
num _sortOf(double? info, double? fromName, int place, bool oneshot) =>
    oneshot ? 1 : info ?? fromName ?? 100000 + place;

String _numberText(double n) => n == n.roundToDouble() ? '${n.toInt()}' : '$n';
