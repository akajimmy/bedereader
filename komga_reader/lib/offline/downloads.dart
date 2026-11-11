import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:clock/clock.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../api.dart';
import '../local/book_names.dart' show isLocalId;
import '../local/library_fs.dart' show FileTrouble;
import '../local/local_source.dart';
import '../app_log.dart';
import '../book_title.dart';
import '../errors.dart';
import '../screen.dart';
import 'store.dart';
import '../book_source.dart';

enum JobState { queued, downloading, paused, failed }

/// Delete a downloaded book once it's read: never, ask (one question for all of them, when no book is open), always.
enum DeleteRead { never, ask, always }

/// One book in the download queue. Visible on the Downloads screen, page by page (the user asked for a real queue
/// view with progress - CDisplayEx never had one).
class DownloadJob {
  DownloadJob({required this.bookId, required this.title, this.state = JobState.queued, this.error,
      this.cache = false});
  final String bookId;
  final String title; // "Series #n"
  JobState state;
  int pagesDone = 0;
  int pagesTotal = 0;
  int bytes = 0;
  String? error;
  bool _cancel = false;

  /// A book opened, cached in the background ([Downloads.cacheBook]) - not one downloaded on purpose.
  bool cache;

  Map<String, dynamic> toJson() =>
      {'bookId': bookId, 'title': title, 'state': state.name, 'error': error, if (cache) 'cache': true};
  factory DownloadJob.fromJson(Map<String, dynamic> j) => DownloadJob(
        bookId: j['bookId'] as String,
        title: j['title'] as String? ?? '',
        // an interrupted download simply queues again (pages already on disk are skipped)
        state: j['state'] == 'failed' ? JobState.failed : (j['state'] == 'paused' ? JobState.paused : JobState.queued),
        error: j['error'] as String?,
        cache: j['cache'] == true,
      );
}

/// What one run of the queue has asked Komga about the books' series (a series and its collections by series id, the
/// library list): asked for once per run, not once per book (code review 2026-10-05, #42).
class _Lookups {
  final Map<String, Map<String, dynamic>?> series = {};
  final Map<String, List<dynamic>> collections = {};
  List<dynamic>? libraries;
}

/// Downloads books for offline reading (1.1 phase 2): a queue worked one book at a time, page by page, into the
/// [OfflineStore]. The queue survives restarts; a size limit (or none) is checked before each book.
class Downloads extends ChangeNotifier implements LocalPages {
  Downloads._();
  static final Downloads instance = Downloads._();

  // ---- a downloaded book read from the device, online too (user, 2026-10-12: "use a downloaded version of a comic
  // if present, even if online") - Komga's calls ask here first ([Komga.localPages])

  /// The entry of [bookId], downloaded whole from the server at [baseUrl] (this one's downloads) - else null.
  Map<String, dynamic>? _here(String baseUrl, String bookId) {
    final a = _api, s = store;
    String norm(String u) => u.trim().toLowerCase().replaceAll(RegExp(r'/+$'), '');
    if (a == null || s == null || norm(a.baseUrl) != norm(baseUrl)) return null;
    final e = s.books[bookId];
    return e?['state'] == 'done' ? e : null;
  }

  @override
  List<dynamic>? pagesOf(String baseUrl, String bookId) {
    final e = _here(baseUrl, bookId);
    if (e == null) return null;
    return [for (final p in (e['pages'] as List?) ?? []) listed(p as Map)];
  }

  /// A downloaded page as Komga lists it: its number, type and - downloaded since 2026-10-16 - size.
  static Map<String, dynamic> listed(Map p) => {
        'number': p['number'], 'mediaType': p['mediaType'],
        if (p['width'] != null) 'width': p['width'],
        if (p['height'] != null) 'height': p['height'],
      };

  /// A downloaded EPUB's file (downloaded whole from the server at [baseUrl], and still on the device) - else null.
  File? epubFileOf(String baseUrl, String bookId) {
    final f = _here(baseUrl, bookId)?['epubFile'];
    if (f is! String) return null;
    final file = store!.file('$bookId/$f');
    return file.existsSync() ? file : null;
  }

  @override
  Future<Uint8List>? pageOf(String baseUrl, String bookId, int number) {
    final e = _here(baseUrl, bookId);
    if (e == null) return null;
    for (final p in (e['pages'] as List?) ?? []) {
      if (p['number'] != number) continue;
      final f = store!.file('$bookId/${p['file']}');
      return f.existsSync() ? f.readAsBytes() : null; // (gone from the device: Komga's)
    }
    return null;
  }

  static const _capKey = 'downloads.capBytes';
  static const gb = 1024 * 1024 * 1024;
  static const defaultCap = 10 * gb;

  BookSource? _api;
  OfflineStore? store;
  final List<DownloadJob> queue = [];

  // ---- network books (user, 2026-10-27: "I want download to work for network books" - with Komga's: the same queue,
  // screen, limits, Wi-Fi rule, Delete once read and cache): their copies in a store of their own, beside the server's,
  // there whether or not Komga is (No server mode too). A book in a folder on the device isn't downloaded: it's here.

  /// The network books' downloads (their files copied whole); null until the local libraries are open.
  OfflineStore? localStore;
  LocalSource? _local;

  /// Komga's downloads are open ([store]) - what offline mode needs ([Connection.available]).
  bool get ready => store != null;

  /// The network books' downloads are open.
  bool get localReady => localStore != null && _local != null;

  /// Any downloads at all: the Downloads screen, its badges and menus.
  bool get anyReady => ready || localReady;

  /// The store [bookId] is (or would be) downloaded into.
  OfflineStore? _storeOf(String bookId) => isLocalId(bookId) ? localStore : store;

  /// [bookId] can be downloaded here: Komga's, with its downloads open; a local library's on a network share, with
  /// theirs (one in a folder on the device is here already).
  bool canDownload(String bookId) =>
      isLocalId(bookId) ? localReady && _local!.onShare(bookId) : ready;

  /// Network books whose ids changed with their paths (Apply edits to files: old -> new): their downloaded or cached
  /// copies follow (each in its own folder, named by its id).
  Future<void> renameLocalIds(Map<String, String> ids) async {
    final s = localStore;
    if (s == null) return;
    var any = false;
    for (final MapEntry(key: from, value: to) in ids.entries) {
      final e = s.books.remove(from);
      if (e == null) continue;
      final dir = Directory(s.file(from).path);
      if (await dir.exists()) await dir.rename(s.file(to).path);
      if (e['book'] is Map) e['book'] = {...(e['book'] as Map), 'id': to};
      s.books[to] = e;
      any = true;
    }
    if (!any) return;
    await s.save();
    notifyListeners();
  }

