import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'api.dart';
import 'errors.dart';

/// A view pinned to Home under a name of your choosing, e.g. "Ultimate Universe · unread" = that read list with
/// read books hidden. Opening it restores exactly that view (list, hide-read, and for libraries mode and sort).
@immutable
class Pin {
  const Pin({required this.name, required this.kind, this.id, required this.title, this.filter = 'all', this.mode,
      this.sort});

  final String name;
  final String kind; // library | series | readlist | collection
  final String? id; // null = all libraries
  final String title; // the screen's own title (library / series / list name)
  final String filter; // ReadFilter name: all | hideRead
  final String? mode; // libraries: series | books | collections | readLists
  final String? sort; // libraries: sort key

  ReadFilter get readFilter => ReadFilterApi.fromName(filter);

  /// Same view (the name doesn't matter).
  bool sameView(Pin o) => o.kind == kind && o.id == id && o.filter == filter && o.mode == mode && o.sort == sort;

  Pin renamed(String n) => Pin(name: n, kind: kind, id: id, title: title, filter: filter, mode: mode, sort: sort);

  Map<String, dynamic> toJson() =>
      {'name': name, 'kind': kind, 'id': id, 'title': title, 'filter': filter, 'mode': mode, 'sort': sort};

  factory Pin.fromJson(Map<String, dynamic> j) => Pin(
        name: j['name'] as String? ?? '?',
        kind: j['kind'] as String? ?? 'library',
        id: j['id'] as String?,
        title: j['title'] as String? ?? '',
        filter: j['filter'] as String? ?? 'all',
        mode: j['mode'] as String?,
        sort: j['sort'] as String?,
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

  Komga? _api;
  List<Pin> items = [];
  String? syncError;
  Timer? _retry;
  bool _sending = false, _sendAgain = false; // one send at a time: the list as it is when it's this one's turn

  /// A sync problem, in plain words; recorded in the error log when it changes (retries repeat it every minute).
  void _syncNote(String note, Object error) {
    if (note != syncError) ErrorLog.instance.record(note, error);
    syncError = note;
  }

  /// [fetch] false (offline mode): this device's copy only - nothing is sent or asked for.
  Future<void> load(Komga api, {bool fetch = true}) async {
    _api = api;
    final p = await SharedPreferences.getInstance();
    final raw = p.getString(_local);
    if (raw != null) items = _decode(raw);
    notifyListeners();
    if (!fetch) return;
    if (p.getBool(_dirtyKey) ?? false) {
      await _send(); // this device's changes haven't reached Komga: they win
      return;
    }
    try {
      final changes = _changes;
      _fetchedAt = DateTime.now();
      final remote = (await api.clientSettings())[komgaKey]?['value'];
      if (_changes != changes) return; // pinned / unpinned here meanwhile: that goes to Komga, not the other way
      if (remote is String) {
        items = _decode(remote);
        await p.setString(_local, remote);
        notifyListeners();
      }
      syncError = null;
    } catch (e) {
      _syncNote('Using the pins saved on this device: ${explain(e).reason}.', e);
    }
  }

  /// Komga's list again - Home calls it each time it reloads, so pins made on another device show up without
  /// restarting the app (user, 2026-10-05: one pinned on the tablet never reached a PC app left open). Changes made
  /// here and not sent yet go first, as at a start.
  /// Several reloads in a row (going online rebuilds Home, and Home reloads as it comes back) ask once: one fetch at a
  /// time, and none within [refreshGap] of the last.
  Future<void> refresh() {
    final api = _api;
    if (api == null) return Future.value();
    final running = _refreshing;
    if (running != null) return running;
    final at = _fetchedAt;
    if (at != null && DateTime.now().difference(at) < refreshGap) return Future.value();
    return _refreshing = load(api).whenComplete(() => _refreshing = null);
  }

  @visibleForTesting
  static Duration refreshGap = const Duration(seconds: 10);
  DateTime? _fetchedAt; // the last time Komga was asked
  Future<void>? _refreshing;

  int _changes = 0; // pins changed on this device: a list from Komga that was asked for before is out of date

  /// Switch connection (online / offline) without reloading; changes waiting to be sent go now.
  void useApi(Komga api) {
    _api = api;
    SharedPreferences.getInstance().then((p) { if (p.getBool(_dirtyKey) ?? false) _send(); });
  }

  /// Signed out: the account's pins go from this device (they come back from Komga on signing in again).
  Future<void> clearAccount() async {
    _retry?.cancel();
    _api = null;
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

  String get _raw => jsonEncode([for (final p in items) p.toJson()]);

  void _save(List<Pin> next) {
    items = next;
    _changes++;
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
      await api.putClientSetting(komgaKey, _raw);
      if (!_sendAgain) await p.setBool(_dirtyKey, false); // changed meanwhile: still to send
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
