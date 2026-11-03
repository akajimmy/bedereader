import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// What a key does in the reader, with the controls hidden (Settings > Remote and keys; user, 2026-09-30).
/// [openMenu]: not the reader's - the side menu, on the screens that have one (user, 2026-10-12: a key for it on
/// Windows; no key by default).
/// [autoScroll], [scrollFaster], [scrollSlower]: a webtoon's auto-scroll - on / off and its speed (user, 2026-10-22:
/// "create new empty hotkeys for scroll speed"; no keys by default).
enum ReaderAction { next, previous, controls, close, zoomIn, zoomOut, openMenu, autoScroll, scrollFaster, scrollSlower }

extension ReaderActionLabel on ReaderAction {
  String get label => switch (this) {
        ReaderAction.next => 'Next page',
        ReaderAction.previous => 'Previous page',
        ReaderAction.controls => 'Show the controls',
        ReaderAction.close => 'Close the book',
        ReaderAction.zoomIn => 'Zoom in',
        ReaderAction.zoomOut => 'Zoom out',
        ReaderAction.openMenu => 'Open the side menu',
        ReaderAction.autoScroll => 'Auto-scroll on / off',
        ReaderAction.scrollFaster => 'Auto-scroll faster',
        ReaderAction.scrollSlower => 'Auto-scroll slower',
      };
}

/// The keys that get around the app, on every screen and in the reader (user, 2026-11-03: a controller held sideways,
/// its up and down to be left and right; OK, that opens a book and presses what's selected, too).
enum Nav { up, down, left, right, ok }

extension NavLabel on Nav {
  String get label => switch (this) {
        Nav.up => 'Up',
        Nav.down => 'Down',
        Nav.left => 'Left',
        Nav.right => 'Right',
        Nav.ok => 'OK',
      };
}

/// The reader's keys, kept on this device: which keys turn pages, show the controls, close the book. Written for
/// left-to-right reading - in a right-to-left book Left and Right swap, as before. A key has one job at a time.
/// Not covered (fixed): Shift+Space goes back, and moving around the controls once they're up (arrows and OK), so a
/// mapping can never strand the remote. The volume keys are keys like any other here (mapped to an action or not).
///
/// [moves] come before all that: which keys count as the arrows and OK, everywhere. A key on one reaches the app as
/// that arrow, or Enter ([remap]), so the screens and the reader's own keys need know nothing of it. Each of those
/// five keys is on exactly one [Nav] - its own until it's given to another - so what the rows say is what it does.
/// (Select and Num Enter are OK as well, on no row: a key on none does what it always did.)
class ReaderKeys extends ChangeNotifier {
  ReaderKeys._();
  static final ReaderKeys instance = ReaderKeys._();

  static const _key = 'reader.keys';
  static const _movesKey = 'reader.moves';

  /// What each [Nav] reaches the app as.
  static final navKeys = {
    Nav.up: LogicalKeyboardKey.arrowUp,
    Nav.down: LogicalKeyboardKey.arrowDown,
    Nav.left: LogicalKeyboardKey.arrowLeft,
    Nav.right: LogicalKeyboardKey.arrowRight,
    Nav.ok: LogicalKeyboardKey.enter,
  };

  static Map<Nav, List<LogicalKeyboardKey>> _usualMoves() => {for (final e in navKeys.entries) e.key: [e.value]};

  Map<Nav, List<LogicalKeyboardKey>> moves = _usualMoves();

  static final Map<ReaderAction, List<LogicalKeyboardKey>> defaults = {
    ReaderAction.next: [LogicalKeyboardKey.arrowRight, LogicalKeyboardKey.arrowDown, LogicalKeyboardKey.pageDown,
        LogicalKeyboardKey.space],
    ReaderAction.previous: [LogicalKeyboardKey.arrowLeft, LogicalKeyboardKey.arrowUp, LogicalKeyboardKey.pageUp],
    ReaderAction.controls: [LogicalKeyboardKey.enter, LogicalKeyboardKey.select, LogicalKeyboardKey.numpadEnter],
    ReaderAction.close: [LogicalKeyboardKey.escape],
    // in fit screen: a step in or out (x1.5), like pinching
    ReaderAction.zoomIn: [LogicalKeyboardKey.equal, LogicalKeyboardKey.add, LogicalKeyboardKey.numpadAdd],
    ReaderAction.zoomOut: [LogicalKeyboardKey.minus, LogicalKeyboardKey.numpadSubtract],
    ReaderAction.openMenu: [], // none: given one by hand (Settings > Remote and keys)
    ReaderAction.autoScroll: [], // (webtoons; none, likewise)
    ReaderAction.scrollFaster: [],
    ReaderAction.scrollSlower: [],
  };

  Map<ReaderAction, List<LogicalKeyboardKey>> keys = {for (final e in defaults.entries) e.key: List.of(e.value)};

  bool get isDefault =>
      jsonEncode(_ids(keys)) == jsonEncode(_ids(defaults)) && jsonEncode(_ids(moves)) == jsonEncode(_ids(_usualMoves()));

  static Map<String, List<int>> _ids(Map<Enum, List<LogicalKeyboardKey>> m) =>
      {for (final e in m.entries) e.key.name: [for (final k in e.value) k.keyId]};

