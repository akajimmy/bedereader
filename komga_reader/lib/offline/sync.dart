import 'dart:async';

import 'package:flutter/widgets.dart';

import '../api.dart';
import '../epub/progress.dart' show komgaEpubPage;
import 'connection.dart';
import 'downloads.dart';
import 'store.dart';

/// A book whose progress had changed both here (offline) and on Komga: what each side had, and which was kept.
class ProgressConflict {
  const ProgressConflict({required this.title, required this.here, required this.komga, required this.keptHere});
  final String title, here, komga;
  final bool keptHere;
}

class SyncResult {
  const SyncResult({this.sent = 0, this.conflicts = const [], this.gone = 0});
  final int sent; // offline progress sent to Komga without a clash
  final List<ProgressConflict> conflicts;
  final int gone; // books no longer on the server (their queued progress is dropped)
  bool get isEmpty => sent == 0 && conflicts.isEmpty && gone == 0;
}

/// Offline phase 5: reading progress made offline goes to Komga once it's reachable (user's rules, 2026-09-28):
/// - only this device changed it -> sent as it is (including "mark as unread");
/// - Komga changed too (another device / the web) -> **further wins**: never back a page, never un-finish - and the
///   books are listed in an alert with what each side had and what was kept.
/// Runs when the app goes back online, at start-up, and on returning to the app. It also refreshes the downloaded
/// copies from Komga (reading done elsewhere), and keeps them current while reading online ([Komga.onProgressWritten]).
class ProgressSync extends ChangeNotifier with WidgetsBindingObserver {
  ProgressSync._();
  static final ProgressSync instance = ProgressSync._();

  static const refreshGap = Duration(minutes: 2); // resume checks: not more often than this

  bool running = false;
  SyncResult? last; // shown once by the app, then cleared ([takeResult])
  DateTime? _lastRun;
  bool _wasOffline = false, _started = false;

  OfflineStore? get _store => Downloads.instance.store;
  Connection get _conn => Connection.instance;

  /// Wired up once the connection is loaded.
  void start() {
    Komga.onProgressWritten = _mirror;
    if (!_started) {
      _started = true;
      _conn.addListener(_onConnection);
      WidgetsBinding.instance.addObserver(this);
    }
    _wasOffline = _conn.offline;
    unawaited(run());
  }

