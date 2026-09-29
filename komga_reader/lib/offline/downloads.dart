import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../api.dart';
import '../screen.dart';
import 'store.dart';

enum JobState { queued, downloading, paused, failed }

/// One book in the download queue. Visible on the Downloads screen, page by page (the user asked for a real queue
/// view with progress - CDisplayEx never had one).
class DownloadJob {
  DownloadJob({required this.bookId, required this.title, this.state = JobState.queued, this.error});
  final String bookId;
  final String title; // "Series #n"
  JobState state;
  int pagesDone = 0;
  int pagesTotal = 0;
  int bytes = 0;
  String? error;
  bool _cancel = false;

  Map<String, dynamic> toJson() => {'bookId': bookId, 'title': title, 'state': state.name, 'error': error};
  factory DownloadJob.fromJson(Map<String, dynamic> j) => DownloadJob(
        bookId: j['bookId'] as String,
        title: j['title'] as String? ?? '',
        // an interrupted download simply queues again (pages already on disk are skipped)
        state: j['state'] == 'failed' ? JobState.failed : (j['state'] == 'paused' ? JobState.paused : JobState.queued),
        error: j['error'] as String?,
      );
}

/// Downloads books for offline reading (1.1 phase 2): a queue worked one book at a time, page by page, into the
/// [OfflineStore]. The queue survives restarts; a size limit (or none) is checked before each book.
class Downloads extends ChangeNotifier {
  Downloads._();
  static final Downloads instance = Downloads._();

  static const _capKey = 'downloads.capBytes';
  static const gb = 1024 * 1024 * 1024;
  static const defaultCap = 10 * gb;

  Komga? _api;
  OfflineStore? store;
  final List<DownloadJob> queue = [];
  final List<String> recentlyDone = []; // this session, newest first (titles)
  bool paused = false;

  /// Offline mode: nothing downloads (and the server isn't contacted) until it's released.
  bool get hold => _hold;
  set hold(bool v) {
    _hold = v;
    if (!v) _pump();
  }

  bool _hold = false;
  int? capBytes = defaultCap; // null = no limit
  bool _running = false;
  int _session = 0; // bumped by attach(); a worker from an older session stops instead of blocking the new one

  bool get ready => store != null;

  /// The worker is running (including its final saves after a book finishes or pauses).
  bool get busy => _running;
  int get usedBytes => store?.books.values.fold<int>(0, (sum, e) => sum + ((e['bytes'] as num?)?.toInt() ?? 0)) ?? 0;
  bool isDownloaded(String bookId) => store?.books[bookId]?['state'] == 'done';
  DownloadJob? jobFor(String bookId) {
    for (final j in queue) {
      if (j.bookId == bookId) return j;
    }
    return null;
  }

  File get _queueFile => store!.file('queue.json');

  /// Starts (or restarts) the manager for this server. [root] overrides the storage folder (tests).
  Future<void> attach(Komga api, {Directory? root}) async {
    _api = api;
    _session++;
    _running = false; // any older worker notices the new session and stops
    _queueWrites = Future.value(); // a fresh start: nothing to wait behind
    final base = root ?? Directory('${await appStorageDir() ?? Directory.systemTemp.path}${Platform.pathSeparator}downloads');
    store = OfflineStore(base);
    await store!.load();
    final p = await SharedPreferences.getInstance();
    final cap = p.getInt(_capKey);
    capBytes = cap == null ? defaultCap : (cap < 0 ? null : cap);
    queue.clear();
    if (await _queueFile.exists()) {
      try {
        for (final j in jsonDecode(await _queueFile.readAsString()) as List) {
          queue.add(DownloadJob.fromJson(Map<String, dynamic>.from(j as Map)));
        }
      } catch (_) {}
    }
    notifyListeners();
    _pump();
  }

  Future<void> setCap(int? bytes) async {
    capBytes = bytes;
    await (await SharedPreferences.getInstance()).setInt(_capKey, bytes ?? -1);
    // books that stopped for lack of room get another go under the new limit
    for (final j in queue) {
      if (j.state == JobState.failed && (j.error ?? '').startsWith('not enough room')) {
        j
          ..state = JobState.queued
          ..error = null;
      }
    }
    if (ready) await _saveQueue();
    notifyListeners();
    _pump();
  }