  void _loadMoves(String? raw) {
    moves = _usualMoves();
    if (raw == null) return;
    try {
      final m = jsonDecode(raw) as Map<String, dynamic>;
      final saved = {
        for (final a in Nav.values)
          a: [for (final id in m[a.name] as List) LogicalKeyboardKey.findKeyByKeyId(id as int) ?? LogicalKeyboardKey(id)],
      };
      // (each of the five on a row: see the class)
      if (navKeys.values.every((k) => saved.values.where((row) => row.contains(k)).length == 1)) moves = saved;
    } catch (_) {
      // unreadable: the usual keys
    }
  }

  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_key);
    _loadMoves(prefs.getString(_movesKey));
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
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_key, jsonEncode(_ids(keys)));
    await prefs.setString(_movesKey, jsonEncode(_ids(moves)));
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
  ///
  /// An arrow or Enter is taken as what it now is ([moved]): that's what the reader will get from it. Not for the side
  /// menu, whose key is looked for before it's changed (main.dart). Another key on a [Nav] comes off it.
  Future<ReaderAction?> assign(ReaderAction action, LogicalKeyboardKey key) async {
    final isArrow = navKeys.containsValue(key);
    if (isArrow && action != ReaderAction.openMenu) key = moved(key);
    if (cantAssign(action, key) != null) return null;
    ReaderAction? was;
    for (final e in keys.entries) {
      if (e.key != action && e.value.remove(key)) was = e.key;
    }
    if (!isArrow) {
      for (final row in moves.values) {
        row.remove(key);
      }
    }
    if (!keys[action]!.contains(key)) keys[action]!.add(key);
    await _save();
    return was;
  }

  /// The key [key] counts as, or null: it isn't on a [Nav].
  LogicalKeyboardKey? moveFor(LogicalKeyboardKey key) {
    for (final e in moves.entries) {
      if (e.value.contains(key)) return navKeys[e.key];
    }
    return null;
  }

  /// What [key] reaches the app as.
  LogicalKeyboardKey moved(LogicalKeyboardKey key) => moveFor(key) ?? key;

  /// Gives [key] to [move], off whatever it did before: what that was is returned, to say so. Nothing changes if it's
  /// the only key that shows the controls ([cantAssign]). One of the five stays on the reader's lists, where it stands for
  /// its direction whichever key sends it.
  Future<String?> assignMove(Nav move, LogicalKeyboardKey key) async {
    if (cantAssign(ReaderAction.next, key) != null) return null;
    String? was;
    for (final e in moves.entries) {
      if (e.key != move && e.value.remove(key)) was = e.key.label;
    }
    if (!navKeys.containsValue(key)) {
      for (final e in keys.entries) {
        if (e.value.remove(key)) was = e.key.label;
      }
    }
    if (!moves[move]!.contains(key)) moves[move]!.add(key);
    await _save();
    return was;
  }

  /// Whether [key] can come off [move]: one of the five stays on its own.
  bool canRemoveMove(Nav move, LogicalKeyboardKey key) => key != navKeys[move];

  /// [key] off [move]; one of the five goes back to its own.
  Future<void> removeMove(Nav move, LogicalKeyboardKey key) async {
    if (!canRemoveMove(move, key)) return;
    moves[move]!.remove(key);
    for (final e in navKeys.entries) {
      if (e.value == key) moves[e.key]!.add(key);
    }
    await _save();
  }

  /// What each key held down was changed to. A press ends as it began, whatever is set meanwhile, and a press not
  /// changed stays so.
  final _pressed = <PhysicalKeyboardKey, LogicalKeyboardKey>{};

  /// [e] as the app should get it. In a text box ([typing]) only the five change: a letter set to one types.
  KeyEvent remap(KeyEvent e, {bool typing = false}) {
    final physical = e.physicalKey;
    switch (e) {
      case KeyDownEvent():
        final to = moved(e.logicalKey);
        if (to == e.logicalKey || (typing && !navKeys.containsValue(e.logicalKey))) return e;
        _pressed[physical] = to;
        return KeyDownEvent(physicalKey: physical, logicalKey: to, timeStamp: e.timeStamp, deviceType: e.deviceType,
            synthesized: e.synthesized);
      case KeyRepeatEvent():
        final to = _pressed[physical];
        if (to == null) return e;
        return KeyRepeatEvent(physicalKey: physical, logicalKey: to, timeStamp: e.timeStamp, deviceType: e.deviceType);
      case KeyUpEvent():
        final to = _pressed.remove(physical);
        if (to == null) return e;
        return KeyUpEvent(physicalKey: physical, logicalKey: to, timeStamp: e.timeStamp, deviceType: e.deviceType,
            synthesized: e.synthesized);
      default:
        return e;
    }
  }

  /// Sends every key through [remap] on its way to the focus - all the screens, the reader, the sliders. What listens
  /// to the keyboard itself gets the key as pressed: asking for a key in Remote and keys, Test the remote.
  /// (keyMessageHandler is deprecated, with nothing in its place for changing what the focus gets. If Flutter drops it
  /// this stops compiling; PlatformDispatcher.onKeyData is the way left then, and asking for a key would have to turn
  /// [remap] off.)
  void remapKeysToFocus() {
    // ignore: deprecated_member_use
    final manager = ServicesBinding.instance.keyEventManager;
    // ignore: deprecated_member_use
    final next = _beforeRemap = manager.keyMessageHandler!;
    // ignore: deprecated_member_use
    manager.keyMessageHandler = (m) {
      final typing = FocusManager.instance.primaryFocus?.context?.findAncestorStateOfType<EditableTextState>() != null;
      // ignore: deprecated_member_use
      return next(KeyMessage([for (final e in m.events) remap(e, typing: typing)], m.rawEvent));
    };
  }

  // ignore: deprecated_member_use
  KeyMessageHandler? _beforeRemap;

  /// Undoes [remapKeysToFocus] (tests: so it doesn't stay on for the next).
  @visibleForTesting
  void stopRemappingKeys() {
    // ignore: deprecated_member_use
    ServicesBinding.instance.keyEventManager.keyMessageHandler = _beforeRemap;
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
    moves = _usualMoves();
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_key);
    await prefs.remove(_movesKey);
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