  /// A network book's copy on the device, downloaded or cached (whole); null: none. LocalSource reads it instead of
  /// the share ([LocalSource.downloadedCopy]).
  String? localCopyOf(String bookId) {
    final e = localStore?.books[bookId];
    if (e == null || e['state'] != 'done' || e['file'] is! String) return null;
    return localStore!.file('$bookId/${e['file']}').path;
  }

  /// Pause all: kept across restarts until Resume (code review, 2026-09-30: a restart ran the queue again and left
  /// the paused book stuck).
  bool paused = false;
  static const _pausedKey = 'downloads.paused';

  /// Komga couldn't be reached: the book goes back in the queue (not failed) and the worker waits, looking again every
  /// [serverRecheck], then carries on by itself (code review, 2026-09-30: an outage failed the whole queue).
  bool waitingForServer = false;
  static Duration serverRecheck = const Duration(seconds: 30);
  Timer? _serverTimer;

  /// Offline mode: nothing downloads (and the server isn't contacted) until it's released.
  bool get hold => _hold;
  set hold(bool v) {
    _hold = v;
    if (!v) _pump();
  }

  bool _hold = false;

  // ---- Wi-Fi only (Settings > Downloads, this device; user, 2026-09-30) -----------------------------------------------
  static const _wifiOnlyKey = 'downloads.wifiOnly';
  bool wifiOnly = false;

  /// On mobile data with Wi-Fi only on: the queue waits (a book part way through keeps its pages) and looks again
  /// every [wifiRecheck].
  bool waitingForWifi = false;
  static Future<bool> Function() isOnWifi = onWifi; // swapped in tests
  static Duration wifiRecheck = const Duration(seconds: 30);
  Timer? _wifiTimer;

  Future<void> setWifiOnly(bool v) async {
    wifiOnly = v;
    if (!v) {
      waitingForWifi = false;
      _wifiTimer?.cancel();
    }
    notifyListeners();
    await (await SharedPreferences.getInstance()).setBool(_wifiOnlyKey, v);
    unawaited(_pump());
  }

  /// May the worker fetch now? Off Wi-Fi with Wi-Fi only on: no - it says so and looks again in a while.
  Future<bool> _networkOk() async {
    if (!wifiOnly || await isOnWifi()) {
      if (waitingForWifi) {
        waitingForWifi = false;
        AppLog.instance.info('downloads', 'on Wi-Fi again: the queue goes on');
        notifyListeners();
      }
      return true;
    }
    if (!waitingForWifi) {
      waitingForWifi = true;
      AppLog.instance.info('downloads', 'Wi-Fi only, and not on Wi-Fi: the queue waits');
      notifyListeners();
    }
    _wifiTimer?.cancel();
    _wifiTimer = Timer(wifiRecheck, _pump);
    return false;
  }

  int? capBytes = defaultCap; // null = no limit
  bool _running = false;
  int _session = 0; // bumped by attach(); a worker from an older session stops instead of blocking the new one

  /// The worker is running (including its final saves after a book finishes or pauses).
  bool get busy => _running;
  /// Downloads' room used (the cache's own is [cacheBytes]).
  int get usedBytes => _bytes(cached: false);
  int _bytes({required bool cached}) => [store, localStore]
      .expand((s) => s?.books.values ?? const <Map<String, dynamic>>[])
      .where((e) => (e['cache'] == true) == cached)
      .fold<int>(0, (sum, e) => sum + ((e['bytes'] as num?)?.toInt() ?? 0));

  /// Downloaded on purpose (a cached copy isn't: [isCached]).
  bool isDownloaded(String bookId) {
    final e = _storeOf(bookId)?.books[bookId];
    return e?['state'] == 'done' && e?['cache'] != true;
  }

  // ---- the cache (user, 2026-10-24): a book opened online is downloaded in the background as it's read - read
  // from the device from then on, and offline too. Up to [cacheCap] on disk: the books opened longest ago go first to
  // make room; a book finished goes as soon as it's left. Not a download: not on the Downloads screen, not in its limit.
  static const defaultCacheCap = 512 * 1024 * 1024; // (user, 2026-10-24: "let's call the cache size 512 megabytes")
  /// This device's (Settings > Storage & Downloads > Cache limit - user, 2026-10-27); 0: nothing is cached - a book is
  /// read from its source as it's opened and read.
  static int cacheCap = defaultCacheCap;
  static const _cacheCapKey = 'downloads.cacheCap';

  /// A new cache limit, kept; the cache trimmed to it at once (0: emptied - but the book being read).
  Future<void> setCacheCap(int bytes) async {
    cacheCap = bytes;
    await (await SharedPreferences.getInstance()).setInt(_cacheCapKey, bytes);
    await _cacheRoom(0, '');
    notifyListeners();
  }

  /// Every cached copy gone (Clear cache), but the book open in the reader's - its pages are read from it - and the
  /// books waiting to be cached.
  Future<void> clearCache() async {
    final open = _readers > 0 ? _reading : null;
    final ids = [
      for (final s in [store, localStore])
        for (final e in s?.books.entries ?? const <MapEntry<String, Map<String, dynamic>>>[])
          if (e.value['cache'] == true && e.key != open) e.key,
    ];
    final waiting = queue.where((j) => j.cache && j.state != JobState.downloading).toList();
    queue.removeWhere(waiting.contains);
    if (ids.isNotEmpty) await _deleteFiles(ids);
    if (waiting.isNotEmpty) await _saveQueue();
    notifyListeners();
  }
  int get cacheBytes => _bytes(cached: true);
  bool isCached(String bookId) {
    final e = _storeOf(bookId)?.books[bookId];
    return e?['state'] == 'done' && e?['cache'] == true;
  }

  /// The queue as the Downloads screen shows it (the cache's books aren't downloads).
  List<DownloadJob> get shownQueue => [for (final j in queue) if (!j.cache) j];

  /// [bookId]'s download on its way - not the cache's (code review, 2026-10-24: a book being cached showed "In the
  /// download queue", and its tile a download's progress).
  DownloadJob? downloadJob(String bookId) {
    final j = jobFor(bookId);
    return j == null || j.cache ? null : j;
  }

