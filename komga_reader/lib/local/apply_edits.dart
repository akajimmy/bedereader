// Apply edits to files (user, 2026-10-27; reports\10-27-apply-edits-plan.md): a local or network library's edits,
// kept alongside its books, put into the books themselves - their metadata written in, files and folders renamed -
// when the user asks, after a warning that says what will change.
import 'dart:convert';
import 'dart:typed_data';

import 'file_zip.dart';
import 'in_file_meta.dart';
import 'library_fs.dart';
import 'book_names.dart';
import 'local_library.dart';
import 'local_meta.dart';
import 'local_store.dart';

/// [e] written into [b]'s own file ([fs]: its library's files): a CBZ's ComicInfo.xml (made if it has none), an EPUB's
/// package file - the book rewritten safely ([rewriteZip]: checked before it takes the old one's place). Its own file, never a downloaded copy.
Future<void> writeEditsIntoBook(LibraryFs fs, LocalBook b, BookEdits e) async {
  final zip = await ComicArchive.open(fs, b.path);
  final Map<String, Uint8List> replace, add;
  try {
    if (b.epub) {
      final container = await zip.read(zip.find('META-INF/container.xml') ?? 'META-INF/container.xml');
      final opfPath = container == null
          ? null
          : RegExp(r'full-path\s*=\s*"([^"]+)"').firstMatch(utf8.decode(container, allowMalformed: true))?[1];
      final opf = opfPath == null ? null : await zip.read(opfPath);
      if (opfPath == null || opf == null) throw const FormatException('No package file in the EPUB');
      replace = {opfPath: Uint8List.fromList(utf8.encode(opfWith(utf8.decode(opf, allowMalformed: true), e)))};
      add = const {};
    } else {
      final name = zip.find('ComicInfo.xml');
      final was = name == null ? null : await zip.read(name);
      final xml = Uint8List.fromList(
          utf8.encode(comicInfoWith(was == null ? null : utf8.decode(was, allowMalformed: true), e)));
      replace = name == null ? const {} : {name: xml};
      add = name == null ? {'ComicInfo.xml': xml} : const {};
    }
  } finally {
    await zip.close();
  }
  await rewriteZip(fs, b.path, replace: replace, add: add);
}

// ---- the plan: what Apply will do, worked out before anything changes (the warning shows it) ----------------------

/// A series folder Apply will rename (to its series' title).
class FolderStep {
  const FolderStep(this.from, this.to);
  final String from, to;
}

/// A book Apply will change: its edits written into it ([write]; null: nothing to write - a CBR's can't be), and its
/// file renamed or moved ([from] -> [to]: its path now and after; the same when it stays).
class BookStep {
  const BookStep(this.book, this.from, this.to, {this.write, String? via}) : via = via ?? from;
  final LocalBook book; // as the scan found it
  final String from, to;
  final BookEdits? write;

  /// Where it is once its folder has been renamed (as [from] if it isn't).
  final String via;

  bool get cbr => !book.epub && book.mediaType != 'application/zip';
  bool get renamed => fileNameOf(from) != fileNameOf(to);
  bool get moved => folderOf(via) != folderOf(to);
}

/// What Apply will do to a library: its series folders renamed ([folders]), its books written into, renamed and moved
/// ([books]), and what it can't do and why ([problems]). Only books and series with edits are touched.
class ApplyPlan {
  ApplyPlan(this.library, this.folders, this.books, this.problems, {this.carried = const []});
  final LocalLibrary library;
  final List<FolderStep> folders;
  final List<BookStep> books;
  final List<String> problems;

  /// The books in a renamed folder that have no step of their own: their paths (they go with the folder).
  final List<String> carried;

  bool get isEmpty => folders.isEmpty && books.isEmpty;

  /// The fields that will go into files, by their edit names (title, series, number, releaseDate, summary, authors,
  /// tags) - those edited in at least one book written.
  Set<String> get fieldsWritten => {
        for (final b in written) ...{
          if (b.write!.title != null) 'title',
          if (b.write!.series != null) 'series',
          if (b.write!.number != null) 'number',
          if (b.write!.dateSet) 'releaseDate',
          if (b.write!.summary != null) 'summary',
          if (b.write!.authors != null) 'authors',
          if (b.write!.tags != null) 'tags',
        },
      };
  Iterable<BookStep> get written => books.where((b) => b.write != null);
  Iterable<BookStep> get renamed => books.where((b) => b.renamed);
  Iterable<BookStep> get moved => books.where((b) => b.moved);
  Iterable<BookStep> get cbrs => books.where((b) => b.cbr);
}

