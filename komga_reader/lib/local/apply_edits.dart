// Apply edits to files (user, 2026-10-27; reports\10-27-apply-edits-plan.md): a local or network library's edits,
// kept alongside its books, put into the books themselves - their metadata written in, files and folders renamed -
// when the user asks, after a confirmation that sums up what will change.
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
/// package file - the book rewritten safely ([rewriteZip]: checked before it takes the old one's place). Its own file,
/// never a downloaded copy.
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

// ---- the plan: what Apply will do, worked out before anything changes (the confirmation sums it up) ----------------

/// A series folder Apply will rename (after its series' title), with the books in it ([books]: their paths now - their
/// ids follow the folder).
class FolderStep {
  const FolderStep(this.from, this.to, this.books);
  final String from, to;
  final List<String> books;
}

/// A book Apply will change: its edits written into it ([write]; null: nothing to write - a CBR can't be written to),
/// and its file renamed or moved ([via]: where it is once its folder has been renamed - [from] if it isn't; [to]: where
/// it goes). [makesSeries]: the name of the series it's moved to, which gets its folder made by this move.
class BookStep {
  const BookStep(this.book, this.from, this.via, this.to, {this.write, this.makesSeries});
  final LocalBook book; // as the scan found it
  final String from, via, to;
  final BookEdits? write;
  final String? makesSeries;

  bool get cbr => isCbr(book);
  bool get renamed => fileNameOf(via) != fileNameOf(to);
  bool get moved => folderOf(via) != folderOf(to);
}

