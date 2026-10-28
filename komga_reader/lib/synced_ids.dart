import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'book_source.dart';
import 'local/book_names.dart' show isLocalId;
import 'refresh_gate.dart';

/// Sets of ids kept on the device and in the user's Komga client settings, so every device agrees - what's hidden from
/// On deck ([OnDeckHidden]), the books whose pages pair shifted by one ([PairShift]). Komga's copy is the truth except
/// for this device's changes that haven't reached it yet: those win, and go.
/// (Taken out of OnDeckHidden, 2026-10-16, for the second one; the review history below is its.)
abstract class SyncedIds extends ChangeNotifier {
  SyncedIds(this._syncKey, this._local, this._names) : _dirtyKey = '$_local.unsent' {
    _clearSets();
  }

  final String _syncKey; // its key in Komga's client settings
  final String _local;
  final String _dirtyKey; // changed while Komga couldn't be reached
  final List<String> _names;

  /// The sets, by name.
  @protected
  final Map<String, Set<String>> sets = {};

  void _clearSets() {
    for (final n in _names) {
      sets[n] = {};
    }
  }

  BookSource? _api;

  bool get isEmpty => sets.values.every((s) => s.isEmpty);
  int get count => sets.values.fold(0, (n, s) => n + s.length);

  /// [fetch] false (offline mode): this device's copy only - nothing is sent or asked for.
  Future<void> load(BookSource api, {bool fetch = true}) async {
    _api = api;
    final p = await SharedPreferences.getInstance();
    final before = _raw;
    final raw = p.getString(_local), here = p.getString(_hereKey);
    if (raw != null) _decode(raw);
    if (here != null) _decodeHere(here);
    _loaded = true;
    if (_raw != before) notifyListeners();
    if (!fetch) return;
    await _fetch(p);
  }

  /// Komga's list: this device's unsent change goes instead (it wins); a list asked for before a change here is
  /// dropped. Never re-reads the device's copy - Home's refresh did, and put back a list from before a hide that was
  /// still being saved, undoing it (code review 2026-10-05, #1).
  Future<void> _fetch(SharedPreferences p) async {
    final api = _api;
    if (api == null) return;
    if (_pending || (p.getBool(_dirtyKey) ?? false)) {
      await _send(); // this device's changes haven't reached Komga: they win
      return;
    }
    try {
      final changes = _changes;
      _gate.asked();
      final remote = (await api.clientSettings())[_syncKey]?['value'];
      if (_changes != changes) return; // changed here meanwhile: that goes to Komga, not the other way
      if (remote is String) {
        final before = _raw;
        _decode(remote);
        if (_raw == before) return; // nothing new: nobody told (Home reloaded three times per reload - #34)
        await p.setString(_local, _synced);
        notifyListeners();
      }
    } catch (_) {
      // offline / not reachable: the device's copy stands
    }
  }

  /// Komga's list again - Home calls it each time it reloads, so a change made on another device arrives without a
  /// restart (user, 2026-10-05). Several reloads in a row ask once ([RefreshGate]).
  Future<void> refresh() async {
    if (_api == null || !_loaded) return;
    final p = await SharedPreferences.getInstance();
    await _gate.run(() => _fetch(p));
  }

  final _gate = RefreshGate();
  int _changes = 0; // changed on this device: a list from Komga asked for before is out of date
  bool _loaded = false; // the device's copy read: until then there's nothing to send (#2 sent an empty list)
  // a change here not on Komga yet - known at once, not only once the flag is saved (a refresh in between fetched
  // Komga's older list and put it over the hide - #1)
  bool _pending = false;
  bool _sending = false, _sendAgain = false; // one send at a time, the list as it is when it's this one's turn
  Timer? _retry;

  /// Switch connection (online / offline) without reloading; a change made while Komga couldn't be reached goes now
  /// (it used to wait for the next start - test audit, 2026-09-30). Not before the device's copy is read: [load]
  /// sends it then (start-up sent [] here - code review 2026-10-05, #2).
  void useApi(BookSource api) {
    _api = api;
    if (!_loaded) return;
    SharedPreferences.getInstance().then((p) {
      if (p.getBool(_dirtyKey) ?? false) _send();
    });
  }

  /// Id [id] in or out of set [name].
  @protected
  void put(String name, String id, bool inSet) => change(() => inSet ? sets[name]!.add(id) : sets[name]!.remove(id));

