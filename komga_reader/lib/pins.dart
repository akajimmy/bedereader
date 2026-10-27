import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'api.dart';
import 'book_title.dart';
import 'errors.dart';
import 'refresh_gate.dart';
import 'view_filter.dart';
import 'book_source.dart';

/// A library sort field's natural direction: titles A -> Z, dates newest first.
bool naturalDesc(String key) => key != 'title';

/// A library's sort keys -> Komga's sort fields, series mode. One definition for the library screen and a pinned
/// view's poster (pin_tile.dart's pinView), so a key added here sorts the same in both (code review 2026-10-05, #52).
/// The first entry is the fallback field for an unknown key.
const seriesSortFields = {'title': 'metadata.titleSort', 'added': 'createdDate', 'updated': 'lastModifiedDate'};

/// The same for books mode.
const bookSortFields = {'title': 'metadata.title', 'added': 'createdDate', 'release': 'metadata.releaseDate'};

/// A view pinned to Home under a name of your choosing, e.g. "Ultimate Universe · unread" = that read list with
/// read books hidden. Opening it restores exactly that view (list, hide-read, and for libraries mode and sort).
@immutable
class Pin {
  const Pin({required this.name, required this.kind, this.id, required this.title, this.filter = 'all', this.mode,
      this.sort, this.filters = ViewFilter.none});

  final String name;
  final String kind; // library | series | readlist | collection | book
  final String? id; // null = all libraries
  final String title; // the screen's own title (library / series / list name)
  final String filter; // ReadFilter name: all | hideRead | hideUnread
  final String? mode; // libraries: series | books | collections | readLists
  final String? sort; // libraries: sort key
  final ViewFilter filters; // the filter panel's filters (writer, years, ...); none = not filtered

  /// A single book pinned (user, 2026-10-12): on Home its cover; a tap opens the reader. Named, until renamed, after
  /// its series, number and title - "Discworld #13 · Small Gods" (user, 2026-10-18: "it shouldn't just take the
  /// title"); the title left out when it only repeats the rest, the series and number when the book has neither.
  factory Pin.book(dynamic b) {
    final title = '${b['metadata']?['title'] ?? b['name'] ?? ''}';
    final where = bookTitle(b);
    final name = where.isEmpty ? title : title.isEmpty || title == where ? where : '$where · $title';
    return Pin(name: name, kind: 'book', id: b['id'] as String, title: title);
  }

  ReadFilter get readFilter => ReadFilterApi.fromName(filter);

  /// A library pin's sort with its direction always there: "key" alone (no direction saved with it) is the sort's
  /// natural one, as the library screen opens it (code review 2026-10-05, #29: the poster showed it oldest first and
  /// the screen newest first, and pinning the same view again made a second pin).
  String? get fullSort {
    final s = sort;
    if (kind != 'library' || s == null || s.contains(':')) return s;
    return '$s:${naturalDesc(s) ? 'desc' : 'asc'}';
  }

  /// Same view (the name doesn't matter).
  bool sameView(Pin o) =>
      o.kind == kind && o.id == id && o.filter == filter && o.mode == mode && o.fullSort == fullSort &&
      o.filters == filters;

  Pin renamed(String n) =>
      Pin(name: n, kind: kind, id: id, title: title, filter: filter, mode: mode, sort: sort, filters: filters);

  /// The same pin for a list renamed on Komga: its title [to], and its name too where that was the old title [from]
  /// - alone, or before " · " and the view's words ("Civil War · Unread"); a name of your own is kept.
  Pin retitled(String from, String to) => Pin(
      name: name == from ? to : name.startsWith('$from · ') ? to + name.substring(from.length) : name,
      kind: kind, id: id, title: to, filter: filter, mode: mode, sort: sort, filters: filters);

  Map<String, dynamic> toJson() => {
        'name': name, 'kind': kind, 'id': id, 'title': title, 'filter': filter, 'mode': mode, 'sort': sort,
        if (filters.isNotEmpty) 'filters': filters.toJson(),
      };

