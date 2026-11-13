import 'dart:async';
import 'dart:convert';

import 'package:clock/clock.dart';
import 'package:flutter/widgets.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../app_log.dart';
import '../book_source.dart';
import '../local/book_names.dart' show isLocalId;
import '../pins.dart';
import '../view_filter.dart';
import '../widgets/pin_tile.dart' show pinView;
import 'connection.dart';
import 'downloads.dart';

/// What a rule keeps downloaded: a series, a read list or a pin.
enum RuleKind { series, readList, pin }

/// "Keep the next [keep] unread books of this downloaded" (user, 2026-11-12, reports\11-12-smart-downloads.md).
@immutable
class SmartRule {
  const SmartRule({required this.kind, required this.id, required this.title, this.keep = defaultKeep, this.pin});

  static const defaultKeep = 3; // (user, 11-12: "3")
  static const most = 10;

  final RuleKind kind;

  /// The series' or read list's id; a pin's: its view ([pinKey]).
  final String id;
  final String title;
  final int keep;

  /// A pin's view (its name aside).
  final Pin? pin;

  /// A pin's view as a rule's id: two pins of the same view are one rule.
  static String pinKey(Pin p) => jsonEncode({...p.toJson(), 'name': null});

  /// Komga's, or a local library's (the network books') - where its books are asked for.
  bool get local => switch (kind) {
        RuleKind.pin => pin?.id != null && isLocalId(pin!.id!),
        _ => isLocalId(id),
      };

  SmartRule withKeep(int n) => SmartRule(kind: kind, id: id, title: title, keep: n, pin: pin);
  SmartRule withId(String to) => SmartRule(kind: kind, id: to, title: title, keep: keep, pin: pin);

  Map<String, dynamic> toJson() =>
      {'kind': kind.name, 'id': id, 'title': title, 'keep': keep, if (pin != null) 'pin': pin!.toJson()};

  static SmartRule? fromJson(Map<String, dynamic> j) {
    final kind = RuleKind.values.where((k) => k.name == j['kind']).firstOrNull;
    final id = j['id'], keep = j['keep'];
    if (kind == null || id is! String || keep is! int || keep < 1) return null;
    final pin = j['pin'] is Map ? Pin.fromJson(Map<String, dynamic>.from(j['pin'] as Map)) : null;
    if (kind == RuleKind.pin && pin == null) return null;
    return SmartRule(kind: kind, id: id, title: '${j['title'] ?? ''}', keep: keep.clamp(1, most), pin: pin);
  }
}

/// Smart downloads: this device's rules, and the books they downloaded. A top-up asks each rule's source for its next
/// unread books, queues the ones not here, and removes the rule's books no rule wants any more - read, or not started
/// (one part way through stays until it's read). Books you downloaded yourself are never touched. Komga or the share
/// not answering: that rule waits for the next top-up.
class SmartDownloads extends ChangeNotifier with WidgetsBindingObserver {
  SmartDownloads._();
  static final SmartDownloads instance = SmartDownloads._();

  static const _rulesKey = 'smart.rules', _booksKey = 'smart.books', _onKey = 'smart.on';

  final List<SmartRule> rules = [];

  /// Settings > Storage & Downloads > Smart downloads: off, no rule tops up (and nothing is removed).
  bool on = true;

  /// The books a rule downloaded (or queued): a rule's mark, and the ones it may remove.
  final Set<String> books = {};

  /// Each rule's next books, as the last top-up found them (by rule id) - "keeping 2 of 3".
  final Map<String, List<String>> wanted = {};

  /// When the last top-up ran (null: not yet).
  DateTime? lastTopUp;

  Downloads get _d => Downloads.instance;
  bool _loaded = false, _observing = false;

  Future<void> load() async {
    final p = await SharedPreferences.getInstance();
    rules
      ..clear()
      ..addAll(_decode(p.getString(_rulesKey)));
    books
      ..clear()
      ..addAll(p.getStringList(_booksKey) ?? const []);
    on = p.getBool(_onKey) ?? true;
    _loaded = true;
    if (!_observing) {
      _observing = true;
      WidgetsBinding.instance.addObserver(this);
      Connection.instance.addListener(_onConnection);
    }
    _wasOffline = Connection.instance.offline;
    notifyListeners();
  }

  static List<SmartRule> _decode(String? raw) {
    if (raw == null) return [];
    try {
      return [
        for (final j in jsonDecode(raw) as List)
          if (SmartRule.fromJson(Map<String, dynamic>.from(j as Map)) case final r?) r,
      ];
    } catch (_) {
      return [];
    }
  }