  void _onConnection() {
    final now = _conn.offline;
    if (_wasOffline && !now) unawaited(run()); // back online
    _wasOffline = now;
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) return;
    final l = _lastRun;
    if (l == null || DateTime.now().difference(l) > refreshGap || (_store?.unsynced.isNotEmpty ?? false)) unawaited(run());
  }

  SyncResult? takeResult() {
    final r = last;
    last = null;
    return r;
  }

  int get pending => _store?.unsynced.length ?? 0;

  /// Sends what's queued, then refreshes the downloaded copies. Quietly stops if Komga stops answering.
  Future<void> run() async {
    final store = _store, api = _conn.online;
    if (running || store == null || api == null || _conn.offline) return;
    running = true;
    _lastRun = DateTime.now();
    notifyListeners();
    var sent = 0, gone = 0;
    final conflicts = <ProgressConflict>[];
    try {
      // each book on its own: one Komga keeps refusing (a 403, a page it no longer has) waits for the next run
      // instead of holding up all the others behind it (code review, 2026-09-30)
      for (final id in List.of(store.unsynced)) {
        try {
          final local = store.progress[id]!;
          final book = await api.book(id);
          if (book == null) {
            store.progress.remove(id);
            gone++;
            continue;
          }
          final server = OfflineStore.norm(book['readProgress'] as Map?);
          final here = _norm(local);
          final base = local['base'] as Map?;
          final komgaChanged = base != null && !_same(server, base) && !_same(server, here);
          final place = store.books[id]?['epubProgression'] as Map?; // an EPUB's exact place, read here
          if (!komgaChanged) {
            // (an EPUB's place goes even on the same page: Komga's pages are coarser than its places)
            if (!_same(server, here) || place != null) await _send(api, id, here, book, place: place);
            sent++;
            store.setServerProgress(id, _asReadProgress(here, book));
          } else {
            final keepHere = _rank(here) >= _rank(server);
            if (keepHere) await _send(api, id, here, book, place: place);
            store.setServerProgress(id, keepHere ? _asReadProgress(here, book) : book['readProgress'] as Map?);
            conflicts.add(ProgressConflict(title: _title(book), here: _describe(here), komga: _describe(server),
                keptHere: keepHere));
          }
          await store.saveProgress();
        } on KomgaUnreachable {
          rethrow; // gone offline: stop, everything left stays queued
        } catch (_) {
          // this book: next time; the rest carry on
        }
      }
      await _refresh(api, store);
    } on KomgaUnreachable {
      // back offline mid-way: the rest stays queued for next time
    } catch (_) {
      // anything else: try again on the next run
    } finally {
      running = false;
      final r = SyncResult(sent: sent, conflicts: conflicts, gone: gone);
      if (!r.isEmpty) last = r;
      notifyListeners();
    }
  }

  /// Downloaded copies take Komga's current progress (one request per series), except books with unsent changes.
  Future<void> _refresh(Komga api, OfflineStore store) async {
    final bySeries = <String, List<String>>{};
    store.books.forEach((id, e) {
      final s = (e['book'] as Map?)?['seriesId'] as String?;
      if (s != null) bySeries.putIfAbsent(s, () => []).add(id);
    });
    var changed = false;
    final finishedElsewhere = <String>[];
    // each series on its own: one deleted on Komga stopped the refresh of every series after it (code review,
    // 2026-09-30); now its downloads are marked "no longer on Komga" and the rest carry on
    var booksChanged = false;
    for (final entry in bySeries.entries) {
      final Map<String, dynamic> r;
      // progress saved here after this moment is newer than Komga's answer (#11: a page read online while the
      // refresh was on its way was put back to the page before, and the next sync said Komga had changed too)
      final asked = DateTime.now();
      try {
        r = await api.seriesBooks(entry.key);
      } on KomgaUnreachable {
        rethrow;
      } on KomgaError catch (e) {
        if (e.status == 404) {
          for (final id in entry.value) {
            if (store.books[id]?['gone'] != true) {
              store.books[id]?['gone'] = true;
              changed = booksChanged = true;
            }
          }
        }
        continue;
      } catch (_) {
        continue;
      }
      // the series is there: each downloaded book is marked by whether Komga still lists it (a single book deleted
      // went unmarked - missing-tests audit, 2026-09-30). Only on a complete list: past one page, unlisted proves nothing.
      final listed = {for (final b in (r['content'] as List?) ?? const []) (b as Map)['id'] as String};
      final complete = r['last'] != false;
      for (final id in entry.value) {
        if (listed.contains(id)) {
          if (store.books[id]?.remove('gone') != null) changed = booksChanged = true; // there after all
        } else if (complete && store.books[id] != null && store.books[id]!['gone'] != true) {
          store.books[id]!['gone'] = true;
          changed = booksChanged = true;
        }
      }
      for (final b in (r['content'] as List?) ?? const []) {
        final id = (b as Map)['id'] as String;
        if (!entry.value.contains(id) || store.progress[id]?['synced'] == false) continue;
        final rp = b['readProgress'] as Map?;
        final cur = store.progress[id];
        if (cur != null && _same(_norm(cur), OfflineStore.norm(rp))) continue;
        final at = DateTime.tryParse(cur?['at'] as String? ?? '');
        // saved here since Komga was asked (or that same moment - the clock can't tell them apart): that's the newer
        if (at != null && !at.isBefore(asked)) continue;
        store.setServerProgress(id, rp);
        changed = true;
        // an EPUB: its exact place too, for opening at offline (else the copy opened where it was when downloaded)
        if (store.books[id]?['positions'] != null) {
          try {
            final place = await api.epubProgression(id);
            if (place == null) {
              store.books[id]!.remove('epubProgression');
            } else {
              store.books[id]!['epubProgression'] = place;
            }
            booksChanged = true;
          } on KomgaUnreachable {
            rethrow;
          } catch (_) {
            // the page alone: near enough
          }
        }
        // read on another device (it wasn't read here before): Delete once read
        if (cur != null && rp?['completed'] == true) finishedElsewhere.add(id);
      }
    }
    if (changed) {
      await (booksChanged ? store.save() : store.saveProgress()); // progress alone: the small file
      Downloads.instance.notifyListeners(); // tiles showing downloaded books
    }
    finishedElsewhere.forEach(Downloads.instance.bookFinished);
  }

  /// Written to Komga while online: the downloaded copy follows, and it's the new baseline.
  void _mirror(Komga api, ProgressWrite w) {
    final store = _store;
    if (store == null || !identical(api, _conn.online)) return;
    final ids = w.bookId != null
        ? [w.bookId!]
        : [for (final e in store.books.entries) if ((e.value['book'] as Map?)?['seriesId'] == w.seriesId) e.key];
    var changed = false;
    for (final id in ids) {
      if (!store.books.containsKey(id)) continue;
      final place = w.place;
      if (place != null) {
        // an EPUB's place, read online: the copy opens there offline too, its page as Komga makes it
        final entry = store.books[id]!;
        entry['epubProgression'] = place;
        final total = ((place['locator'] as Map?)?['locations'] as Map?)?['totalProgression'] as num?;
        final page = komgaEpubPage(total?.toDouble(), ((entry['book'] as Map?)?['media'] as Map?)?['pagesCount'] as int?);
        if (page != null) store.setServerProgress(id, {'page': page, 'completed': false});
        changed = true;
        continue;
      }
      final pages = (store.books[id]?['pages'] as List?)?.length ?? 0;
      store.setServerProgress(id, w.unread ? null : {'page': w.page ?? pages, 'completed': w.completed});
      changed = true;
    }
    // (an EPUB's place is in the book's own record: the whole store, not the progress file alone)
    if (changed) unawaited((w.place != null ? store.save() : store.saveProgress()).catchError((Object _) {}));
    if (w.completed && !w.unread) ids.forEach(Downloads.instance.bookFinished); // Delete once read
  }

  /// [place]: an EPUB's exact place read here (its stored progression): sent as it is - Komga works its read progress
  /// out from it, and the book reopens there on every device; sent as a page, only the page moved, and Komga's place
  /// stayed where it was.
  static Future<void> _send(Komga api, String id, Map<String, dynamic> p, Map book, {Map? place}) async {
    if (p['none'] == true) {
      await api.markUnread(id);
    } else if (p['completed'] == true) {
      await api.markRead(id);
    } else if (place != null) {
      await api.setEpubProgression(id, place.cast<String, dynamic>());
    } else {
      await api.setProgress(id, (p['page'] as int).clamp(1, 1 << 20));
    }
  }

  static Map<String, dynamic>? _asReadProgress(Map<String, dynamic> p, Map book) {
    if (p['none'] == true) return null;
    final pages = (book['media'] as Map?)?['pagesCount'] as int? ?? p['page'] as int;
    return {'page': p['completed'] == true ? pages : p['page'], 'completed': p['completed'] == true};
  }

  static Map<String, dynamic> _norm(Map p) =>
      {'page': p['page'] ?? 0, 'completed': p['completed'] == true, 'none': p['none'] == true};

  static bool _same(Map a, Map b) {
    if ((a['none'] == true) != (b['none'] == true)) return false;
    if (a['none'] == true) return true;
    if ((a['completed'] == true) != (b['completed'] == true)) return false;
    return a['completed'] == true || a['page'] == b['page']; // read is read, whatever page it was left on
  }

  /// How far along: unread < page 1 < page 2 ... < read.
  static int _rank(Map p) => p['none'] == true ? -1 : p['completed'] == true ? 1 << 30 : (p['page'] as int? ?? 0);

  static String _describe(Map p) =>
      p['none'] == true ? 'unread' : p['completed'] == true ? 'read' : 'page ${p['page']}';

  static String _title(Map book) {
    final number = (book['metadata'] as Map?)?['number'] ?? book['number'];
    return '${book['seriesTitle'] ?? ''} #$number'.trim();
  }

  /// Tests: back to a clean state.
  @visibleForTesting
  void reset() {
    running = false;
    last = null;
    _lastRun = null;
    Komga.onProgressWritten = null;
  }
}
