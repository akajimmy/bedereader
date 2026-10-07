import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// What a key does in the reader, with the controls hidden (Settings > Remote and keys; user, 2026-09-30).
enum ReaderAction { next, previous, controls, close, zoomIn, zoomOut }

extension ReaderActionLabel on ReaderAction {
  String get label => switch (this) {
        ReaderAction.next => 'Next page',
        ReaderAction.previous => 'Previous page',
        ReaderAction.controls => 'Show the controls',
        ReaderAction.close => 'Close the book',
        ReaderAction.zoomIn => 'Zoom in',
        ReaderAction.zoomOut => 'Zoom out',
      };
}

/// The reader's keys, kept on this device: which keys turn pages, show the controls, close the book. Written for
/// left-to-right reading - in a right-to-left book Left and Right swap, as before. A key has one job at a time.
/// Not covered (fixed): Shift+Space goes back, the volume keys (their own setting), and moving around the controls
/// once they're up (arrows and OK), so a mapping can never strand the remote.
class ReaderKeys extends ChangeNotifier {
  ReaderKeys._();
  static final ReaderKeys instance = ReaderKeys._();

  static const _key = 'reader.keys';

  static final Map<ReaderAction, List<LogicalKeyboardKey>> defaults = {
    ReaderAction.next: [LogicalKeyboardKey.arrowRight, LogicalKeyboardKey.arrowDown, LogicalKeyboardKey.pageDown,
        LogicalKeyboardKey.space],
    ReaderAction.previous: [LogicalKeyboardKey.arrowLeft, LogicalKeyboardKey.arrowUp, LogicalKeyboardKey.pageUp],
    ReaderAction.controls: [LogicalKeyboardKey.enter, LogicalKeyboardKey.select, LogicalKeyboardKey.numpadEnter],
    ReaderAction.close: [LogicalKeyboardKey.escape],
    // in fit screen: a step in or out (x1.5), like pinching
    ReaderAction.zoomIn: [LogicalKeyboardKey.equal, LogicalKeyboardKey.add, LogicalKeyboardKey.numpadAdd],
    ReaderAction.zoomOut: [LogicalKeyboardKey.minus, LogicalKeyboardKey.numpadSubtract],
  };

  Map<ReaderAction, List<LogicalKeyboardKey>> keys = {for (final e in defaults.entries) e.key: List.of(e.value)};

  bool get isDefault => jsonEncode(_ids(keys)) == jsonEncode(_ids(defaults));

  static Map<String, List<int>> _ids(Map<ReaderAction, List<LogicalKeyboardKey>> m) =>
      {for (final e in m.entries) e.key.name: [for (final k in e.value) k.keyId]};

  Future<void> load() async {
    final raw = (await SharedPreferences.getInstance()).getString(_key);
    keys = {for (final e in defaults.entries) e.key: List.of(e.value)};
    if (raw != null) {
      try {
        final m = jsonDecode(raw) as Map<String, dynamic>;
        for (final a in ReaderAction.values) {
          final ids = m[a.name];
          if (ids is List) keys[a] = [for (final id in ids) LogicalKeyboardKey.findKeyByKeyId(id as int) ?? LogicalKeyboardKey(id)];
        }
      } catch (_) {
        // unreadable: the defaults
      }
    }
    // Show the controls always has a key - saves from before that rule could have none, leaving the remote no way to
    // the controls (missing-tests audit, 2026-09-30). Its default keys come back, taken off whatever else had them.
    if (keys[ReaderAction.controls]!.isEmpty) {
      final back = defaults[ReaderAction.controls]!;
      for (final a in ReaderAction.values) {
        keys[a]!.removeWhere(back.contains);
      }
      keys[ReaderAction.controls] = List.of(back);
    }
    notifyListeners();
  }

  Future<void> _save() async {
    notifyListeners();
    await (await SharedPreferences.getInstance()).setString(_key, jsonEncode(_ids(keys)));
  }

  /// What [key] does, in a book read left to right or right to left (Left and Right swap). Null: nothing.
  ReaderAction? actionFor(LogicalKeyboardKey key, {bool rtl = false}) {
    var k = key;
    if (rtl && k == LogicalKeyboardKey.arrowLeft) {
      k = LogicalKeyboardKey.arrowRight;
    } else if (rtl && k == LogicalKeyboardKey.arrowRight) {
      k = LogicalKeyboardKey.arrowLeft;
    }
    for (final e in keys.entries) {
      if (e.value.contains(k)) return e.key;
    }
    return null;
  }

  /// Why [key] can't go to [action], or null if it can: it's the only key that shows the controls (taking it would
  /// leave no remote key to bring them up - code review, 2026-09-30).
  String? cantAssign(ReaderAction action, LogicalKeyboardKey key) {
    final controls = keys[ReaderAction.controls]!;
    if (action == ReaderAction.controls || controls.length != 1 || controls.single != key) return null;
    return '${nameOf(key)} is the only key that shows the controls - give "${ReaderAction.controls.label}" another '
        'key first.';
  }

  /// Gives [key] to [action] - taken off whatever it did before, which is returned (to say so). Nothing changes if
  /// [cantAssign] says no.
  Future<ReaderAction?> assign(ReaderAction action, LogicalKeyboardKey key) async {
    if (cantAssign(action, key) != null) return null;
    ReaderAction? was;
    for (final e in keys.entries) {
      if (e.key != action && e.value.remove(key)) was = e.key;
    }
    if (!keys[action]!.contains(key)) keys[action]!.add(key);
    await _save();
    return was;
  }

  /// Whether [key] can be taken off [action]: Show the controls always keeps one key.
  bool canRemove(ReaderAction action) => action != ReaderAction.controls || keys[action]!.length > 1;

  Future<void> remove(ReaderAction action, LogicalKeyboardKey key) async {
    if (!canRemove(action)) return;
    keys[action]!.remove(key);
    await _save();
  }

  Future<void> reset() async {
    keys = {for (final e in defaults.entries) e.key: List.of(e.value)};
    notifyListeners();
    await (await SharedPreferences.getInstance()).remove(_key);
  }

  /// A key's name as people know it.
  static final _names = {
    LogicalKeyboardKey.arrowRight: '→', LogicalKeyboardKey.arrowLeft: '←', LogicalKeyboardKey.arrowUp: '↑',
    LogicalKeyboardKey.arrowDown: '↓', LogicalKeyboardKey.pageDown: 'PgDn', LogicalKeyboardKey.pageUp: 'PgUp',
    LogicalKeyboardKey.space: 'Space', LogicalKeyboardKey.enter: 'Enter', LogicalKeyboardKey.escape: 'Esc',
    LogicalKeyboardKey.select: 'Select', LogicalKeyboardKey.numpadEnter: 'Num Enter',
    LogicalKeyboardKey.audioVolumeDown: 'Volume down', LogicalKeyboardKey.audioVolumeUp: 'Volume up',
    LogicalKeyboardKey.mediaTrackNext: 'Next track', LogicalKeyboardKey.mediaTrackPrevious: 'Previous track',
    LogicalKeyboardKey.mediaPlayPause: 'Play/Pause', LogicalKeyboardKey.numpadAdd: 'Num +',
    LogicalKeyboardKey.numpadSubtract: 'Num -',
  };

  static String nameOf(LogicalKeyboardKey k) {
    final n = _names[k];
    if (n != null) return n;
    final label = k.keyLabel;
    if (label.trim().isNotEmpty) return label.length == 1 ? label.toUpperCase() : label;
    return k.debugName ?? 'Key ${k.keyId}';
  }
}