  factory Pin.fromJson(Map<String, dynamic> j) => Pin(
        name: j['name'] as String? ?? '?',
        kind: j['kind'] as String? ?? 'library',
        id: j['id'] as String?,
        title: j['title'] as String? ?? '',
        filter: j['filter'] as String? ?? 'all',
        mode: j['mode'] as String?,
        sort: j['sort'] as String?,
        filters: ViewFilter.fromJson(j['filters']),
      );
}

/// The pins, kept on the device and in the user's Komga client settings (so another device gets them too).
class Pins extends ChangeNotifier {
  Pins._();
  static final Pins instance = Pins._();

  static const komgaKey = 'komgareader.pins';
  static const _local = 'pins';
  // changed while Komga couldn't be reached: kept on the device, sent when it can be, and it wins at start-up (code
  // review, 2026-09-30: Komga's older list used to replace it at the next start) - as On deck hidden does
  static const _dirtyKey = 'pins.unsent';
  // Pins always sync (user, 2026-10-21: "drop this setting entirely. pins always sync."). The switch's keys, from
  // before - a device's own list and its switch - are cleared at the next load: the shared list is the one.
  static const _oldSyncKey = 'pins.sync', _oldDeviceKey = 'pins.device';

  BookSource? _api;
  List<Pin> items = [];
  String? syncError;
  Timer? _retry;
  bool _sending = false, _sendAgain = false; // one send at a time: the list as it is when it's this one's turn

  /// A failed send will be tried again (tests).
  @visibleForTesting
  bool get retrying => _retry?.isActive ?? false;

  /// A sync problem, in plain words; recorded in the error log when it changes (retries repeat it every minute).
  void _syncNote(String note, Object error) {
    if (note != syncError) ErrorLog.instance.record(note, error);
    syncError = note;
  }

  /// [fetch] false (offline mode): this device's copy only - nothing is sent or asked for.
  Future<void> load(BookSource api, {bool fetch = true}) async {
    _api = api;
    final p = await SharedPreferences.getInstance();
    if (p.containsKey(_oldSyncKey)) await p.remove(_oldSyncKey);
    if (p.containsKey(_oldDeviceKey)) await p.remove(_oldDeviceKey);
    final before = _raw;
    final raw = p.getString(_local);
    if (raw != null) items = _decode(raw);
    _loaded = true;
    if (_raw != before) notifyListeners();
    if (!fetch) return;
    await _fetch(p);
  }