/// What Apply will do to a library: its series folders renamed ([folders]), its books written into, renamed and moved
/// ([books]), and what it can't do and why ([problems]). Only the books and series with edits are touched - a series'
/// title edited touches all its books.
class ApplyPlan {
  ApplyPlan(this.library, this.folders, this.books, this.problems);
  final LocalLibrary library;
  final List<FolderStep> folders;
  final List<BookStep> books;
  final List<String> problems;

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
/// follows - an id the same either way isn't in it), and what failed and why.
class ApplyResult {
  ApplyResult(this.ids, this.failures);
  final Map<String, String> ids;
  final List<String> failures;
}

/// [library]'s plan from its scan ([index]) and the edits kept alongside its books ([index.meta]); [fs]: its files.
/// Every name it gives is checked against one picture of where everything will be once it's done - the books it
/// knows, and what's on the disk - so no two things end up in one place (a name taken gets " (2)").
Future<ApplyPlan> planApply(LibraryFs fs, LocalLibrary library, LibraryIndex index) async {
  final edited = withEdits(index, library, index.meta);
  final root = library.path.replaceAll(RegExp(r'[\\/]+$'), '');
  // series made from folders: their folders renamed, books moved between them; a read list's order is in its file
  // names ("002 - "): its books written into, never renamed
  final ownFolders = library.kind == LibraryKind.seriesFolders, renames = library.kind != LibraryKind.readList;
  final problems = <String>[];

  // 1. series folders whose title was edited, named after it (a one-series library's folder is the library itself)
  final folders = <String, String>{}; // folder now -> its new path
  if (ownFolders) {
    for (final MapEntry(key: id, value: place) in edited.places.entries) {
      if (edited.series[id] == null || place.key != null || place.folder == root) continue;
      final title = index.meta[place.folder]?.folderSeries?.title;
      if (title == null || safeName(title) == fileNameOf(place.folder)) continue;
      final to = joinPath(folderOf(place.folder), safeName(title));
      final caseOnly = to.toLowerCase() == place.folder.toLowerCase();
      if (!caseOnly && (await fs.isThere(to) || folders.values.any((t) => t.toLowerCase() == to.toLowerCase()))) {
        problems.add('The folder "${fileNameOf(place.folder)}" stays as it is: "${fileNameOf(to)}" is there already.');
        continue;
      }
      folders[place.folder] = to;
    }
  }
  String after(String path) =>
      folders.containsKey(folderOf(path)) ? joinPath(folders[folderOf(path)]!, fileNameOf(path)) : path;
  final renamedTo = {for (final MapEntry(:key, :value) in folders.entries) value.toLowerCase(): key};

  // where everything will be: every book where it'll be with its folder - each book step takes its own out and its
  // target in; a path not among them is free if nothing's on the disk there (looked for where it is now)
  final occupied = {for (final b in index.books.values) after(b.path).toLowerCase()};
  final made = <String>{}; // folders this plan makes (nothing on the disk in them)
  Future<bool> free(String path) async {
    if (occupied.contains(path.toLowerCase())) return false;
    final folder = folderOf(path).toLowerCase();
    if (made.contains(folder)) return true;
    final now = renamedTo[folder];
    return !await fs.isThere(now == null ? path : joinPath(now, fileNameOf(path)));
  }

  // 2. the folders of series a move makes: in the library, named after the series - one there already isn't used
  final newFolders = <String, String?>{}; // series id -> its folder (null: it can't have one)
  Future<String?> folderFor(String seriesId, String name) async {
    if (newFolders.containsKey(seriesId)) return newFolders[seriesId];
    final folder = joinPath(root, safeName(name));
    final taken = await fs.isThere(folder) || renamedTo.containsKey(folder.toLowerCase());
    if (taken) problems.add('Books moved to "$name" stay where they are: a folder "${fileNameOf(folder)}" is there already.');
    if (!taken) made.add(folder.toLowerCase());
    return newFolders[seriesId] = taken ? null : folder;
  }

  // 3. the books
  final books = <BookStep>[];
  for (final b in index.books.values) {
    final now = edited.books[b.id];
    final series = now == null ? null : edited.series[now.seriesId];
    if (now == null || series == null) continue;
    final own = index.meta[folderOf(b.path)]?.books[fileNameOf(b.path)];
    final moved = ownFolders && now.seriesId != b.seriesId;
    // its series' name goes into it if it moved, or its series' title was edited (all the series' books, then)
    final seriesChanged = !series.oneshot && (moved || series.name != index.series[b.seriesId]?.name);
    if ((own == null || own.isEmpty) && !seriesChanged) continue; // (in a renamed folder only: it goes with it)
    final via = after(b.path);
    var folder = folderOf(via);
    String? makes;
    if (moved) {
      final place = edited.places[now.seriesId];
      final into = place != null && place.key == null ? after(place.folder) : await folderFor(now.seriesId, series.name);
      if (into == null) continue; // (said: its series' folder can't be made)
      if (place == null || place.key != null) makes = series.name;
      folder = into;
    }
    var to = renames ? joinPath(folder, '${safeName(patternName(now, series))}${_extension(b.path)}') : via;
    if (to.toLowerCase() != via.toLowerCase()) {
      occupied.remove(via.toLowerCase());
      final stem = to.substring(0, to.length - _extension(b.path).length);
      for (var n = 2; !await free(to); n++) {
        to = '$stem ($n)${_extension(b.path)}';
      }
      occupied.add(to.toLowerCase());
    }
    // what goes into the file: only what was edited (a sort number has no place in one: it stays alongside only)
    final write = BookEdits(
      title: own?.title, number: own?.number, dateSet: own?.dateSet ?? false, releaseDate: own?.releaseDate,
      summary: own?.summary, authors: own?.authors, tags: own?.tags, series: seriesChanged ? series.name : null,
    );
    final cbr = isCbr(b);
    // (in the file already - what's to go in was all written last time: not again; Apply can be run any time)
    final writes = !cbr && !write.isEmpty && !_within(write.toJson(), own?.applied);
    if (!writes && to == via) continue;
    books.add(BookStep(b, b.path, via, to, write: writes ? write : null, makesSeries: makes));
  }
  return ApplyPlan(library, [
    for (final MapEntry(:key, :value) in folders.entries)
      FolderStep(key, value, [for (final b in index.books.values) if (folderOf(b.path) == key) b.path]),
  ], books, problems);
}

/// A CBR (a RAR): it can't be written to.
bool isCbr(LocalBook b) => !b.epub && b.mediaType != 'application/zip';

String _extension(String path) {
  final name = fileNameOf(path);
  return name.contains('.') ? name.substring(name.lastIndexOf('.')) : '';
}

/// Whether every field of [now] is in [applied] (what was written last time, as JSON), with the same value.
bool _within(Map<String, Object?> now, String? applied) {
  if (applied == null) return false;
  final was = jsonDecode(applied);
  return was is Map && now.entries.every((e) => jsonEncode(was[e.key]) == jsonEncode(e.value));
}

/// A book's file name by the pattern (user, 2026-10-27: "Series 001 (Year)"): a comic "Saga 001 (2012)" - the number
/// padded to three figures, one that isn't a number kept as it is ("Saga Annual (2012)"), the year left out if there's
/// none or the series' name has it; an eBook in a series "Dune 01 - Dune", else its title; a one-shot its title (and
/// year). No extension.
String patternName(LocalBook b, LocalSeries s) {
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

/// [plan] carried out through [fs], one step at a time - each series folder, then each book: written into, moved,
/// and its entry in the alongside files following it at once (a step cut short loses at most that one book's entry).
/// A step that fails is said, and the rest go on; a book whose folder couldn't be renamed stays in it. [onStep]:
/// steps done of all.
Future<ApplyResult> runApply(LibraryFs fs, ApplyPlan plan, {void Function(int done, int all)? onStep}) async {
  final failures = <String>[];
  final ids = <String, String>{};
  void follows(String from, String to) {
    if (from != to) ids[from] = to; // (a rename only in case keeps its id: ids are made from the path in lower case)
  }

  final all = plan.folders.length + plan.books.length;
  var done = 0;
  void step() => onStep?.call(++done, all);

  final stayed = <String, String>{}; // a folder rename that failed: the name it would have had -> its own
  for (final f in plan.folders) {
    try {
      await _move(fs, f.from, f.to);
      follows(localSeriesId(f.from), localSeriesId(f.to));
      for (final p in f.books) {
        follows(localBookId(p), localBookId(joinPath(f.to, fileNameOf(p))));
      }
    } catch (e) {
      failures.add('The folder "${fileNameOf(f.from)}" wasn\'t renamed: $e');
      stayed[f.to] = f.from;
    }
    step();
  }
  String where(String path) =>
      stayed.containsKey(folderOf(path)) ? joinPath(stayed[folderOf(path)]!, fileNameOf(path)) : path;

  for (final b in plan.books) {
    final at = where(b.via), to = where(b.to);
    try {
      final write = b.write;
      if (write != null) {
        await writeEditsIntoBook(fs, LocalBook.fromJson(b.book.toJson()..['path'] = at, b.book.libraryId), write);
      }
      if (to != at) {
        if (b.makesSeries case final name?) await _makeSeriesFolder(fs, plan.library, folderOf(to), name, follows);
        await _move(fs, at, to);
        follows(localBookId(b.from), localBookId(to));
        // (a one-shot is a series of its own, named by its file)
        if (b.book.seriesId == localSeriesId(b.from)) follows(b.book.seriesId, localSeriesId(to));
      }
      await _entryFollows(fs, at, to, applied: write == null ? null : jsonEncode(write.toJson()));
    } catch (e) {
      failures.add('"${fileNameOf(b.from)}": $e');
    }
    step();
  }
  return ApplyResult(ids, failures);
}

/// [from] moved to [to] - a rename only in case through a name of its own (some systems see the two as one).
Future<void> _move(LibraryFs fs, String from, String to) async {
  if (from.toLowerCase() != to.toLowerCase()) return fs.move(from, to);
  await fs.move(from, '$from.bedereader-rename');
  await fs.move('$from.bedereader-rename', to);
}

/// The folder of a series made by a move, made, with a series.json naming it as it was typed ("What If?" in a folder
/// "What If-") and holding its edits - taken from the library's .bedereader.json. Its id becomes the folder's.
Future<void> _makeSeriesFolder(LibraryFs fs, LocalLibrary library, String folder, String name,
    void Function(String from, String to) follows) async {
  if (!await fs.isThere(folder)) await fs.makeFolder(folder);
  follows(movedSeriesId(library, name), localSeriesId(folder));
  final at = joinPath(folder, seriesFileName);
  if (await fs.isThere(at)) return; // (made by an earlier book of it)
  final root = folderOf(folder), rootEdits = joinPath(root, editsFileName);
  final doc = await readMetaJson(fs, rootEdits);
  final series = Map<String, Object?>.from((doc?['series'] as Map?) ?? const {});
  final edits = series.remove('name:${name.trim().toLowerCase()}');
  final e = edits is Map ? SeriesEdits.fromJson(edits) : const SeriesEdits();
  await fs.writeWhole(at, _bytes(seriesJsonText(null, e, name)));
  if (doc != null && edits != null) await fs.writeWhole(rootEdits, _bytes(_json({...doc, 'series': series})));
}

/// A book's entry in the alongside files following it from [from] to [to] (its new name, its new folder's
/// .bedereader.json), with what was written into it now ([applied]) recorded; a one-shot's series entry renamed with
/// it.
Future<void> _entryFollows(LibraryFs fs, String from, String to, {String? applied}) async {
  final oldPath = joinPath(folderOf(from), editsFileName), newPath = joinPath(folderOf(to), editsFileName);
  final oldDoc = await readMetaJson(fs, oldPath);
  if (oldDoc == null) return; // (no entry to follow)
  Map<String, Object?> part(Map<String, Object?> d, String key) =>
      d[key] = Map<String, Object?>.from((d[key] as Map?) ?? const {});
  final entry = part(oldDoc, 'books').remove(fileNameOf(from));
  final oneshot = part(oldDoc, 'series').remove('file:${fileNameOf(from)}');
  if (entry == null && oneshot == null) return;
  final newDoc = oldPath == newPath ? oldDoc : (await readMetaJson(fs, newPath) ?? <String, Object?>{});
  if (entry is Map) {
    part(newDoc, 'books')[fileNameOf(to)] = {...entry, if (applied != null) 'applied': applied};
  }
  if (oneshot != null) part(newDoc, 'series')['file:${fileNameOf(to)}'] = oneshot;
  newDoc['bedereader'] = 1;
  await fs.writeWhole(newPath, _bytes(_json(newDoc)));
  if (oldPath != newPath) await fs.writeWhole(oldPath, _bytes(_json(oldDoc)));
}

String _json(Object o) => const JsonEncoder.withIndent('  ').convert(o);
Uint8List _bytes(String text) => Uint8List.fromList(utf8.encode(text));