  /// Written to a temporary file and then moved over queue.json, so a crash (or a reader) never sees half a file.
  /// Saves run one after another (overlapping ones would fight over the temporary file).
  Future<void> _saveQueue() => _queueWrites = _queueWrites.then((_) async {
        await store!.root.create(recursive: true);
        final tmp = File('${_queueFile.path}.tmp');
        await tmp.writeAsString(jsonEncode([for (final j in queue) j.toJson()]));
        await tmp.rename(_queueFile.path);
      }).catchError((Object _) {});

  Future<void> _queueWrites = Future.value();

  // ---- adding -----------------------------------------------------------------------------------------------------
  /// Queues books that aren't downloaded or queued yet. Returns how many were added.
  Future<int> add(Iterable<dynamic> books) async {
    if (!ready) return 0;
    var added = 0;
    for (final b in books) {
      final id = b['id'] as String;
      if (isDownloaded(id) || jobFor(id) != null) continue;
      queue.add(DownloadJob(bookId: id, title: '${b['seriesTitle'] ?? ''} #${b['metadata']?['number'] ?? ''}'));
      added++;
    }
    if (added > 0) {
      await _saveQueue();
      notifyListeners();
      _pump();
    }
    return added;
  }

  // ---- controls -----------------------------------------------------------------------------------------------------
  void pauseAll() {
    paused = true;
    notifyListeners();
  }

  void resumeAll() {
    paused = false;
    for (final j in queue) {
      if (j.state == JobState.paused) j.state = JobState.queued;
    }
    _saveQueue();
    notifyListeners();
    _pump();
  }

  void retry(String bookId) {
    final j = jobFor(bookId);
    if (j == null) return;
    j
      ..state = JobState.queued
      ..error = null;
    _saveQueue();
    notifyListeners();
    _pump();
  }

  void retryAll() {
    for (final j in queue) {
      if (j.state == JobState.failed) {
        j
          ..state = JobState.queued
          ..error = null;
      }
    }
    _saveQueue();
    notifyListeners();
    _pump();
  }

  /// Empties the queue: everything waiting, paused or failed goes (with any partly downloaded files); the book
  /// downloading stops after its current page and is cleaned up. Finished downloads are untouched.
  Future<void> cancelAll() async {
    for (final j in List<DownloadJob>.of(queue)) {
      if (j.state == JobState.downloading) {
        j._cancel = true; // the worker removes it
      } else {
        queue.remove(j);
        await _deleteFiles(j.bookId);
      }
    }
    await _saveQueue();
    notifyListeners();
  }

  /// Removes a book from the queue; a partly downloaded book's files go too.
  Future<void> cancel(String bookId) async {
    final j = jobFor(bookId);
    if (j == null) return;
    if (j.state == JobState.downloading) {
      j._cancel = true; // the worker stops after the current page and cleans up
      return;
    }
    queue.remove(j);
    await _deleteFiles(bookId);
    await _saveQueue();
    notifyListeners();
  }

  /// Deletes a downloaded book from this device (not from the server). Reading progress made offline that hasn't
  /// reached Komga yet is kept, so it can still be sent.
  Future<void> remove(String bookId) async {
    await _deleteFiles(bookId);
    notifyListeners();
  }

  Future<void> _deleteFiles(String bookId) async {
    final s = store!;
    final dir = Directory(s.file(bookId).path);
    if (await dir.exists()) await dir.delete(recursive: true);
    s.books.remove(bookId);
    if (s.progress[bookId]?['synced'] != false) s.progress.remove(bookId);
    await s.save();
  }

  // ---- the worker ---------------------------------------------------------------------------------------------------
  Future<void> _pump() async {
    if (_running || paused || _hold || _api == null || store == null) return;
    _running = true;
    final session = _session;
    try {
      while (!paused && !_hold && session == _session) {
        DownloadJob? next;
        for (final j in queue) {
          if (j.state == JobState.queued) {
            next = j;
            break;
          }
        }
        if (next == null) break;
        await _run(next);
      }
    } finally {
      if (session == _session) _running = false;
    }
  }

  static String _extension(String? mediaType) => switch (mediaType) {
        'image/png' => 'png',
        'image/webp' => 'webp',
        'image/gif' => 'gif',
        'image/avif' => 'avif',
        'image/jxl' => 'jxl',
        _ => 'jpg',
      };

  String _gb(int bytes) => '${(bytes / gb).toStringAsFixed(1)} GB';