  /// A book opened in the reader (online): cached in the background - first in the queue - unless it's here already
  /// (then it counts as opened now, the last to go).
  Future<void> cacheBook(Map book) async {
    final id = book['id'] as String;
    // a network book like Komga's (user, 2026-10-27); one in a folder on the device is here already. Offline mode
    // holds Komga's only (the share is another server)
    final s = _storeOf(id);
    if (s == null || !canDownload(id) || (_hold && !isLocalId(id))) return;
    if (cacheCap <= 0) return; // (the cache off: read from its source)
    final e = s.books[id];
    if (e != null && e['cache'] == true) {
      e['cachedAt'] = clock.now().toIso8601String();
      await s.put(id, e);
      return;
    }
    final had = jobFor(id);
    if (had != null && had.cache && had.state == JobState.failed) {
      // (one that failed before this build's fix stayed in the queue: tried again)
      had.state = JobState.queued;
      had.error = null;
      await _saveQueue();
      unawaited(_pump());
      return;
    }
    if (e != null || had != null) return; // downloaded, or on its way
    final size = (book['sizeBytes'] as num?)?.toInt() ?? 0;
    if (size > cacheCap) return; // bigger than the whole cache
    final firstWaiting = queue.indexWhere((j) => j.state != JobState.downloading);
    final job = DownloadJob(bookId: id, title: bookTitle(book), cache: true);
    firstWaiting < 0 ? queue.add(job) : queue.insert(firstWaiting, job);
    await _saveQueue();
    notifyListeners();
    unawaited(_pump());
  }

  /// Room in the cache for [keep], the book being cached, at [bytes] in all: the books opened longest ago go - never
  /// [keep], nor the book open in the reader ([reading]: its pages are read from these files).
  Future<bool> _cacheRoom(int bytes, String keep) async {
    final open = _readers > 0 ? _reading : null;
    final cached = [
      for (final s in [store, localStore])
        for (final e in s?.books.entries ?? const <MapEntry<String, Map<String, dynamic>>>[])
          if (e.value['cache'] == true && e.key != keep && e.key != open) e,
    ]..sort((a, b) => '${a.value['cachedAt'] ?? ''}'.compareTo('${b.value['cachedAt'] ?? ''}'));
    // the others' (code review, 2026-10-24: [keep]'s bytes so far were taken off twice, and its real size left out
    // once it was in - the cache went past its limit)
    var used = cacheBytes - ((_storeOf(keep)?.books[keep]?['bytes'] as num?)?.toInt() ?? 0);
    final gone = <String>[];
    for (final e in cached) {
      if (used + bytes <= cacheCap) break;
      used -= (e.value['bytes'] as num?)?.toInt() ?? 0;
      gone.add(e.key);
    }
    if (gone.isNotEmpty) await _deleteFiles(gone);
    return used + bytes <= cacheCap;
  }

  /// Downloaded books per series / read list (for the tile badges) - worked out once per change, not per tile.
  int downloadedInSeries(String seriesId) => _counts().$1[seriesId] ?? 0;
  int downloadedInReadList(String readListId) => _counts().$2[readListId] ?? 0;
  (Map<String, int>, Map<String, int>)? _countCache;
  (Map<String, int>, Map<String, int>) _counts() => _countCache ??= () {
        final series = <String, int>{}, lists = <String, int>{};
        for (final e in [store, localStore].expand((s) => s?.books.values ?? const <Map<String, dynamic>>[])) {
          if (e['state'] != 'done' || e['cache'] == true) continue;
          final s = (e['book'] as Map?)?['seriesId'] as String?;
          if (s != null) series[s] = (series[s] ?? 0) + 1;
          for (final rl in (e['readLists'] as List?) ?? const []) {
            final id = (rl as Map)['id'] as String;
            lists[id] = (lists[id] ?? 0) + 1;
          }
        }
        return (series, lists);
      }();

  @override
  void notifyListeners() {
    _countCache = null; // every change to the store is followed by a notify
    super.notifyListeners();
  }

  DownloadJob? jobFor(String bookId) {
    for (final j in queue) {
      if (j.bookId == bookId) return j;
    }
    return null;
  }

  /// Each store keeps its own books' place in the queue (Komga's in the server's folder, the network books' in theirs).
  static File _queueFile(OfflineStore s) => s.file('queue.json');

  /// The jobs kept in [s]'s queue.json.
  static Future<List<DownloadJob>> _readQueue(OfflineStore s) async {
    final f = _queueFile(s);
    if (!await f.exists()) return [];
    try {
      return [for (final j in jsonDecode(await f.readAsString()) as List) DownloadJob.fromJson(Map<String, dynamic>.from(j as Map))];
    } catch (_) {
      return [];
    }
  }

  /// Starts (or restarts) the manager for this server. [root] overrides the storage folder (tests). [start] false:
  /// the queue waits for [hold] to be set - the app applies offline mode first, so a forced-offline start contacts
  /// nothing (code review, 2026-09-30).
  /// Signed out: the queue stops and forgets the old key (the downloads stay on the device). The next sign-in attaches
  /// again (missing-tests audit, 2026-09-30).
  void detach() {
    _api = null;
    _session++; // a running worker stops
    _running = false;
    _serverTimer?.cancel();
    waitingForServer = false;
    unawaited(_pump()); // (the network books' carry on: they're not the account's)
  }

  /// A network book's reading progress, as the Downloads screen shows a book's (read, started): the local libraries
  /// keep it, not the downloads.
  Map<String, dynamic>? localProgressOf(String bookId) => _local?.readProgressOf(bookId);

  Future<void> attach(BookSource api, {Directory? root, bool start = true}) async {
    _api = api;
    Komga.localPages = this;
    _session++;
    _running = false; // any older worker notices the new session and stops
    _queueWrites = Future.value(); // a fresh start: nothing to wait behind
    _serverTimer?.cancel();
    waitingForServer = false;
    final base = root ?? Directory('${await appStorageDir() ?? Directory.systemTemp.path}${Platform.pathSeparator}downloads');
    var folder = await serverFolder(base, api.baseUrl);
    // none here yet, and another address's downloads are this library's (Komga moved, its database with it): they're
    // this server's now
    folder = await movedFrom(base, folder, api.baseUrl, (id) async => await api.book(id) != null) ?? folder;
    // the same folder (signed in again to the same server): the same store - a second one for it, while a download
    // from before was still writing through the first, had two writing index.json (code review 2026-10-05, #27)
    if (store?.root.path != folder.path) {
      store = OfflineStore(folder);
      await store!.load();
    }
    await _loadSettings();
    // Komga's jobs from its folder; the network books' stay as they are
    queue
      ..removeWhere((j) => !isLocalId(j.bookId))
      ..addAll([for (final j in await _readQueue(store!)) if (!isLocalId(j.bookId)) j]);
    notifyListeners();
    if (start) unawaited(_pump());
  }