  Future<void> _save() async {
    final p = await SharedPreferences.getInstance();
    await p.setString(_rulesKey, jsonEncode([for (final r in rules) r.toJson()]));
    await p.setStringList(_booksKey, books.toList());
  }

  /// Tests: back to nothing (the singleton outlives a test).
  @visibleForTesting
  void reset() {
    rules.clear();
    books.clear();
    wanted.clear();
    on = true;
    lastTopUp = null;
    _loaded = false;
    _again = false;
    _running = null;
  }

  // ---- rules -------------------------------------------------------------------------------------------------------

  SmartRule? ruleFor(RuleKind kind, String id) => rules.where((r) => r.kind == kind && r.id == id).firstOrNull;

  /// A pin's rule (null: none). A pinned series or read list is that series' or list's rule.
  SmartRule? ruleForPin(Pin p) => switch (p.kind) {
        'series' => ruleFor(RuleKind.series, p.id!),
        'readlist' => ruleFor(RuleKind.readList, p.id!),
        _ => ruleFor(RuleKind.pin, SmartRule.pinKey(p)),
      };

  /// Whether a pin can have a rule: not a book, nor a view of collections or read lists.
  static bool pinCanKeep(Pin p) =>
      p.kind != 'book' && !(p.kind == 'library' && (p.mode == 'collections' || p.mode == 'readLists'));

  /// Keeps the next [keep] of a series / read list downloaded; 0: the rule goes (its books not started go at the
  /// top-up).
  Future<void> setRule(RuleKind kind, String id, String title, int keep, {Pin? pin}) async {
    rules.removeWhere((r) => r.kind == kind && r.id == id);
    if (keep > 0) {
      rules.add(SmartRule(kind: kind, id: id, title: title, keep: keep.clamp(1, SmartRule.most), pin: pin));
    }
    wanted.remove(id);
    await _save();
    notifyListeners();
    AppLog.instance.info('smart', keep > 0 ? 'keep next $keep of "$title"' : 'no rule for "$title"');
    unawaited(topUp());
  }

  /// A pin's rule (a pinned series or read list: that one's).
  Future<void> setPinRule(Pin p, int keep) => switch (p.kind) {
        'series' => setRule(RuleKind.series, p.id!, p.title, keep),
        'readlist' => setRule(RuleKind.readList, p.id!, p.title, keep),
        _ => setRule(RuleKind.pin, SmartRule.pinKey(p), p.name, keep, pin: p),
      };

  Future<void> setOn(bool v) async {
    on = v;
    notifyListeners();
    await (await SharedPreferences.getInstance()).setBool(_onKey, v);
    if (v) unawaited(topUp());
  }

  /// A rule's book: its own mark on the poster.
  bool isRuled(String bookId) => books.contains(bookId);

  /// You downloaded these yourself: yours from now on - a rule doesn't remove them.
  void takenByHand(Iterable<String> ids) {
    var any = false;
    for (final id in ids) {
      any |= books.remove(id);
    }
    if (!any) return;
    unawaited(_save());
    notifyListeners();
  }

  /// Network books whose ids changed with their paths (Apply edits to files): rules and marks follow.
  Future<void> renameIds(Map<String, String> ids) async {
    var any = false;
    for (final (i, r) in rules.indexed.toList()) {
      final to = r.kind == RuleKind.pin ? null : ids[r.id];
      if (to != null) {
        rules[i] = r.withId(to);
        any = true;
      }
    }
    for (final MapEntry(key: from, value: to) in ids.entries) {
      if (books.remove(from)) {
        books.add(to);
        any = true;
      }
    }
    if (!any) return;
    await _save();
    notifyListeners();
  }

  /// A rule's books in the queue that stopped for lack of room - Downloads says "Download limit reached".
  bool get limitReached => books.any((id) {
        final j = _d.downloadJob(id);
        return j != null && j.state == JobState.failed && (j.error ?? '').startsWith('not enough room');
      });

  /// How many of a rule's next books are downloaded now.
  int keeping(SmartRule r) => (wanted[r.id] ?? const []).where(_d.isDownloaded).length;

  // ---- when it tops up: the start, back in the front, leaving a book, back online, a rule changed, Top up now ------

  bool _wasOffline = false;