  /// Komga's list: this device's unsent change goes instead (it wins); a list asked for before a change here is
  /// dropped. Never re-reads the device's copy (code review 2026-10-05, #1).
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
      final remote = (await api.clientSettings())[komgaKey]?['value'];
      // pinned / unpinned here meanwhile (that goes to Komga, not the other way)
      if (_changes != changes) return;
      if (remote is String) {
        final before = _raw;
        items = _decode(remote);
        if (_raw != before) { // nothing new: nobody told (Home reloaded three times per reload - #34)
          await p.setString(_local, _raw);
          notifyListeners();
        }
      }
      syncError = null;
    } catch (e) {
      _syncNote('Using the pins saved on this device: ${explain(e).reason}.', e);
    }
  }

  /// Komga's list again - Home calls it each time it reloads, so pins made on another device show up without
  /// restarting the app (user, 2026-10-05: one pinned on the tablet never reached a PC app left open). Changes made
  /// here and not sent yet go first, as at a start.
  /// Several reloads in a row ask once ([RefreshGate]).
  Future<void> refresh() async {
    if (_api == null || !_loaded) return;
    final p = await SharedPreferences.getInstance();
    await _gate.run(() => _fetch(p));
  }

  final _gate = RefreshGate();
  bool _loaded = false; // the device's copy read: until then there's nothing to send (#2 sent an empty list)
  bool _pending = false; // a change here not on Komga yet - known at once, before the flag is saved (#1)

  int _changes = 0; // pins changed on this device: a list from Komga that was asked for before is out of date

  /// Switch connection (online / offline) without reloading; changes waiting to be sent go now.
  void useApi(BookSource api) {
    _api = api;
    if (!_loaded) return; // not read yet: [load] sends what's unsent (start-up sent [] - #2)
    SharedPreferences.getInstance().then((p) { if (p.getBool(_dirtyKey) ?? false) _send(); });
  }

  /// Signed out: the account's pins go from this device (they come back from Komga on signing in again).
  Future<void> clearAccount() async {
    _retry?.cancel();
    _api = null;
    _loaded = false;
    _pending = false;
    items = [];
    syncError = null;
    notifyListeners();
    final p = await SharedPreferences.getInstance();
    await p.remove(_local);
    await p.remove(_dirtyKey);
  }

  Pin? find(Pin view) {
    for (final p in items) {
      if (p.sameView(view)) return p;
    }
    return null;
  }

  void add(Pin pin) => _save([...items.where((p) => !p.sameView(pin)), pin]);
  void remove(Pin pin) => _save(items.where((p) => !p.sameView(pin)).toList());
  void rename(Pin pin, String name) => _save([for (final p in items) p.sameView(pin) ? p.renamed(name) : p]);

  /// A read list (or other [kind]) renamed on Komga from [from] to [to]: its pins follow ([Pin.retitled]).
  void retitle(String kind, String id, String from, String to) {
    if (!items.any((p) => p.kind == kind && p.id == id)) return;
    _save([for (final p in items) p.kind == kind && p.id == id ? p.retitled(from, to) : p]);
  }

  String get _raw => jsonEncode([for (final p in items) p.toJson()]);

  void _save(List<Pin> next) {
    items = next;
    _changes++;
    _pending = true;
    notifyListeners();
    SharedPreferences.getInstance().then((p) async {
      await p.setString(_local, _raw);
      await p.setBool(_dirtyKey, true); // until Komga has it
      await _send();
    });
  }

  /// The list to Komga. Not reachable: flagged (kept for the next start) and tried again in a minute.
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
      final raw = _raw;
      await api.putClientSetting(komgaKey, raw);
      if (!_sendAgain) {
        _pending = false;
        await p.setBool(_dirtyKey, false); // changed meanwhile: still to send
      }
      syncError = null;
    } catch (e) {
      _syncNote('Pins saved on this device, not on Komga yet: ${explain(e).reason}.', e);
      _retry = Timer(const Duration(minutes: 1), _send);
    } finally {
      _sending = false;
    }
    notifyListeners();
    if (_sendAgain) {
      _sendAgain = false;
      await _send();
    }
  }

  static List<Pin> _decode(String raw) {
    try {
      return [for (final j in jsonDecode(raw) as List) Pin.fromJson(Map<String, dynamic>.from(j as Map))];
    } catch (_) {
      return [];
    }
  }
}

/// Pin button for a screen's app bar. Outline = not pinned (tap to pin, with a name); filled = pinned (tap to rename
/// or unpin). [current] describes the screen's view right now.
class PinButton extends StatelessWidget {
  const PinButton({super.key, required this.current});
  final Pin current;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Pins.instance,
      builder: (context, _) {
        final existing = Pins.instance.find(current);
        return IconButton(
          tooltip: existing == null ? 'Pin to Home' : 'Pinned as "${existing.name}"',
          icon: Icon(existing == null ? Icons.push_pin_outlined : Icons.push_pin,
              color: existing == null ? null : Theme.of(context).colorScheme.primary),
          onPressed: () => showPinDialog(context, existing ?? current, pinned: existing != null),
        );
      },
    );
  }
}

/// Name a new pin, or rename / unpin an existing one.
Future<void> showPinDialog(BuildContext context, Pin pin, {required bool pinned}) async {
  final name = TextEditingController(text: pin.name);
  final result = await showDialog<String>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(pinned ? 'Pinned view' : 'Pin to Home'),
      content: TextField(
        controller: name,
        autofocus: true,
        decoration: const InputDecoration(labelText: 'Name on Home'),
        onSubmitted: (_) => Navigator.pop(ctx, 'save'),
      ),
      actions: [
        if (pinned) TextButton(onPressed: () => Navigator.pop(ctx, 'unpin'), child: const Text('Unpin')),
        TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
        FilledButton(onPressed: () => Navigator.pop(ctx, 'save'), child: Text(pinned ? 'Save' : 'Pin')),
      ],
    ),
  );
  final n = name.text.trim();
  if (result == 'unpin') {
    Pins.instance.remove(pin);
  } else if (result == 'save' && n.isNotEmpty) {
    pinned ? Pins.instance.rename(pin, n) : Pins.instance.add(pin.renamed(n));
  }
}
