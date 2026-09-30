import 'dart:async';

import 'package:flutter/widgets.dart';

import 'settings.dart';

/// Night mode on a schedule (Settings > Display > On a schedule): switched on at the start time and off at the end
/// time. In between it can still be flipped by hand; the schedule acts again at its next change. When the app starts
/// it's set to what the schedule says; coming back to the front, only if a change was passed while the app was away
/// (Android doesn't run timers in the background) - a hand-made change since the last one stands.
class NightSchedule with WidgetsBindingObserver {
  NightSchedule._();
  static final NightSchedule instance = NightSchedule._();

  Timer? _timer;
  bool _started = false;
  String? _for; // the schedule the timer was set for (on/from/to), so other settings changes leave it alone

  /// Whether [now] falls in the night window [from]..[to] (minutes after midnight; the window may cross midnight).
  static bool inWindow(DateTime now, int from, int to) {
    final m = now.hour * 60 + now.minute;
    if (from == to) return false;
    return from < to ? (m >= from && m < to) : (m >= from || m < to);
  }

  static List<DateTime> _changes(DateTime now, int from, int to) {
    DateTime at(int minutes, int dayOffset) =>
        DateTime(now.year, now.month, now.day + dayOffset, minutes ~/ 60, minutes % 60);
    return [for (final d in const [-1, 0, 1]) ...[at(from, d), at(to, d)]]..sort();
  }

  /// The next time the schedule changes after [now].
  static DateTime nextChange(DateTime now, int from, int to) =>
      _changes(now, from, to).firstWhere((t) => t.isAfter(now));

  /// The last time the schedule changed, at or before [now].
  static DateTime lastChange(DateTime now, int from, int to) =>
      _changes(now, from, to).lastWhere((t) => !t.isAfter(now));

  DateTime? _actedOn; // the schedule change last acted on: a hand-made change after it stands until the next one

  /// Wired up once the settings are loaded; follows every settings change.
  void start() {
    if (_started) return;
    _started = true;
    WidgetsBinding.instance.addObserver(this);
    AppSettings.instance.addListener(_onSettings);
    _apply();
  }

  void _onSettings() {
    final d = AppSettings.instance.display;
    final key = '${d.nightSchedule}/${d.nightFrom}/${d.nightTo}';
    if (key == _for) return;
    _actedOn = null; // the schedule itself changed: night mode as it says for now, then its next change
    _apply();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _apply();
  }

  void _apply() {
    _timer?.cancel();
    final s = AppSettings.instance, d = s.display;
    _for = '${d.nightSchedule}/${d.nightFrom}/${d.nightTo}';
    if (!d.nightSchedule || d.nightFrom == d.nightTo) return;
    final now = DateTime.now();
    final last = lastChange(now, d.nightFrom, d.nightTo);
    // first time, or a change has passed since the last one acted on (at a timer, or while the app was away)
    if (_actedOn == null || last.isAfter(_actedOn!)) {
      _actedOn = last;
      final night = inWindow(now, d.nightFrom, d.nightTo);
      if (d.night != night) s.setDisplay(d.copyWith(night: night));
    }
    _timer = Timer(nextChange(now, d.nightFrom, d.nightTo).difference(now) + const Duration(seconds: 1), _apply);
  }

  @visibleForTesting
  void stop() {
    _timer?.cancel();
    _actedOn = null;
    _for = null;
    if (_started) {
      WidgetsBinding.instance.removeObserver(this);
      AppSettings.instance.removeListener(_onSettings);
    }
    _started = false;
  }
}
