import 'dart:convert';
import 'dart:io';

/// The downloaded books on this device (1.1 offline mode). One folder per store:
///
///   index.json                      every downloaded book (see [put])
///   progress.json                   reading progress (see [progress]) - its own small file, written on each page
///                                   settle; it was in index.json, rewritten whole each time (a few MB with hundreds
///                                   of downloads - code review 2026-10-05, #36)
///   index.v1.json                   index.json as it was before progress moved out (kept once, a backup)
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

  /// bookId -> {page, completed, at (ISO time), synced, place?}: reading progress made on this device. Starts as the
  /// server's progress when the book was downloaded; unsynced changes are sent to Komga later (phase 5).
  /// `place`: an EPUB's exact place (Komga's Readium progression) - kept here with its page, not in the book's
  /// entry, so the page and the place move together through syncing, conflicts, mark unread and removing the
  /// download (a place kept apart went stale and could be sent over a further one - EPUB review 2026-10-06, S1-S4),
  /// and saving one writes only the small progress file (S7).
  final Map<String, Map<String, dynamic>> progress = {};

  File get _index => File('${root.path}${Platform.pathSeparator}index.json');
  File get _progressFile => File('${root.path}${Platform.pathSeparator}progress.json');
  File get _backup => File('${root.path}${Platform.pathSeparator}index.v1.json');

  File file(String relative) => File('${root.path}${Platform.pathSeparator}${relative.replaceAll('/', Platform.pathSeparator)}');

  Future<void> load() async {
    books.clear();
    progress.clear();
    Map? oldProgress; // still in index.json (a store from before progress.json)
    if (await _index.exists()) {
      try {
        final j = jsonDecode(await _index.readAsString()) as Map<String, dynamic>;
        (j['books'] as Map? ?? {}).forEach((k, v) => books[k as String] = Map<String, dynamic>.from(v as Map));
        oldProgress = j['progress'] as Map?;
      } catch (_) {
        // a damaged index: start empty rather than crash (the page files stay on disk)
      }
    }
    if (await _progressFile.exists()) {
      // progress.json is the progress (once written it's the newer: index.json only loses its copy afterwards)
      try {
        final j = jsonDecode(await _progressFile.readAsString()) as Map<String, dynamic>;
        (j['progress'] as Map? ?? {}).forEach((k, v) => progress[k as String] = Map<String, dynamic>.from(v as Map));
      } catch (_) {
        // damaged: the copy still in index.json, if there is one
        oldProgress?.forEach((k, v) => progress[k as String] = Map<String, dynamic>.from(v as Map));
      }
      return;
    }
    if (oldProgress == null) return;
    oldProgress.forEach((k, v) => progress[k as String] = Map<String, dynamic>.from(v as Map));
    await _moveProgressOut();
  }

  /// Once, from a store made before progress.json: index.json backed up as it is (and the copy checked), progress
  /// written to progress.json and read back to check it. index.json itself is left alone here - the next save writes
  /// it without the progress. Anything failing leaves the old index as the record (nothing is lost).
  Future<void> _moveProgressOut() async {
    try {
      if (!await _backup.exists()) {
        await _index.copy(_backup.path);
        if (await _backup.length() != await _index.length()) throw StateError('backup incomplete');
      }
      await _writeProgress();
      final back = jsonDecode(await _progressFile.readAsString()) as Map<String, dynamic>;
      if (jsonEncode(back['progress']) != jsonEncode(progress)) throw StateError('progress.json read back differently');
    } catch (_) {
      // left as it was: progress.json gone again if it was written wrong, index.json still has the progress
      if (await _progressFile.exists()) await _progressFile.delete();
    }
  }

  /// Written to a temporary file first, then moved over the index, so a crash mid-write can't leave half an index.
  /// Saves run one after another (overlapping ones would fight over the temporary file).
  /// A failed save is reported to its caller but doesn't block the saves after it.
  /// Both files: the downloads changed. (Reading progress alone: [saveProgress].) Until progress.json exists (its
  /// first write failed), index.json keeps carrying the progress as before.
  Future<void> save() {
    final write = _writes.then((_) async {
      await root.create(recursive: true);
      final separate = await _writeProgress();
      final tmp = File('${_index.path}.tmp');
      await tmp.writeAsString(jsonEncode({'v': separate ? 2 : 1, 'books': books, if (!separate) 'progress': progress}));
      await tmp.rename(_index.path);
    });
    _writes = write.catchError((Object _) {});
    return write;
  }

  /// Reading progress only: the small file, not the whole index (each page settle of a downloaded book).
  Future<void> saveProgress() {
    final write = _writes.then((_) async {
      await root.create(recursive: true);
      if (!await _writeProgress()) await _writeIndexWithProgress();
    });
    _writes = write.catchError((Object _) {});
    return write;
  }

  /// progress.json written (temporary file, then moved over it). False if it couldn't be.
  Future<bool> _writeProgress() async {
    try {
      final tmp = File('${_progressFile.path}.tmp');
      await tmp.writeAsString(jsonEncode({'v': 1, 'progress': progress}));
      await tmp.rename(_progressFile.path);
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<void> _writeIndexWithProgress() async {
    final tmp = File('${_index.path}.tmp');
    await tmp.writeAsString(jsonEncode({'v': 1, 'books': books, 'progress': progress}));
    await tmp.rename(_index.path);
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
  /// [place]: an EPUB's exact place as Komga has it with that page; left out, the place kept before stays - unless
  /// the book is unread now ([rp] null), which has no place.
  void setServerProgress(String bookId, Map? rp, {Map? place, bool keepPlace = true}) {
    final n = norm(rp);
    final before = progress[bookId];
    final kept = place ?? (keepPlace && before != null ? before['place'] : null);
    progress[bookId] = {
      'page': n['page'], 'completed': n['completed'], 'at': DateTime.now().toIso8601String(), 'synced': true,
      if (rp == null) 'none': true,
      if (rp != null && kept != null) 'place': kept,
      'base': n,
    };
  }

  /// An EPUB's exact place on this device (null: none - not started, marked unread, or never known).
  Map<String, dynamic>? placeOf(String bookId) => (progress[bookId]?['place'] as Map?)?.cast<String, dynamic>();

  /// Reading progress made offline (queued for Komga). Keeps the baseline: what Komga had when the two last agreed.
  /// [place]: an EPUB's exact place read here (sent to Komga as it is); left out, the one before stays - except on
  /// [clear] (marked unread: no place, it opened mid-book - S2).
  Future<void> setProgress(String bookId, {int? page, required bool completed, bool clear = false, Map? place}) async {
    final prev = progress[bookId];
    final kept = clear ? null : (place ?? prev?['place']);
    progress[bookId] = {
      'page': clear ? 0 : (page ?? prev?['page'] ?? 0),
      'completed': completed,
      'at': DateTime.now().toIso8601String(),
      'synced': false,
      if (clear) 'none': true,
      if (kept != null) 'place': kept,
      if (place != null) 'placeHere': true, // read here: goes to Komga with the page
      if (place == null && prev?['placeHere'] == true && !clear) 'placeHere': true,
      if (prev?['base'] != null) 'base': prev!['base'],
    };
    await saveProgress();
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