  @protected
  void change(void Function() f) {
    final synced = _synced;
    f();
    notifyListeners();
    if (_synced == synced) { // only this device's own changed: nothing for Komga
      SharedPreferences.getInstance().then((p) => p.setString(_hereKey, _here));
      return;
    }
    _changes++;
    _pending = true;
    SharedPreferences.getInstance().then((p) async {
      await p.setString(_hereKey, _here);
      await p.setString(_local, _synced);
      await p.setBool(_dirtyKey, true); // until Komga has it
      await _send();
    });
  }

  /// This device's own ids - a local library's series and books (review, 2026-10-26: as its pins are): never sent to
  /// Komga (another device hasn't its folders), kept when Komga's list comes, and through signing out.
  String get _hereKey => '$_local.here';

  String get _raw => jsonEncode({for (final n in _names) n: sets[n]!.toList()});
  String get _synced => jsonEncode({for (final n in _names) n: [for (final id in sets[n]!) if (!isLocalId(id)) id]});
  String get _here => jsonEncode({for (final n in _names) n: [for (final id in sets[n]!) if (isLocalId(id)) id]});

  /// To Komga, one send at a time with the list as it is then (two quick changes landed out of order, and a fast
  /// failure then a slow success cleared the unsent mark - code review 2026-10-05, #3). Not reachable: kept marked
  /// unsent and tried again in a minute.
  Future<void> _send() async {
    if (_sending) {
      _sendAgain = true;
      return;
    }
    _sending = true;
    _retry?.cancel();
    final p = await SharedPreferences.getInstance();
    try {
      final api = _api;
      if (api == null) throw StateError('no server');
      await api.putClientSetting(_syncKey, _synced);
      if (!_sendAgain) {
        _pending = false;
        await p.setBool(_dirtyKey, false); // changed meanwhile: still to send
      }
    } catch (_) {
      await p.setBool(_dirtyKey, true);
      if (_api != null) _retry = Timer(const Duration(minutes: 1), _send);
    } finally {
      _sending = false;
    }
    if (_sendAgain) {
      _sendAgain = false;
      await _send();
    }
  }

  /// Komga's list (or the device's copy of it) - this device's own ids kept as they are.
  void _decode(String raw) {
    try {
      final j = jsonDecode(raw) as Map;
      for (final n in _names) {
        sets[n] = {
          for (final id in (j[n] as List? ?? const [])) if (!isLocalId(id as String)) id,
          ...sets[n]!.where(isLocalId),
        };
      }
    } catch (_) {
      // damaged: keep what we have
    }
  }

  /// This device's own ids, as kept.
  void _decodeHere(String raw) {
    try {
      final j = jsonDecode(raw) as Map;
      for (final n in _names) {
        sets[n]!.addAll([for (final id in (j[n] as List? ?? const [])) if (isLocalId(id as String)) id]);
      }
    } catch (_) {
      // damaged: none
    }
  }

  /// Signed out: the account's list goes from this device (it comes back from Komga on signing in again) - an unsent
  /// change here was sent to the next account, over its own list (code review, 2026-09-30). This device's own stay.
  Future<void> clearAccount() async {
    _retry?.cancel();
    _api = null;
    _loaded = false;
    _pending = false;
    for (final n in _names) {
      sets[n] = {...sets[n]!.where(isLocalId)};
    }
    notifyListeners();
    final p = await SharedPreferences.getInstance();
    await p.remove(_local);
    await p.remove(_dirtyKey);
  }

  @visibleForTesting
  void reset() {
    _retry?.cancel();
    _api = null;
    _loaded = false;
    _pending = false;
    _clearSets();
  }
}

/// Comics in two pages: the books whose pairing is shifted by one ("Shift pairing by one" on the reader's bottom bar -
/// user, 2026-10-16: per book, synced). See lib/reader/spreads.dart's pairPages.
class PairShift extends SyncedIds {
  PairShift._() : super(komgaKey, 'pairshift', const ['books']);
  static const komgaKey = 'komgareader.pairshift';
  static final PairShift instance = PairShift._();

  bool shifted(String bookId) => sets['books']!.contains(bookId);
  void setShifted(String bookId, bool on) => put('books', bookId, on);
}