  void _onConnection() {
    final now = Connection.instance.offline;
    if (_wasOffline && !now) unawaited(topUp());
    _wasOffline = now;
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) unawaited(topUp());
  }

  Future<void>? _running;
  bool _again = false;

  /// Brings every rule's books up to date. One at a time: asked for while one runs, it runs once more after it.
  Future<void> topUp() {
    if (_running != null) {
      _again = true;
      return _running!;
    }
    return _running = () async {
      try {
        do {
          _again = false;
          await _once();
        } while (_again);
      } finally {
        _running = null;
      }
    }();
  }

  Future<void> _once() async {
    if (!_loaded || !on || (rules.isEmpty && books.isEmpty) || _d.hold) return;
    final failed = <bool>{}; // the sources that didn't answer: local (true) / Komga (false)
    final want = <String, Map>{};
    for (final r in rules) {
      final src = _sourceFor(r.local);
      if (src == null) {
        failed.add(r.local);
        continue;
      }
      try {
        final next = await nextBooks(src, r);
        wanted[r.id] = [for (final b in next) b['id'] as String];
        for (final b in next) {
          want[b['id'] as String] = b;
        }
      } catch (e) {
        failed.add(r.local);
        AppLog.instance.info('smart', '"${r.title}" waits: $e');
      }
    }
    // the new ones: queued as the rules' (one you downloaded yourself, or queued, stays yours)
    final add = [
      for (final MapEntry(key: id, value: b) in want.entries)
        if (_d.canDownload(id) && !_d.isDownloaded(id) && _d.downloadJob(id) == null) b,
    ];
    if (add.isNotEmpty) {
      await _d.add(add, byRule: true);
      for (final b in add) {
        final id = b['id'] as String;
        if (_d.downloadJob(id) != null || _d.isDownloaded(id)) books.add(id);
      }
    }
    // the rules' books no rule wants now: read, or not started, they go; part way through, they stay until read
    final open = _d.openBook;
    final gone = <String>[];
    for (final id in books.toList()) {
      if (!_d.isDownloaded(id) && _d.downloadJob(id) == null) {
        books.remove(id); // removed by hand meanwhile
        continue;
      }
      if (want.containsKey(id) || id == open || failed.contains(isLocalId(id))) continue;
      final src = _sourceFor(isLocalId(id));
      if (src == null) continue;
      try {
        final b = await src.book(id);
        final rp = b?['readProgress'];
        if (b != null && rp is Map && rp['completed'] != true) continue; // started: kept until read
        gone.add(id);
      } catch (_) {
        // not answering: asked again next time
      }
    }
    for (final id in gone) {
      books.remove(id);
      _d.downloadJob(id) != null ? await _d.cancel(id) : await _d.removeAll([id]);
    }
    if (add.isNotEmpty || gone.isNotEmpty) {
      AppLog.instance.info('smart', 'top-up: ${add.length} queued, ${gone.length} removed');
    }
    lastTopUp = clock.now();
    await _save();
    notifyListeners();
  }

  BookSource? _sourceFor(bool local) => local ? _d.local : _d.komga;

  /// A rule's next books: its unread and in-progress ones, in its order, the first [SmartRule.keep].
  @visibleForTesting
  static Future<List<Map>> nextBooks(BookSource src, SmartRule r) async {
    const unread = ['UNREAD', 'IN_PROGRESS'];
    List<Map> of(Map<String, dynamic> page) => [for (final b in (page['content'] as List? ?? const [])) b as Map];
    switch (r.kind) {
      case RuleKind.series:
        return of(await src.seriesBooks(r.id, readStatus: unread, size: r.keep));
      case RuleKind.readList:
        return of(await src.readListBooks(r.id, readStatus: unread, size: r.keep));
      case RuleKind.pin:
        final p = r.pin!;
        // the pin's view with its read books left out, in its own order (user, 11-12: "first 3 of the pin")
        final shown = Pin(name: p.name, kind: p.kind, id: p.id, title: p.title, filter: ReadFilter.hideRead.name,
            mode: p.mode, sort: p.sort, filters: p.filters);
        final ofSeries = p.kind == 'collection' || (p.kind == 'library' && (p.mode == null || p.mode == 'series'));
        if (!ofSeries) return of(await pinView(src, shown, size: r.keep)).take(r.keep).toList();
        // a view of series: their books, series by series, each by number
        final out = <Map>[];
        for (final s in of(await pinView(src, shown, size: 50))) {
          if (out.length >= r.keep) break;
          out.addAll(of(await src.seriesBooks(s['id'] as String, readStatus: unread, size: r.keep - out.length)));
        }
        return out.take(r.keep).toList();
    }
  }
}