/// What Apply did: the books' and series' ids that changed with their paths (old -> new: what's kept under them
/// follows), and what failed and why.
class ApplyResult {
  ApplyResult(this.ids, this.failures, this.done);
  final Map<String, String> ids;
  final List<String> failures;
  final int done;
}

/// [library]'s plan from its scan ([index]) and the edits kept alongside its books ([index.meta]); [fs]: its files
/// (a name already taken there gets " (2)").
Future<ApplyPlan> planApply(LibraryFs fs, LocalLibrary library, LibraryIndex index) async {
  final edited = withEdits(index, library, index.meta);
  final root = library.path.replaceAll(RegExp(r'[\\/]+$'), '');
  final sep = root.contains(r'\') ? r'\' : '/';
  final folders = <String, String>{}; // series folder -> its new path
  final problems = <String>[];
  final taken = <String>{}; // paths given out by this plan

  // a series folder whose title was edited: named after it (a one-series library's folder is the library: not renamed)
  if (library.kind == LibraryKind.seriesFolders) {
    for (final MapEntry(key: id, value: place) in edited.places.entries) {
      final s = edited.series[id];
      if (s == null || place.key != null || place.folder == root) continue;
      final title = index.meta[place.folder]?.folderSeries?.title;
      if (title == null || safeName(title) == fileNameOf(place.folder)) continue;
      final to = '${folderOf(place.folder)}$sep${safeName(title)}';
      final caseOnly = to.toLowerCase() == place.folder.toLowerCase();
      if (!caseOnly && (await fs.isThere(to) || taken.contains(to.toLowerCase()))) {
        problems.add('The folder "${fileNameOf(place.folder)}" isn\'t renamed: "${safeName(title)}" is there already.');
        continue;
      }
      folders[place.folder] = to;
      taken.add(to.toLowerCase());
    }
  }
  String afterFolders(String folder) => folders[folder] ?? folder;

  final books = <BookStep>[];
  for (final b in index.books.values) {
    final now = edited.books[b.id];
    final series = now == null ? null : edited.series[now.seriesId];
    if (now == null || series == null) continue;
    final own = index.meta[folderOf(b.path)]?.books[fileNameOf(b.path)];
    final hasEdits = own != null && !own.isEmpty;
    final moved = now.seriesId != b.seriesId && library.kind == LibraryKind.seriesFolders;
    if (!hasEdits && !moved) continue; // (in a renamed folder only: it goes with the folder)
    // its folder: its series' (a series made by a move gets one in the library), else where it is
    var folder = afterFolders(folderOf(b.path));
    if (moved) {
      final place = edited.places[now.seriesId];
      folder = place != null && place.key == null ? afterFolders(place.folder) : '$root$sep${safeName(series.name)}';
    }
    final ext = b.path.contains('.') ? b.path.substring(b.path.lastIndexOf('.')) : '';
    var to = '$folder$sep${safeName(patternName(now, series))}$ext';
    final from = '${afterFolders(folderOf(b.path))}$sep${fileNameOf(b.path)}';
    if (to.toLowerCase() != from.toLowerCase()) {
      final stem = to.substring(0, to.length - ext.length);
      for (var n = 2; await fs.isThere(to) || taken.contains(to.toLowerCase()); n++) {
        to = '$stem ($n)$ext';
      }
    }
    taken.add(to.toLowerCase());
    // what goes into the file: only what was edited - its own fields, and its series' name if it moved or its series'
    // title was edited (a sort number has no place in a file: it stays alongside only)
    final cbr = !b.epub && b.mediaType != 'application/zip';
    final seriesChanged = !series.oneshot && (moved || series.name != index.series[b.seriesId]?.name);
    final write = BookEdits(
      title: own?.title, number: own?.number, dateSet: own?.dateSet ?? false, releaseDate: own?.releaseDate,
      summary: own?.summary, authors: own?.authors, tags: own?.tags, series: seriesChanged ? series.name : null,
    );
    // (in the file already - what's to go in was all written last time: not again; Apply can be run any time)
    final done = _within(write.toJson(), own?.applied);
    final step = BookStep(b, b.path, to, via: from, write: cbr || write.isEmpty || done ? null : write);
    if (step.write == null && to == from) continue; // (nothing to do: in place, and in the file already)
    books.add(step);
  }
  final stepped = {for (final b in books) b.from};
  // (the books in a renamed folder with no step of their own go with it)
  return ApplyPlan(library, [for (final e in folders.entries) FolderStep(e.key, e.value)], books, problems, carried: [
    for (final b in index.books.values)
      if (folders.containsKey(folderOf(b.path)) && !stepped.contains(b.path)) b.path,
  ]);
}

/// Whether every field of [now] is in [applied] (what was written last time, as JSON), with the same value.
bool _within(Map<String, Object?> now, String? applied) {
  if (applied == null) return false;
  final was = jsonDecode(applied);
  return was is Map && now.entries.every((e) => jsonEncode(was[e.key]) == jsonEncode(e.value));
}

/// A book's file name by the pattern (user, 2026-10-27: "Series 001 (Year)"): a comic "Saga 001 (2012)" - the number
/// padded to three figures, one that isn't a number kept as it is ("Saga Annual (2012)"), the year left out if there's
/// none; an eBook in a series "Dune 01 - Dune", else its title; a one-shot its title (and year). No extension.
String patternName(LocalBook b, LocalSeries s) {
  // (no year when the series' name has it already: "Saga (2012) 001", not "Saga (2012) 001 (2012)")
  final year = b.released == null || s.name.contains('(${b.released!.year})') ? '' : ' (${b.released!.year})';
  if (s.oneshot) return '${b.title}$year';
  if (b.epub) {
    final n = _numberText(b.number, 2);
    return n == null ? b.title : '${s.name} $n - ${b.title}';
  }
  final n = _numberText(b.number, 3);
  return '${s.name}${n == null ? '' : ' $n'}$year';
}

String? _numberText(String number, int width) {
  final t = number.trim();
  if (t.isEmpty) return null;
  final m = RegExp(r'^(\d+)(.*)$').firstMatch(t);
  return m == null ? t : '${m[1]!.padLeft(width, '0')}${m[2]}';
}

/// [name] as a file or folder name on any system: the characters Windows refuses replaced, no dot or space at the end.
String safeName(String name) => name
    .replaceAll(RegExp(r'[<>:"/\\|?*\x00-\x1f]'), '-')
    .replaceAll(RegExp(r'\s+'), ' ')
    .trim()
    .replaceAll(RegExp(r'[. ]+$'), '');

// ---- the run --------------------------------------------------------------------------------------------------------

/// [plan] carried out through [fs]: the series folders renamed, the books written into, then renamed and moved; the
/// edits kept alongside follow them (a book's entry under its new name, in its new folder's .bedereader.json; a new
/// series' edits from the library's file to its own folder's series.json). Each step on its own: one that fails is
/// said, and the rest go on. [onStep]: steps done of all.
Future<ApplyResult> runApply(LibraryFs fs, ApplyPlan plan, {void Function(int done, int all)? onStep}) async {
  final failures = <String>[];
  final ids = <String, String>{};
  final all = plan.folders.length + plan.books.length;
  var done = 0;
  void step() => onStep?.call(++done, all);
  final sep = plan.library.path.contains(r'\') ? r'\' : '/';

  // 1. series folders (a rename only in case: through a name of its own, as some systems see the two as one)
  final folders = <String, String>{};
  for (final f in plan.folders) {
    try {
      if (f.from.toLowerCase() == f.to.toLowerCase()) {
        final via = '${f.from}.bedereader-rename';
        await fs.move(f.from, via);
        await fs.move(via, f.to);
      } else {
        await fs.move(f.from, f.to);
      }
      folders[f.from] = f.to;
      ids[localSeriesId(f.from)] = localSeriesId(f.to);
    } catch (e) {
      failures.add('The folder "${fileNameOf(f.from)}" wasn\'t renamed: $e');
    }
    step();
  }
  String now(String path) => folders.containsKey(folderOf(path))
      ? '${folders[folderOf(path)]}$sep${fileNameOf(path)}'
      : path;
  // the books in a renamed folder: their ids follow it
  for (final p in [...plan.carried, for (final b in plan.books) if (b.to == now(b.from)) b.from]) {
    if (now(p) != p) ids[localBookId(p)] = localBookId(now(p));
  }

  // 2. the books: written into, then renamed and moved
  final entries = <(String, String, String)>[]; // (old folder now, old file name, new path): their entries to follow
  final applied = <String, String>{}; // a book written into (its path after): what was written (its entry records it)
  for (final b in plan.books) {
    final at = now(b.from);
    try {
      if (b.write case final e?) {
        await writeEditsIntoBook(fs, LocalBook.fromJson(b.book.toJson()..['path'] = at, b.book.libraryId), e);
        applied[b.to] = jsonEncode(e.toJson());
        if (at == b.to) entries.add((folderOf(at), fileNameOf(at), at)); // (its entry to record it, where it is)
      }
      if (at != b.to) {
        final into = folderOf(b.to);
        if (!await fs.isThere(into)) await fs.makeFolder(into);
        if (at.toLowerCase() == b.to.toLowerCase()) {
          await fs.move(at, '$at.bedereader-rename');
          await fs.move('$at.bedereader-rename', b.to);
        } else {
          await fs.move(at, b.to);
        }
        ids[localBookId(b.from)] = localBookId(b.to);
        // (a one-shot is a series of its own, named by its file)
        if (b.book.seriesId == localSeriesId(b.from)) ids[b.book.seriesId] = localSeriesId(b.to);
        entries.add((folderOf(at), fileNameOf(b.from), b.to));
      }
    } catch (e) {
      failures.add('"${fileNameOf(b.from)}": $e');
    }
    step();
  }

  // 3. the edits kept alongside follow the files
  try {
    await _follow(fs, plan, entries, ids, sep, applied);
  } catch (e) {
    failures.add("The edits kept beside the books couldn't all follow them: $e");
  }
  return ApplyResult(ids, failures, done);
}

/// The alongside files after the moves: each moved or renamed book's entry taken from its old folder's
/// .bedereader.json and put, under its new name, in its new folder's - a book written into, what was written recorded
/// in its entry ([applied]); a one-shot's series entry renamed with it; a
/// series made by a move, its edits from the library's file to its new folder's series.json (and its id the folder's).
Future<void> _follow(LibraryFs fs, ApplyPlan plan, List<(String, String, String)> entries, Map<String, String> ids,
    String sep, Map<String, String> applied) async {
  final docs = <String, Map<String, Object?>>{}; // folder -> its .bedereader.json, read once, written at the end
  Future<Map<String, Object?>> doc(String folder) async =>
      docs[folder] ??= await readMetaJson(fs, '$folder$sep$editsFileName') ?? <String, Object?>{};
  Map<String, Object?> part(Map<String, Object?> d, String key) =>
      d[key] = Map<String, Object?>.from((d[key] as Map?) ?? const {});

  final root = plan.library.path.replaceAll(RegExp(r'[\\/]+$'), '');
  final madeSeries = <String, String>{}; // a series made by a move, its name (lower case) -> its new folder
  for (final (oldFolder, oldName, to) in entries) {
    final from = part(await doc(oldFolder), 'books');
    final entry = from.remove(oldName);
    final oneshot = part(await doc(oldFolder), 'series').remove('file:$oldName');
    if (oneshot != null) part(await doc(folderOf(to)), 'series')['file:${fileNameOf(to)}'] = oneshot;
    if (entry is Map) {
      if (applied[to] case final stamp?) entry['applied'] = stamp; // (what's in the file now)
      part(await doc(folderOf(to)), 'books')[fileNameOf(to)] = entry;
      final series = entry['series'];
      if (series is String && folderOf(folderOf(to)) == root) madeSeries[series.toLowerCase()] = folderOf(to);
    }
  }
  // a series made by a move: its edits into its folder's series.json, its id now the folder's
  for (final MapEntry(key: name, value: folder) in madeSeries.entries) {
    ids[movedSeriesId(plan.library, name)] = localSeriesId(folder);
    final edits = part(await doc(root), 'series').remove('name:$name');
    if (edits is! Map) continue;
    final path = '$folder$sep$seriesFileName';
    final was = await readMetaJson(fs, path);
    final e = ((was == null ? null : FolderMeta.read(seriesJson: jsonEncode(was)).folderSeries) ?? const SeriesEdits())
        .plus(SeriesEdits.fromJson(edits).toJson());
    await fs.writeWhole(path, Uint8List.fromList(utf8.encode(seriesJsonText(was, e, fileNameOf(folder)))));
  }
  for (final MapEntry(key: folder, value: d) in docs.entries) {
    final empty = ((d['books'] as Map?) ?? const {}).isEmpty && ((d['series'] as Map?) ?? const {}).isEmpty;
    final path = '$folder$sep$editsFileName';
    if (empty && !await fs.isThere(path)) continue;
    d['bedereader'] = 1;
    await fs.writeWhole(path, Uint8List.fromList(utf8.encode(const JsonEncoder.withIndent('  ').convert(d))));
  }
}