  /// This device's downloads settings (Settings > Downloads): the limit, Wi-Fi only, paused, Delete once read.
  Future<void> _loadSettings() async {
    final p = await SharedPreferences.getInstance();
    final cap = p.getInt(_capKey);
    capBytes = cap == null ? defaultCap : (cap < 0 ? null : cap);
    final cacheLimit = p.getInt(_cacheCapKey);
    if (cacheLimit != null) cacheCap = cacheLimit; // (none chosen: as it is - the default, or a test's)
    wifiOnly = p.getBool(_wifiOnlyKey) ?? false;
    waitingForWifi = false;
    paused = p.getBool(_pausedKey) ?? false;
    keptRead
      ..clear()
      ..addAll(p.getStringList(_keptKey) ?? const []);
    final saved = p.getString(_deleteReadKey);
    deleteRead = DeleteRead.values.firstWhere((d) => d.name == saved, orElse: () => DeleteRead.never);
  }

  /// The network books' downloads, opened with the local libraries (the app: once, at the start - signed in or not).
  /// [root] overrides the storage folder (tests). Their copies are read through [local] from then on.
  Future<void> attachLocal(LocalSource local, {Directory? root}) async {
    _local = local;
    local.downloadedCopy = localCopyOf;
    local.onFinished = bookFinished; // (Delete once read; a cached copy goes)
    final base = root ?? Directory('${await appStorageDir() ?? Directory.systemTemp.path}${Platform.pathSeparator}downloads');
    final s = localStore = OfflineStore(Directory('${base.path}${Platform.pathSeparator}network'));
    await s.load();
    if (store == null) await _loadSettings(); // (No server mode: Komga's never attaches)
    queue
      ..removeWhere((j) => isLocalId(j.bookId))
      ..addAll([for (final j in await _readQueue(s)) if (isLocalId(j.bookId)) j]);
    notifyListeners();
    unawaited(_pump());
  }

  /// Each server's downloads in a folder of their own (code review, 2026-09-30: with one folder for all, signing in
  /// to another server deleted the first one's unsent reading progress as "gone"). The folder there already is
  /// belongs to the first server that uses it (recorded in server.json - nothing is moved); any other server gets
  /// `downloads-(its address)` beside it.
  @visibleForTesting
  static Future<Directory> serverFolder(Directory base, String baseUrl) async {
    String norm(String u) => u.trim().toLowerCase().replaceAll(RegExp(r'/+$'), '');
    final me = norm(baseUrl);
    Future<String?> owner(Directory d) async {
      final f = File('${d.path}${Platform.pathSeparator}server.json');
      if (!await f.exists()) return null;
      try {
        return norm((jsonDecode(await f.readAsString()) as Map)['url'] as String);
      } catch (_) {
        return null;
      }
    }

    Future<Directory> claim(Directory d) async {
      await d.create(recursive: true);
      await File('${d.path}${Platform.pathSeparator}server.json').writeAsString(jsonEncode({'url': me}));
      return d;
    }

    final first = await owner(base);
    if (first == me) return base;
    if (first == null) return claim(base); // today's folder: this server's
    final safe = me.replaceAll(RegExp(r'^[a-z]+://'), '').replaceAll(RegExp(r'[^a-z0-9.]+'), '_');
    final other = Directory('${base.path}-$safe');
    return await owner(other) == me ? other : claim(other);
  }

  /// The same Komga at a new address (user, 2026-10-12: moved to the NAS, its database with it): its downloads, filed
  /// under the old address ([serverFolder]), went missing - a new, empty folder for the new one. When [current] (this
  /// server's folder) has no books and another address's folder has, and this server knows most of those books
  /// ([known]: asked about a few), that folder becomes this server's - its reading progress not yet sent goes with it,
  /// to the same database. The empty folder is removed (only if nothing but its label and empty lists is in it).
  /// Null: nothing to take over (books here already; none elsewhere; another library's; Komga not answering - asked
  /// again next time).
  static Future<Directory?> movedFrom(Directory base, Directory current, String baseUrl,
      Future<bool> Function(String bookId) known) async {
    try {
      final here = OfflineStore(current);
      await here.load();
      if (here.books.isNotEmpty) return null;
      final queued = here.file('queue.json');
      if (await queued.exists() && (jsonDecode(await queued.readAsString()) as List).isNotEmpty) {
        return null; // downloads already asked for at this address: it's in use - left as it is
      }
      final parent = base.parent;
      if (!await parent.exists()) return null;
      final name = base.uri.pathSegments.where((s) => s.isNotEmpty).last;
      final others = <(Directory, OfflineStore)>[];
      await for (final e in parent.list()) {
        if (e is! Directory || e.path == current.path) continue;
        final n = e.uri.pathSegments.where((s) => s.isNotEmpty).last;
        if (n != name && !n.startsWith('$name-')) continue;
        if (!await File('${e.path}${Platform.pathSeparator}server.json').exists()) continue;
        final s = OfflineStore(e);
        await s.load();
        if (s.books.isNotEmpty) others.add((e, s));
      }
      others.sort((a, b) => b.$2.books.length - a.$2.books.length); // the most books first
      for (final (dir, s) in others) {
        final sample = s.books.keys.take(3).toList();
        var found = 0;
        for (final id in sample) {
          if (await known(id)) found++;
        }
        if (found * 2 <= sample.length) continue; // most not on this server: another library
        String norm(String u) => u.trim().toLowerCase().replaceAll(RegExp(r'/+$'), '');
        await File('${dir.path}${Platform.pathSeparator}server.json').writeAsString(jsonEncode({'url': norm(baseUrl)}));
        // the empty folder made for this address: gone, if empty (its label, and lists with nothing in them)
        final left = await current.list().map((f) => f.uri.pathSegments.where((p) => p.isNotEmpty).last).toList();
        if (left.every(const {'server.json', 'index.json', 'progress.json', 'queue.json'}.contains)) {
          await current.delete(recursive: true);
        }
        return dir;
      }
    } catch (_) {
      // offline, or Komga not answering: asked again next time
    }
    return null;
  }

  // ---- Delete once read (Settings > Downloads, this device): Never / Ask / Always (tablet bug, 2026-09-30) -----------
  static const _deleteReadKey = 'downloads.deleteRead';
  DeleteRead deleteRead = DeleteRead.never;
  final Set<String> _finished = {}; // Always: read while a book was open - deleted once the reader closes
  final Set<String> askPending = {}; // Ask: finished, waiting to be asked about once no book is open
  int _readers = 0;
  String? _reading; // the book the reader shows ([reading]): its cached copy isn't made room with

  /// The reader shows [bookId] now (online or not): a cached copy of it stays while it's open ([_cacheRoom]).
  void reading(String bookId) => _reading = bookId;

  /// Ask, answered Keep: not asked about again (the read reaching Komga later asked a second time - code review,
  /// 2026-09-30). Remembered until the download goes.
  final Set<String> keptRead = {};
  static const _keptKey = 'downloads.keptRead';

