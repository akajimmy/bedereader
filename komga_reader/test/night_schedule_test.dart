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
}
