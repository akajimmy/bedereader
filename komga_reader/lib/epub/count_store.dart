/// Remembered page counts (user, 2026-10-07): a book opens behind a spinner until every chapter is counted; the counts
/// are kept on the device per book and layout, so only the first open at a given page size and text setting waits.
library;

import 'dart:convert';
import 'dart:io';

import '../screen.dart' show appStorageDir;

/// A book's counts in one layout: each chapter's length (characters) and its pages' starts.
class EpubCounts {
  const EpubCounts(this.lengths, this.starts);
  final List<int> lengths;
  final List<List<int>> starts;

  Map<String, dynamic> toJson() => {'lengths': lengths, 'starts': starts};

  /// Null if [j] isn't a whole, sound set of counts.
  static EpubCounts? fromJson(Object? j) {
    if (j is! Map) return null;
    final l = j['lengths'], s = j['starts'];
    if (l is! List || s is! List || l.length != s.length) return null;
    try {
      return EpubCounts([for (final v in l) v as int], [for (final c in s) [for (final v in c as List) v as int]]);
    } catch (_) {
      return null;
    }
  }
}

/// Where counts are kept. [instance]: the device's files (tests put a [MemoryCountStore] in its place).
abstract class EpubCountStore {
  static EpubCountStore instance = FileCountStore();

  /// The counts of book [bookId] in [layout] (null: none kept).
  Future<EpubCounts?> load(String bookId, String layout);

  Future<void> save(String bookId, String layout, EpubCounts counts);
}

/// Kept in memory (tests).
class MemoryCountStore implements EpubCountStore {
  final Map<String, EpubCounts> kept = {};
  int loads = 0;

  @override
  Future<EpubCounts?> load(String bookId, String layout) async {
    loads++;
    return kept['$bookId|$layout'];
  }

  @override
  Future<void> save(String bookId, String layout, EpubCounts counts) async => kept['$bookId|$layout'] = counts;
}

/// One file per book in the app's storage (epub-counts\<book>.json), its last [perBook] layouts in it; at most
/// [books] files, the ones used longest ago let go of. Where the platform gives no storage folder, nothing is kept.
class FileCountStore implements EpubCountStore {
  /// [root]: the folder (tests); default: epub-counts in the app's storage.
  FileCountStore({Directory? root}) : _dir = root;

  static const perBook = 6, books = 300;

  // the folder once known (the value, not the future: a future is tied to where it began - tests)
  Directory? _dir;
  Future<Directory?> get dir async {
    if (_dir != null) return _dir;
    final base = await appStorageDir();
    return base == null ? null : _dir = Directory('$base${Platform.pathSeparator}epub-counts');
  }

  Future<File?> _file(String bookId) async {
    final d = await dir;
    if (d == null) return null;
    final safe = bookId.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '_');
    return File('${d.path}${Platform.pathSeparator}$safe.json');
  }

  Future<Map<String, dynamic>> _read(File f) async {
    try {
      final j = jsonDecode(await f.readAsString());
      return j is Map<String, dynamic> ? j : {};
    } catch (_) {
      return {}; // none yet, or damaged: counted afresh
    }
  }

  @override
  Future<EpubCounts?> load(String bookId, String layout) async {
    try {
      final f = await _file(bookId);
      if (f == null || !await f.exists()) return null;
      return EpubCounts.fromJson((await _read(f))[layout]);
    } catch (_) {
      return null;
    }
  }

  @override
  Future<void> save(String bookId, String layout, EpubCounts counts) async {
    try {
      final f = await _file(bookId);
      if (f == null) return;
      await f.parent.create(recursive: true);
      final all = await _read(f);
      all.remove(layout); // the newest last
      all[layout] = counts.toJson();
      while (all.length > perBook) {
        all.remove(all.keys.first);
      }
      await f.writeAsString(jsonEncode(all), flush: true);
      await _trim(f.parent);
    } catch (_) {
      // not kept: the book is counted again next time
    }
  }

  /// At most [books] files: the ones written longest ago go.
  Future<void> _trim(Directory d) async {
    final files = d.listSync().whereType<File>().where((f) => f.path.endsWith('.json')).toList();
    if (files.length <= books) return;
    files.sort((a, b) => a.statSync().modified.compareTo(b.statSync().modified));
    for (final f in files.take(files.length - books)) {
      try {
        f.deleteSync();
      } catch (_) {}
    }
  }
}