  Future<void> keep(Iterable<String> ids) async {
    keptRead.addAll(ids);
    await (await SharedPreferences.getInstance()).setStringList(_keptKey, keptRead.toList());
  }

  /// No book is open: the moment to ask about [askPending] (the app shows the question - main.dart).
  bool get noBookOpen => _readers == 0;

  Future<void> setDeleteRead(DeleteRead d) async {
    deleteRead = d;
    if (d != DeleteRead.ask) askPending.clear();
    notifyListeners();
    await (await SharedPreferences.getInstance()).setString(_deleteReadKey, d.name);
  }

  /// A book was marked read - here, offline, or on another device (seen by the progress sync). Always: its download
  /// goes (a book still open in the reader, once the reader closes). Ask: it's added to the books to ask about. Books
  /// that were already read when downloaded aren't touched: this only follows a book becoming read.
  void bookFinished(String bookId) {
    // the cache's: finished, it goes - whatever Delete once read says (user, 2026-10-24: "a book that is finished
    // reading should immediately delete the cache"); one still being cached stops
    final job = jobFor(bookId);
    if (job != null && job.cache) {
      unawaited(cancel(bookId));
      return;
    }
    if (isCached(bookId)) {
      _finished.add(bookId); // (its pages may be on screen: once no book is open)
      if (_readers == 0) unawaited(_deleteFinished());
      return;
    }
    if (deleteRead == DeleteRead.never || !isDownloaded(bookId)) return;
    if (deleteRead == DeleteRead.ask) {
      if (keptRead.contains(bookId)) return; // asked already: Keep
      if (askPending.add(bookId)) notifyListeners();
      return;
    }
    _finished.add(bookId);
    if (_readers == 0) unawaited(_deleteFinished());
  }

  void readerOpened() => _readers++;
  void readerClosed() {
    if (_readers > 0) _readers--;
    if (_readers == 0) _reading = null;
    if (_readers == 0 && _finished.isNotEmpty) unawaited(_deleteFinished());
    if (_readers == 0 && askPending.isNotEmpty) notifyListeners(); // time to ask
  }

  /// The books waiting to be asked about, handed over once (the answer is the caller's).
  List<String> takeAskPending() {
    final ids = [for (final id in askPending) if (isDownloaded(id)) id];
    askPending.clear();
    return ids;
  }

  /// Removes several downloads together ("Delete" in answer to Ask; Manage: a selection, a series, everything read)
  /// - the downloads record written once, not once per book.
  Future<void> removeAll(Iterable<String> ids) async {
    final gone = [for (final id in ids) if (isDownloaded(id) || isCached(id)) id];
    if (gone.isEmpty) return;
    await _deleteFiles(gone);
    await _roomAgain(); // room freed: books that stopped for lack of it carry on (and the listeners hear of it)
  }

  /// Tests: books read while a reader was open, waiting for it to close before they're deleted (Always).
  @visibleForTesting
  Set<String> get waitingForReaderToClose => Set.unmodifiable(_finished);

  /// Tests: forget what one test leaves behind in this singleton - open readers, books waiting to be deleted or asked
  /// about, the timers (test audit, 2026-09-30). [attach] reloads the rest.
  @visibleForTesting
  void reset() {
    _serverTimer?.cancel();
    _serverTimer = null;
    _wifiTimer?.cancel();
    _wifiTimer = null;
    _shareTimer?.cancel();
    _shareTimer = null;
    waitingForShare = false;
    _readers = 0;
    _reading = null;
    _finished.clear();
    askPending.clear();
    keptRead.clear();
    paused = false;
    waitingForServer = false;
    waitingForWifi = false;
  }

  Future<void> _deleteFinished() async {
    final ids = List.of(_finished);
    _finished.clear();
    await removeAll(ids); // progress not yet sent to Komga is kept (see remove)
  }

  Future<void> setCap(int? bytes) async {
    capBytes = bytes;
    await (await SharedPreferences.getInstance()).setInt(_capKey, bytes ?? -1);
    await _roomAgain();
  }

  /// There may be room now (the limit went up, or a download was deleted): books that stopped for lack of room go
  /// back in the queue, and the worker tries them - "carries on when space is available" (user, 2026-09-30).
  Future<void> _roomAgain() async {
    var any = false;
    for (final j in queue) {
      if (j.state == JobState.failed && (j.error ?? '').startsWith('not enough room')) {
        j
          ..state = JobState.queued
          ..error = null;
        any = true;
      }
    }
    if (any && ready) await _saveQueue();
    notifyListeners();
    if (any) unawaited(_pump());
  }

  /// Written to a temporary file and then moved over queue.json, so a crash (or a reader) never sees half a file.
  /// Saves run one after another (overlapping ones would fight over the temporary file).
  Future<void> _saveQueue() => _queueWrites = _queueWrites.then((_) async {
        for (final (s, local) in [(store, false), (localStore, true)]) {
          if (s == null) continue;
          await s.root.create(recursive: true);
          final f = _queueFile(s), tmp = File('${_queueFile(s).path}.tmp');
          await tmp.writeAsString(jsonEncode([for (final j in queue) if (isLocalId(j.bookId) == local) j.toJson()]));
          await tmp.rename(f.path);
        }
      }).catchError((Object _) {});

  Future<void> _queueWrites = Future.value();

  // ---- adding -----------------------------------------------------------------------------------------------------
  /// Queues books that aren't downloaded or queued yet. Returns how many were added.
  Future<int> add(Iterable<dynamic> books) async {
    if (!anyReady) return 0;
    var added = 0;
    for (final b in books) {
      final id = b['id'] as String;
      // Komga's, or a network book's (one in a folder on the device: here already)
      if (!canDownload(id)) continue;
      final s = _storeOf(id)!;
      // a book in the cache, downloaded on purpose: a download from now on (kept until deleted)
      final cachedJob = jobFor(id);
      if (cachedJob != null && cachedJob.cache) {
        cachedJob.cache = false;
        added++;
        continue;
      }
      final e = s.books[id];
      if (e != null && e['cache'] == true) {
        e.remove('cache');
        e.remove('cachedAt');
        await s.put(id, e);
        added++;
        continue;
      }
      if (isDownloaded(id) || jobFor(id) != null) continue;
      queue.add(DownloadJob(bookId: id, title: bookTitle(b)));
      added++;
    }
    if (added > 0) {
      await _saveQueue();
      notifyListeners();
      unawaited(_pump());
    }
    return added;
  }