  Future<void> _run(DownloadJob job) async {
    final api = _api!, s = store!;
    job
      ..state = JobState.downloading
      ..error = null
      ..pagesDone = 0;
    notifyListeners();
    try {
      final book = await api.book(job.bookId);
      if (book == null) throw Exception('no longer on the server');
      final pages = await api.pages(job.bookId);
      job.pagesTotal = pages.length;

      // room? (Komga reports page sizes; the book's file size as a fallback)
      final pageSizes = pages.fold<int>(0, (sum, p) => sum + ((p['sizeBytes'] as num?)?.toInt() ?? 0));
      final estimate = pageSizes > 0 ? pageSizes : ((book['sizeBytes'] as num?)?.toInt() ?? 0);
      final alreadyHere = (s.books[job.bookId]?['bytes'] as num?)?.toInt() ?? 0;
      final cap = capBytes;
      if (cap != null && usedBytes - alreadyHere + estimate > cap) {
        throw Exception('not enough room: the download limit is ${_gb(cap)} and ${_gb(usedBytes)} is used '
            '(raise it in App settings)');
      }

      // what it belongs to, for browsing offline
      final seriesId = book['seriesId'] as String;
      final series = await api.oneSeries(seriesId) ?? {'id': seriesId, 'name': book['seriesTitle']};
      final libraries = await api.libraries();
      final library = libraries.firstWhere((l) => l['id'] == book['libraryId'], orElse: () => {'id': book['libraryId'], 'name': 'Library'});
      final readLists = [
        for (final rl in await api.bookReadLists(job.bookId))
          {'id': rl['id'], 'name': rl['name'], 'index': ((rl['bookIds'] as List?) ?? []).indexOf(job.bookId)},
      ];
      final collections = [for (final c in await api.seriesCollections(seriesId)) {'id': c['id'], 'name': c['name']}];

      final plan = [
        for (final p in pages)
          {
            'number': p['number'],
            'mediaType': p['mediaType'],
            'file': 'pages/${(p['number'] as int).toString().padLeft(4, '0')}.${_extension(p['mediaType'] as String?)}',
          },
      ];
      final entry = <String, dynamic>{
        'book': book, 'series': series, 'library': {'id': library['id'], 'name': library['name']},
        'readLists': readLists, 'collections': collections, 'pages': plan, 'bytes': 0, 'state': 'partial',
      };
      await s.put(job.bookId, entry);

      // posters (series / list / collection posters are shared between books: fetched once)
      Future<void> poster(String url, String relative, {bool refresh = false}) async {
        final f = s.file(relative);
        if (!refresh && await f.exists()) return;
        try {
          final bytes = await api.thumbBytes(url);
          if (bytes == null) return;
          await f.parent.create(recursive: true);
          await f.writeAsBytes(bytes);
        } catch (_) {
          // a missing poster isn't worth failing the download for
        }
      }

      await poster(api.bookThumb(job.bookId), '${job.bookId}/thumb.jpg', refresh: true);
      await poster(api.seriesThumb(seriesId), 'series/$seriesId.jpg');
      for (final rl in readLists) {
        await poster(api.readListThumb(rl['id'] as String), 'readlists/${rl['id']}.jpg');
      }
      for (final c in collections) {
        await poster(api.collectionThumb(c['id'] as String), 'collections/${c['id']}.jpg');
      }

      // pages - those already on disk (an interrupted earlier try) are skipped
      var bytes = 0;
      for (final p in plan) {
        if (job._cancel || paused || _hold) break;
        final f = s.file('${job.bookId}/${p['file']}');
        if (await f.exists() && await f.length() > 0) {
          bytes += await f.length();
        } else {
          final data = await api.pageBytes(job.bookId, p['number'] as int);
          await f.parent.create(recursive: true);
          await f.writeAsBytes(data, flush: true);
          bytes += data.length;
        }
        job
          ..pagesDone += 1
          ..bytes = bytes;
        notifyListeners();
      }

      if (job._cancel) {
        queue.remove(job);
        await _deleteFiles(job.bookId);
      } else if (paused || _hold) {
        job.state = _hold ? JobState.queued : JobState.paused; // held: carries on when back online
        entry['bytes'] = bytes;
        await s.put(job.bookId, entry);
      } else {
        entry
          ..['bytes'] = bytes
          ..['state'] = 'done';
        await s.put(job.bookId, entry);
        queue.remove(job);
        recentlyDone.insert(0, job.title);
        if (recentlyDone.length > 20) recentlyDone.removeLast();
      }
    } catch (e) {
      job
        ..state = JobState.failed
        ..error = '$e'.replaceFirst('Exception: ', '');
    }
    await _saveQueue();
    notifyListeners();
  }
}
