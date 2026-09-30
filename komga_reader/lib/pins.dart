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

  Komga? _api;
  List<Pin> items = [];
  String? syncError;

  /// A sync problem, in plain words; recorded in the error log when it changes (retries repeat it every minute).
  void _syncNote(String note, Object error) {
    if (note != syncError) ErrorLog.instance.record(note, error);
    syncError = note;
  }

  Future<void> load(Komga api) async {
    _api = api;
    final p = await SharedPreferences.getInstance();
    final raw = p.getString(_local);
    if (raw != null) items = _decode(raw);
    notifyListeners();
    try {
      final remote = (await api.clientSettings())[komgaKey]?['value'];
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

  /// Switch connection (online / offline) without reloading.
  void useApi(Komga api) => _api = api;

  Pin? find(Pin view) {
    for (final p in items) {
      if (p.sameView(view)) return p;
    }
    return null;
  }

  void add(Pin pin) => _save([...items.where((p) => !p.sameView(pin)), pin]);
  void remove(Pin pin) => _save(items.where((p) => !p.sameView(pin)).toList());
  void rename(Pin pin, String name) => _save([for (final p in items) p.sameView(pin) ? p.renamed(name) : p]);

  void _save(List<Pin> next) {
    items = next;
    notifyListeners();
    final raw = jsonEncode([for (final p in items) p.toJson()]);
    SharedPreferences.getInstance().then((p) => p.setString(_local, raw));
    final api = _api;
    if (api == null) return;
    api.putClientSetting(komgaKey, raw).then((_) {
      syncError = null;
    }).catchError((Object e) {
      _syncNote('Pins saved on this device, not on Komga yet: ${explain(e).reason}.', e);
    }).whenComplete(notifyListeners);
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