  // ---- controls -----------------------------------------------------------------------------------------------------
  void pauseAll() {
    paused = true;
    notifyListeners();
    SharedPreferences.getInstance().then((p) => p.setBool(_pausedKey, true));
  }

  void resumeAll() {
    paused = false;
    SharedPreferences.getInstance().then((p) => p.setBool(_pausedKey, false));
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
      if (j.cache) continue; // (the cache's: not on the Downloads screen, not its to cancel)
      if (j.state == JobState.downloading) {
        j._cancel = true; // the worker removes it
      } else {
        queue.remove(j);
        await _deleteFiles([j.bookId]);
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
    await _deleteFiles([bookId]);
    await _saveQueue();
    notifyListeners();
  }

  /// Deletes a downloaded book from this device (not from the server). Reading progress made offline that hasn't
  /// reached Komga yet is kept, so it can still be sent.
  Future<void> remove(String bookId) async {
    await _deleteFiles([bookId]);
    await _roomAgain(); // room freed: books that stopped for lack of it carry on (and the listeners hear of it)
  }

  Future<void> _deleteFiles(Iterable<String> bookIds) async {
    var kept = false;
    final touched = <OfflineStore>{};
    for (final bookId in bookIds.toList()) {
      final s = _storeOf(bookId);
      if (s == null) continue;
      touched.add(s);
      kept |= keptRead.remove(bookId);
      final dir = Directory(s.file(bookId).path);
      if (await dir.exists()) await dir.delete(recursive: true);
      s.books.remove(bookId);
      if (s.progress[bookId]?['synced'] != false) s.progress.remove(bookId);
    }
    if (kept) await (await SharedPreferences.getInstance()).setStringList(_keptKey, keptRead.toList());
    for (final s in touched) {
      await s.save();
    }
  }

  // ---- the worker ---------------------------------------------------------------------------------------------------
  /// A job the worker can take now: Komga's while it's attached, not held (offline mode) and not waited for; a network
  /// book's while its downloads are open and the share isn't being waited for.
  bool _runnable(DownloadJob j) => j.state == JobState.queued &&
      (isLocalId(j.bookId)
          ? localReady && !waitingForShare && !_hold // (offline: nothing from a share either - user, 10-27)
          : !_hold && _api != null && store != null && !waitingForServer);

  Future<void> _pump() async {
    if (_running || paused) return;
    _running = true;
    final session = _session;
    final lookups = _Lookups(); // this run's: a worker from an older session can't fill the new one's
    try {
      while (!paused && session == _session) {
        if (waitingForServer && !_hold && _api != null) await _serverOk(); // (Komga back? its books carry on)
        final next = queue.where(_runnable).firstOrNull;
        if (next == null) break;
        if (!await _networkOk()) break; // Wi-Fi only, on mobile data: wait for Wi-Fi
        await (isLocalId(next.bookId) ? _runLocal(next) : _run(next, lookups));
      }
    } finally {
      if (session == _session) _running = false;
    }
  }

  /// A network share didn't answer: its books wait (back in the queue, their copy so far kept) and the worker looks
  /// again in [serverRecheck] - Komga's carry on meanwhile.
  bool waitingForShare = false;
  Timer? _shareTimer;

  void _waitForShare() {
    waitingForShare = true;
    _shareTimer?.cancel();
    _shareTimer = Timer(serverRecheck, () {
      waitingForShare = false;
      unawaited(_pump());
    });
  }

  /// How much of a network book is copied at a time (between two, a cancel, a pause or Wi-Fi gone is seen).
  static const _chunk = 1 << 20;

  /// A network book: its file copied whole from the share (whatever it is - CBZ, CBR, EPUB), read from the copy from
  /// then on ([localCopyOf]); its entry a snapshot of the book as the local libraries list it. A copy cut off part way
  /// (paused, Wi-Fi gone, the share gone) goes on from where it stopped.
  Future<void> _runLocal(DownloadJob job) async {
    final local = _local!, s = localStore!;
    job
      ..state = JobState.downloading
      ..error = null
      ..pagesDone = 0;
    notifyListeners();
    final took = Stopwatch()..start();
    AppLog.instance.info('downloads', '${job.cache ? 'caching' : 'downloading'} "${job.title}" (network)');
    try {
      final e = local.entries[job.bookId];
      if (e == null) throw const _Gone();
      final book = Map<String, dynamic>.from(e['book'] as Map);
      final size = (book['sizeBytes'] as num?)?.toInt() ?? 0;
      final name = '${book['url'] ?? ''}';
      final dot = name.lastIndexOf('.');
      final ext = dot < 0 || name.length - dot > 6 ? 'book' : name.substring(dot + 1).toLowerCase();
      final alreadyHere = (s.books[job.bookId]?['bytes'] as num?)?.toInt() ?? 0;
      final cap = capBytes;
      if (job.cache) {
        if (!await _cacheRoom(size, job.bookId)) {
          queue.remove(job);
          await _deleteFiles([job.bookId]);
          await _saveQueue();
          notifyListeners();
          return;
        }
      } else if (cap != null && usedBytes - alreadyHere + size > cap) {
        throw Exception('not enough room: the download limit is ${_gb(cap)} and ${_gb(usedBytes)} is used '
            '(raise it in Settings)');
      }
      final entry = <String, dynamic>{
        'book': book, 'series': e['series'], 'library': e['library'], 'readLists': e['readLists'] ?? const [],
        'collections': const [], 'file': 'book.$ext', 'bytes': 0, 'state': 'partial',
        if (job.cache) 'cache': true,
        if (job.cache) 'cachedAt': clock.now().toIso8601String(),
      };
      await s.put(job.bookId, entry);

      final f = s.file('${job.bookId}/book.$ext'), part = File('${f.path}.part');
      var stopped = false, offWifi = false;
      if (!(await f.exists() && await f.length() == size)) {
        await f.parent.create(recursive: true);
        final from = await local.openBookFile(job.bookId);
        final out = await part.open(mode: FileMode.append); // (what an earlier try copied stays)
        try {
          var at = await out.length();
          final total = await from.length();
          job.pagesTotal = (total / _chunk).ceil().clamp(1, 1 << 30);
          for (var i = 0; at < total; i++) {
            if (job._cancel || paused || _hold) { // (offline: back in the queue, the copy so far kept)
              stopped = true;
              break;
            }
            if (i > 0 && i % 8 == 0 && !await _networkOk()) {
              offWifi = true;
              break;
            }
            final bytes = await from.readRange(at, _chunk < total - at ? _chunk : total - at);
            if (bytes.isEmpty) throw const FormatException('the file ended early');
            await out.writeFrom(bytes);
            at += bytes.length;
            job
              ..pagesDone = (at / _chunk).floor()
              ..bytes = at;
            notifyListeners();
          }
        } finally {
          await out.close();
          await from.close();
        }
        if (!stopped && !offWifi) await part.rename(f.path);
      }

      if (job._cancel) {
        queue.remove(job);
        await _deleteFiles([job.bookId]);
      } else if (stopped || offWifi) {
        job.state = paused && !offWifi ? JobState.paused : JobState.queued;
        entry['bytes'] = await part.exists() ? await part.length() : 0;
        await s.put(job.bookId, entry);
      } else {
        final bytes = await f.length();
        entry
          ..['bytes'] = bytes
          ..['state'] = 'done';
        if (!job.cache) entry..remove('cache')..remove('cachedAt');
        await s.put(job.bookId, entry);
        queue.remove(job);
        AppLog.instance.info('downloads', '"${job.title}" done: ${(bytes / 1048576).toStringAsFixed(1)} MB in '
            '${(took.elapsedMilliseconds / 1000).toStringAsFixed(1)} s (network)');
        if (job.cache) await _cacheRoom(bytes, job.bookId);
        local.closeBook(job.bookId); // (open from the share: read from the copy next time)
      }
    } catch (e, st) {
      final trouble = e is _Gone ? FileTrouble.gone : _local!.troubleOf(job.bookId, e);
      if (trouble == FileTrouble.noAnswer) {
        // the share out of reach for now: back in the queue - the copy so far kept - and wait for it
        job
          ..state = JobState.queued
          ..error = null;
        AppLog.instance.warn('downloads', '"${job.title}" waits: the share is out of reach ($e)');
        _waitForShare();
      } else if (job.cache) {
        queue.remove(job);
        await _deleteFiles([job.bookId]);
        ErrorLog.instance.record('Caching "${job.title}" failed.', e, st);
      } else {
        final room = '$e'.startsWith('Exception: not enough room');
        job
          ..state = JobState.failed
          ..error = room
              ? '$e'.replaceFirst('Exception: ', '')
              : switch (trouble) {
                  FileTrouble.gone => 'this book is no longer in its library',
                  FileTrouble.refused => 'the share refused this device (Settings > Libraries: Sign in)',
                  _ => explain(e, thing: 'book').reason,
                };
        if (!room) ErrorLog.instance.record('Download of "${job.title}" failed: ${job.error}.', e, st);
      }
    }
    await _saveQueue();
    notifyListeners();
  }

  /// After Komga couldn't be reached: does it answer now? No: look again in [serverRecheck].
  Future<bool> _serverOk() async {
    if (!waitingForServer) return true;
    try {
      await _api!.me();
      waitingForServer = false;
      notifyListeners();
      return true;
    } catch (_) {
      _serverTimer?.cancel();
      _serverTimer = Timer(serverRecheck, _pump);
      return false;
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

  Future<void> _run(DownloadJob job, _Lookups lookups) async {
    final api = _api!, s = store!;
    // signed out (or another server attached) meanwhile: this book stops where it is - it carried on with the old key
    // to its last page (code review 2026-10-05, #14)
    final session = _session;
    bool gone() => session != _session;
    job
      ..state = JobState.downloading
      ..error = null
      ..pagesDone = 0;
    notifyListeners();
    final took = Stopwatch()..start(); // (for the app's log)
    AppLog.instance.info('downloads', '${job.cache ? 'caching' : 'downloading'} "${job.title}"');
    try {
      final book = await api.book(job.bookId);
      if (book == null) throw KomgaError(404, '/api/v1/books/${job.bookId}'); // gone from Komga
      // an EPUB: the book's file itself (read offline by the EPUB reader) and Komga's positions (its "pages": offline
      // progress is kept as one, sent to Komga later as the read progress) - not page pictures
      final epub = book['media']?['mediaProfile'] == 'EPUB';
      final pages = epub ? const <dynamic>[] : await api.pages(job.bookId);
      final positions = epub ? await api.epubPositions(job.bookId) : null;
      // an EPUB's exact place on Komga, to open at offline - unless progress read here hasn't been sent yet (its own
      // place, in the progress record, stays)
      final unsent = s.progress[job.bookId]?['synced'] == false;
      final komgaPlace = epub && !unsent ? await api.epubProgression(job.bookId) : null;
      job.pagesTotal = epub ? 1 : pages.length;

      // room? (Komga reports page sizes; the book's file size as a fallback)
      final pageSizes = pages.fold<int>(0, (sum, p) => sum + ((p['sizeBytes'] as num?)?.toInt() ?? 0));
      final estimate = pageSizes > 0 ? pageSizes : ((book['sizeBytes'] as num?)?.toInt() ?? 0);
      final alreadyHere = (s.books[job.bookId]?['bytes'] as num?)?.toInt() ?? 0;
      final cap = capBytes;
      if (job.cache) {
        // the cache's own room: the books opened longest ago go; too big for it all, it isn't cached
        if (!await _cacheRoom(estimate, job.bookId)) {
          queue.remove(job);
          await _deleteFiles([job.bookId]);
          // (saved: left in queue.json, it came back at every start - code review, 2026-10-24)
          await _saveQueue();
          notifyListeners();
          return;
        }
      } else if (cap != null && usedBytes - alreadyHere + estimate > cap) {
        throw Exception('not enough room: the download limit is ${_gb(cap)} and ${_gb(usedBytes)} is used '
            '(raise it in Settings)');
      }

      // what it belongs to, for browsing offline
      // (the series, the library list and the series' collections: asked for once per run of the queue, not once per
      // book - a 50-book series made 150 of the same requests; code review 2026-10-05, #42)
      final seriesId = book['seriesId'] as String;
      final series = (lookups.series.containsKey(seriesId)
              ? lookups.series[seriesId]
              : lookups.series[seriesId] = await api.oneSeries(seriesId)) ??
          {'id': seriesId, 'name': book['seriesTitle']};
      final libraries = lookups.libraries ??= await api.libraries();
      final library = libraries.firstWhere((l) => l['id'] == book['libraryId'], orElse: () => {'id': book['libraryId'], 'name': 'Library'});
      final readLists = [
        for (final rl in await api.bookReadLists(job.bookId))
          {
            'id': rl['id'], 'name': rl['name'], 'index': ((rl['bookIds'] as List?) ?? []).indexOf(job.bookId),
            'count': ((rl['bookIds'] as List?) ?? []).length, // offline: the list's last book vs one not downloaded
          },
      ];
      // the book after this one in its series (null: the last), so offline reading can tell "the next book isn't
      // downloaded" from "end of the series" instead of skipping ahead to the next one that is (user, 2026-09-29)
      String? nextId;
      var nextKnown = false;
      try {
        nextId = (await api.nextBook(job.bookId))?['id'] as String?;
        nextKnown = true;
      } catch (_) {
        // not worth failing the download for: offline falls back to the next downloaded book
      }
      final collections = [
        for (final c in lookups.collections[seriesId] ??= await api.seriesCollections(seriesId)) {'id': c['id'], 'name': c['name']},
      ];

      final plan = [
        for (final p in pages)
          {
            'number': p['number'],
            'mediaType': p['mediaType'],
            // its size: two pages side by side pair on it (a wide page is alone - lib/reader/spreads.dart)
            if (p['width'] != null) 'width': p['width'],
            if (p['height'] != null) 'height': p['height'],
            'file': 'pages/${(p['number'] as int).toString().padLeft(4, '0')}.${_extension(p['mediaType'] as String?)}',
          },
      ];
      final entry = <String, dynamic>{
        'book': book, 'series': series, 'library': {'id': library['id'], 'name': library['name']},
        'readLists': readLists, 'collections': collections, 'pages': plan, 'bytes': 0, 'state': 'partial',
        if (job.cache) 'cache': true,
        if (job.cache) 'cachedAt': clock.now().toIso8601String(),
        if (nextKnown) 'nextId': nextId,
        if (epub) 'epubFile': 'book.epub',
        if (epub) 'positions': positions,
      };
      // the exact place with Komga's page (the page alone is only as near as Komga's page count: opened from it, a
      // book left at 31% came up at 12% - Windows, build 79) - set first, so the entry's save writes it too
      if (epub && !unsent) {
        s.setServerProgress(job.bookId, book['readProgress'] as Map?, place: komgaPlace, keepPlace: false);
      }
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
      var offWifi = false; // Wi-Fi went (checked every few pages): stop here, carry on from here on Wi-Fi
      for (final (i, p) in plan.indexed) {
        if (job._cancel || paused || _hold || gone()) break;
        if (i > 0 && i % 5 == 0 && !await _networkOk()) {
          offWifi = true;
          break;
        }
        final f = s.file('${job.bookId}/${p['file']}');
        if (await f.exists() && await f.length() > 0) {
          bytes += await f.length();
        } else {
          final page = Stopwatch()..start();
          final data = await api.pageBytes(job.bookId, p['number'] as int);
          // a page that took long: the app was likely in the background meanwhile (frozen by iOS) - for the log
          // (downloads in the background, unchecked on iOS - backlog)
          if (page.elapsed > const Duration(seconds: 10)) {
            AppLog.instance.warn('downloads', '"${job.title}" page ${i + 1} took ${page.elapsed.inSeconds} s');
          }
          await f.parent.create(recursive: true);
          // to a .part file first, renamed once it's all there: the app killed mid-write left a cut-off page that the
          // next run counted as downloaded - unreadable for good (code review, 2026-09-30)
          final part = File('${f.path}.part');
          await part.writeAsBytes(data, flush: true);
          await part.rename(f.path);
          bytes += data.length;
        }
        job
          ..pagesDone += 1
          ..bytes = bytes;
        notifyListeners();
      }

      // an EPUB: its one file (kept if already whole from an earlier try)
      if (epub && !(job._cancel || paused || _hold || gone())) {
        final f = s.file('${job.bookId}/book.epub');
        if (await f.exists() && await f.length() > 0) {
          bytes = await f.length();
        } else {
          final data = await api.bookFileBytes(job.bookId);
          await f.parent.create(recursive: true);
          final part = File('${f.path}.part'); // whole or not at all (see pages above)
          await part.writeAsBytes(data, flush: true);
          await part.rename(f.path);
          bytes = data.length;
        }
        job
          ..pagesDone = 1
          ..bytes = bytes;
        notifyListeners();
      }

      if (gone()) {
        job.state = JobState.queued; // the pages so far stay; it goes on when this account is back
        return;
      }
      if (job._cancel) {
        queue.remove(job);
        await _deleteFiles([job.bookId]);
      } else if (paused || _hold || offWifi) {
        // held (offline) or off Wi-Fi: back in the queue, carries on later; paused by hand: paused
        job.state = paused && !_hold && !offWifi ? JobState.paused : JobState.queued;
        entry['bytes'] = bytes;
        await s.put(job.bookId, entry);
      } else {
        entry
          ..['bytes'] = bytes
          ..['state'] = 'done';
        if (!job.cache) entry..remove('cache')..remove('cachedAt'); // (downloaded on purpose meanwhile)
        await s.put(job.bookId, entry);
        queue.remove(job);
        AppLog.instance.info('downloads', '"${job.title}" done: ${(bytes / 1048576).toStringAsFixed(1)} MB in '
            '${(took.elapsedMilliseconds / 1000).toStringAsFixed(1)} s');
        // (its real size now: the cache back under its limit if Komga's sizes were short)
        if (job.cache) await _cacheRoom(bytes, job.bookId);
      }
    } catch (e, st) {
      if (gone()) {
        job.state = JobState.queued; // (a page refused once signed out: not this book's failure)
        return;
      }
      if (e is KomgaUnreachable) {
        // Komga (or the network) gone for now: back in the queue - pages so far kept - and wait for it
        job
          ..state = JobState.queued
          ..error = null;
        waitingForServer = true;
        AppLog.instance.warn('downloads', '"${job.title}" waits: Komga out of reach ($e)');
        _serverTimer?.cancel();
        _serverTimer = Timer(serverRecheck, _pump);
      } else if (job.cache) {
        // the cache's: dropped, tried again when the book is next opened (code review, 2026-10-24: kept as failed, out
        // of sight on the Downloads screen, it stopped the book from ever being cached)
        queue.remove(job);
        await _deleteFiles([job.bookId]);
        ErrorLog.instance.record('Caching "${job.title}" failed.', e, st);
      } else {
        // plain words for the Downloads screen ("Failed: this book is no longer on Komga."); the room message is
        // already plain
        final room = '$e'.startsWith('Exception: not enough room');
        final ex = explain(e, thing: 'book');
        job
          ..state = JobState.failed
          ..error = room
              ? '$e'.replaceFirst('Exception: ', '')
              : ex.kind == ErrorKind.gone ? 'this book is no longer on Komga' : ex.reason;
        if (!room) ErrorLog.instance.record('Download of "${job.title}" failed: ${job.error}.', e, st);
        if (room) AppLog.instance.warn('downloads', '"${job.title}" failed: ${job.error}');
      }
    }
    await _saveQueue();
    notifyListeners();
  }
}

/// A network book gone from the local libraries (its library removed, or its file gone since the scan).
class _Gone implements Exception {
  const _Gone();
}
