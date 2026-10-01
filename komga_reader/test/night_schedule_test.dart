import 'package:flutter/widgets.dart' show AppLifecycleState;
import 'package:flutter_test/flutter_test.dart';
import 'package:komga_reader/night_schedule.dart';
import 'package:komga_reader/settings.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Night mode on a schedule: the window (also across midnight), the next and last changes, and a hand-made change
/// standing until the schedule's next change.
void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));
  tearDown(() {
    NightSchedule.instance.stop();
    AppSettings.instance.setDisplay(const DisplayPrefs());
  });

  DateTime at(int h, int m) => DateTime(2026, 9, 30, h, m);
  const from = 21 * 60, to = 7 * 60; // 21:00 - 07:00, across midnight

  test('the window (across midnight and within a day), and the next and last change', () {
    // one table for the three (they were two tests - test audit, 2026-09-30)
    const afternoon = (13 * 60, 15 * 60);
    for (final (now, (f, t), inside, why) in [
      (at(22, 0), (from, to), true, 'evening'),
      (at(3, 0), (from, to), true, 'after midnight'),
      (at(7, 0), (from, to), false, 'the end time is day again'),
      (at(12, 0), (from, to), false, 'midday'),
      (at(14, 0), afternoon, true, 'an afternoon window'),
      (at(16, 0), afternoon, false, 'after the afternoon window'),
      (at(16, 0), (600, 600), false, 'from = to: never'),
    ]) {
      expect(NightSchedule.inWindow(now, f, t), inside, reason: 'inWindow: $why');
    }
    for (final (now, next, last) in [
      (at(12, 0), at(21, 0), at(7, 0)),
      (at(22, 0), DateTime(2026, 10, 1, 7, 0), at(21, 0)),
      (at(3, 0), at(7, 0), DateTime(2026, 9, 29, 21, 0)),
    ]) {
      expect(NightSchedule.nextChange(now, from, to), next, reason: 'next change after $now');
      expect(NightSchedule.lastChange(now, from, to), last, reason: 'last change before $now');
    }
  });

  testWidgets('switching the schedule on sets night mode for now; a change by hand then stands', (tester) async {
    final s = AppSettings.instance;
    NightSchedule.instance.start();
    final now = DateTime.now();
    final m = now.hour * 60 + now.minute;
    // a window around now, ending in two hours
    s.setDisplay(s.display.copyWith(nightSchedule: true, nightFrom: (m - 60) % 1440, nightTo: (m + 120) % 1440));
    expect(s.display.night, isTrue);
    s.setDisplay(s.display.copyWith(night: false)); // by hand
    NightSchedule.instance.didChangeAppLifecycleState(AppLifecycleState.resumed); // back to the app
    expect(s.display.night, isFalse, reason: 'no change has passed since: the hand-made choice stands');
    NightSchedule.instance.stop(); // its timer to the next change
  });

  // ---- on the clock (NightSchedule.clock: test audit, 2026-09-30 - the boundaries had no test, needing a clock)

  /// The schedule's clock reads [start] now, then moves with the test's fake time (pumps); [jump] moves it on
  /// without running any timer (the app away, Android not running them).
  Duration Function(Duration) clockFrom(WidgetTester tester, DateTime start) {
    final t0 = tester.binding.clock.now();
    var jumped = Duration.zero;
    NightSchedule.clock = () => start.add(tester.binding.clock.now().difference(t0) + jumped);
    addTearDown(() => NightSchedule.clock = DateTime.now);
    return (d) => jumped += d;
  }

  /// Night mode on a schedule from 21:00 to 07:00, switched on with night mode [night] to begin with.
  void schedule({required bool night}) {
    final s = AppSettings.instance;
    s.setDisplay(s.display.copyWith(nightSchedule: true, nightFrom: from, nightTo: to, night: night));
  }

  testWidgets('exactly at the start time it is night, a second before it is not; exactly at the end it is day, a '
      'second before it is night; midnight is night', (tester) async {
    final s = AppSettings.instance;
    for (final (h, m, sec, night) in [
      (20, 59, 59, false),
      (21, 0, 0, true), // the start
      (23, 59, 59, true),
      (0, 0, 0, true), // midnight, inside a window that crosses it
      (6, 59, 59, true),
      (7, 0, 0, false), // the end
    ]) {
      NightSchedule.instance.stop();
      s.setDisplay(const DisplayPrefs());
      clockFrom(tester, DateTime(2026, 9, 30, h, m, sec));
      NightSchedule.instance.start();
      schedule(night: !night); // the other way: the schedule has to change it
      expect(s.display.night, night, reason: 'at $h:$m:$sec');
    }
    NightSchedule.instance.stop();
  });

  testWidgets('left running: the timer switches night mode on at the start time and off at the end, across midnight, '
      'day after day', (tester) async {
    final s = AppSettings.instance;
    clockFrom(tester, DateTime(2026, 9, 30, 20, 59));
    NightSchedule.instance.start();
    schedule(night: false);
    expect(s.display.night, isFalse, reason: '20:59');
    await tester.pump(const Duration(seconds: 59)); // 20:59:59
    expect(s.display.night, isFalse, reason: 'not before the start time');
    await tester.pump(const Duration(seconds: 2)); // 21:00:01 - the timer is set a second past the change
    expect(s.display.night, isTrue, reason: 'on at the start time');
    await tester.pump(const Duration(hours: 9, minutes: 59, seconds: 58)); // 06:59:59, past midnight
    expect(s.display.night, isTrue, reason: 'still on across midnight');
    await tester.pump(const Duration(seconds: 2)); // 07:00:01
    expect(s.display.night, isFalse, reason: 'off at the end time');
    await tester.pump(const Duration(hours: 14)); // 21:00:01 the next day
    expect(s.display.night, isTrue, reason: 'on again the next evening: the timer sets itself again');
    NightSchedule.instance.stop();
  });

  testWidgets('back in the app after a change passed while it was away (no timer ran): set to what the schedule '
      'says, over a change made by hand before', (tester) async {
    final s = AppSettings.instance;
    final jump = clockFrom(tester, DateTime(2026, 9, 30, 20, 0));
    NightSchedule.instance.start();
    schedule(night: false);
    s.setDisplay(s.display.copyWith(night: true)); // on by hand, at 20:00
    jump(const Duration(hours: 11, minutes: 30)); // 07:30 the next morning: 21:00 and 07:00 passed, unseen
    NightSchedule.instance.didChangeAppLifecycleState(AppLifecycleState.resumed);
    expect(s.display.night, isFalse, reason: 'day, as the schedule says: the hand-made choice was before a change');
    NightSchedule.instance.stop();
  });
}
