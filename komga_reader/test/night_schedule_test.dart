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

  test('the window, across midnight and within a day', () {
    expect(NightSchedule.inWindow(at(22, 0), from, to), isTrue);
    expect(NightSchedule.inWindow(at(3, 0), from, to), isTrue);
    expect(NightSchedule.inWindow(at(7, 0), from, to), isFalse); // the end time is day again
    expect(NightSchedule.inWindow(at(12, 0), from, to), isFalse);
    expect(NightSchedule.inWindow(at(14, 0), 13 * 60, 15 * 60), isTrue); // an afternoon window
    expect(NightSchedule.inWindow(at(16, 0), 13 * 60, 15 * 60), isFalse);
    expect(NightSchedule.inWindow(at(16, 0), 600, 600), isFalse); // from = to: never
  });

  test('next and last change', () {
    expect(NightSchedule.nextChange(at(12, 0), from, to), at(21, 0));
    expect(NightSchedule.nextChange(at(22, 0), from, to), DateTime(2026, 10, 1, 7, 0));
    expect(NightSchedule.lastChange(at(12, 0), from, to), at(7, 0));
    expect(NightSchedule.lastChange(at(3, 0), from, to), DateTime(2026, 9, 29, 21, 0));
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

  test('the schedule, text size and accent survive the saved form; older saves get the defaults', () {
    const d = DisplayPrefs(nightSchedule: true, nightFrom: 1320, nightTo: 360, textScale: 1.15, accent: Accent.teal);
    final back = DisplayPrefs.fromJson(d.toJson());
    expect([back.nightSchedule, back.nightFrom, back.nightTo, back.textScale, back.accent],
        [true, 1320, 360, 1.15, Accent.teal]);
    final old = DisplayPrefs.fromJson({'night': true});
    expect([old.nightSchedule, old.nightFrom, old.nightTo, old.textScale, old.accent],
        [false, 21 * 60, 7 * 60, 1.0, Accent.blue]);
    expect(DisplayPrefs.fromJson({'textScale': 3.0}).textScale, 1.0); // not a choice: the default
  });
}
