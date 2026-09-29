import 'dart:convert';
import 'dart:io';

/// The downloaded books on this device (1.1 offline mode). One folder per store:
///
///   index.json                      every downloaded book (see [put]) + reading progress made offline
///   `<bookId>`/pages/0001.jpg ...     page images, fetched through Komga's page endpoint (any source format)
///   `<bookId>`/thumb.jpg              the book's poster
///   series/`<id>`.jpg, readlists/`<id>`.jpg, collections/`<id>`.jpg   posters of what the books belong to
///
/// A book entry keeps a snapshot of everything the screens need to show it without Komga: the book, its series and
/// library, the read lists it is in (with its position) and the collections its series is in.
class OfflineStore {
  OfflineStore(this.root);
  final Directory root;

  /// bookId -> entry: {book, series, library {id,name}, readLists [{id,name,index}], collections [{id,name}],
  /// pages [{number, file, mediaType}], bytes, state ('done' | 'partial')}.
  final Map<String, Map<String, dynamic>> books = {};

  /// bookId -> {page, completed, at (ISO time), synced}: reading progress made on this device. Starts as the
  /// server's progress when the book was downloaded; unsynced changes are sent to Komga later (phase 5).
  final Map<String, Map<String, dynamic>> progress = {};

  File get _index => File('${root.path}${Platform.pathSeparator}index.json');

  File file(String relative) => File('${root.path}${Platform.pathSeparator}${relative.replaceAll('/', Platform.pathSeparator)}');

  Future<void> load() async {
    books.clear();
    progress.clear();
    if (!await _index.exists()) return;
    try {
      final j = jsonDecode(await _index.readAsString()) as Map<String, dynamic>;
      (j['books'] as Map? ?? {}).forEach((k, v) => books[k as String] = Map<String, dynamic>.from(v as Map));
      (j['progress'] as Map? ?? {}).forEach((k, v) => progress[k as String] = Map<String, dynamic>.from(v as Map));
    } catch (_) {
      // a damaged index: start empty rather than crash (the page files stay on disk)
    }
  }

  /// Written to a temporary file first, then moved over the index, so a crash mid-write can't leave half an index.
  /// Saves run one after another (overlapping ones would fight over the temporary file).
  /// A failed save is reported to its caller but doesn't block the saves after it.
  Future<void> save() {
    final write = _writes.then((_) async {
      await root.create(recursive: true);
      final tmp = File('${_index.path}.tmp');
      await tmp.writeAsString(jsonEncode({'v': 1, 'books': books, 'progress': progress}));
      await tmp.rename(_index.path);
    });
    _writes = write.catchError((Object _) {});
    return write;
  }

  Future<void> _writes = Future.value();

  /// Adds or replaces a book entry (the download engine calls this; tests build stores with it).
  Future<void> put(String bookId, Map<String, dynamic> entry) async {
    books[bookId] = entry;
    final rp = (entry['book'] as Map?)?['readProgress'] as Map?;
    if (!progress.containsKey(bookId)) setServerProgress(bookId, rp); // this is the server's own progress
    await save();
  }

  /// Komga's progress, as {page, completed, none} ([rp] = Komga's readProgress, null = unread).
  static Map<String, dynamic> norm(Map? rp) =>
      {'page': rp?['page'] ?? 0, 'completed': rp?['completed'] == true, 'none': rp == null};

  /// Progress that is now the same on Komga and here (downloaded, synced, read online): also the new baseline for
  /// spotting later changes on Komga. Not saved - callers save once after a batch.
  void setServerProgress(String bookId, Map? rp) {
    final n = norm(rp);
    progress[bookId] = {
      'page': n['page'], 'completed': n['completed'], 'at': DateTime.now().toIso8601String(), 'synced': true,
      if (rp == null) 'none': true,
      'base': n,
    };
  }

  /// Reading progress made offline (queued for Komga). Keeps the baseline: what Komga had when the two last agreed.
  Future<void> setProgress(String bookId, {int? page, required bool completed, bool clear = false}) async {
    final prev = progress[bookId];
    progress[bookId] = {
      'page': clear ? 0 : (page ?? prev?['page'] ?? 0),
      'completed': completed,
      'at': DateTime.now().toIso8601String(),
      'synced': false,
      if (clear) 'none': true,
      if (prev?['base'] != null) 'base': prev!['base'],
    };
    await save();
  }

  /// Books whose progress made offline hasn't reached Komga yet.
  List<String> get unsynced => [for (final e in progress.entries) if (e.value['synced'] == false) e.key];

  /// The book's readProgress as Komga would give it (null = never opened / marked unread).
  Map<String, dynamic>? readProgressOf(String bookId) {
    final p = progress[bookId];
    if (p == null || p['none'] == true) return null;
    return {'page': p['page'], 'completed': p['completed'] == true, 'readDate': p['at']};
  }
}
