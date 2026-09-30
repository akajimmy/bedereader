import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:komga_reader/api.dart';
import 'package:komga_reader/ondeck_hidden.dart';
import 'package:komga_reader/pins.dart';
import 'package:komga_reader/settings.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Komga's client settings: what's written there, whether it can be reached, and (optionally) a write held in flight.
class FakeKomga extends Komga {
  FakeKomga([Map<String, String>? start]) : super('http://test', 'k') {
    if (start != null) written.addAll(start);
  }
  final written = <String, String>{};
  bool down = false;
  Completer<void>? holdPut; // a write on its way, until completed
  int puts = 0;
  @override
  Future<Map<String, dynamic>> clientSettings() async {
    if (down) throw KomgaUnreachable(baseUrl);
    return {for (final e in written.entries) e.key: {'value': e.value}};
  }

  @override
  Future<void> putClientSetting(String key, String value) async {
    if (down) throw KomgaUnreachable(baseUrl);
    puts++;
    await holdPut?.future;
    written[key] = value;
  }

  FitMode? fitOn(String seriesId) {
    final raw = written[AppSettings.komgaKey];
    if (raw == null) return null;
    final s = (jsonDecode(raw) as Map)['series'] as Map;
    final j = s[seriesId];
    return j == null ? null : ReaderPrefs.fromJson(Map<String, dynamic>.from(j as Map)).fit;
  }
}

String blob(Map<String, FitMode> series) => jsonEncode({
      'v': 1,
      'default': const ReaderPrefs().toJson(),
      'series': {for (final e in series.entries) e.key: ReaderPrefs(fit: e.value).toJson()},
    });

/// Reader settings synced through Komga (code review, 2026-09-30): changes that haven't reached Komga survive a
/// restart and win; Komga's copy is otherwise the truth (removals included); a change made while a send is on its way
/// isn't lost; signing out leaves nothing of the account behind.
void main() {
  final s = AppSettings.instance;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await s.clearAccount();
    await Pins.instance.clearAccount();
    await OnDeckHidden.instance.clearAccount();
  });

  testWidgets('a change made while Komga was down survives a restart and is sent then - not replaced by Komga\'s '
      'older copy', (tester) async {
    final api = FakeKomga({AppSettings.komgaKey: blob({'S1': FitMode.screen})});
    await s.load(api);
    expect(s.series['S1']!.fit, FitMode.screen);
    api.down = true;
    s.setSeries('S1', const ReaderPrefs(fit: FitMode.width));
    await tester.pump(const Duration(seconds: 3)); // the send fails
    expect(api.fitOn('S1'), FitMode.screen);

    api.down = false;
    await s.load(api); // "the next start" (the unsent list comes from the device, not memory)
    expect(s.series['S1']!.fit, FitMode.width, reason: "this device's unsent change wins");
    await tester.pump(const Duration(seconds: 3));
    expect(api.fitOn('S1'), FitMode.width, reason: 'and reaches Komga');
    await tester.pump(const Duration(minutes: 2));
  });

  testWidgets("series settings removed on another device go here too; Komga's copy is the truth", (tester) async {
    final api = FakeKomga({AppSettings.komgaKey: blob({'S1': FitMode.width, 'S2': FitMode.height})});
    await s.load(api);
    expect(s.series.keys, unorderedEquals(['S1', 'S2']));
    api.written[AppSettings.komgaKey] = blob({'S1': FitMode.width}); // the PC: S2 back to the defaults
    await s.load(api); // this device, next start
    expect(s.series.keys, ['S1'], reason: 'S2 went on the other device');
  });

  testWidgets("a change made while a send is on its way still reaches Komga (it was marked sent)", (tester) async {
    final api = FakeKomga();
    await s.load(api);
    api.holdPut = Completer<void>();
    s.setSeries('S1', const ReaderPrefs(fit: FitMode.width));
    await tester.pump(const Duration(seconds: 3)); // the send starts, and waits
    expect(api.puts, 1);
    s.setSeries('S1', const ReaderPrefs(fit: FitMode.height)); // changed again meanwhile
    await tester.pump(const Duration(seconds: 3));
    api.holdPut!.complete();
    api.holdPut = null;
    await tester.pump();
    await tester.pump(const Duration(seconds: 3)); // the change made meanwhile goes next
    expect(api.fitOn('S1'), FitMode.height);
    await tester.pump(const Duration(minutes: 2));
  });

  testWidgets('signing out leaves nothing of the account: the next account starts clean and nothing is sent to it',
      (tester) async {
    final a = FakeKomga({AppSettings.komgaKey: blob({'S1': FitMode.width})});
    await s.load(a);
    await Pins.instance.load(a);
    Pins.instance.add(const Pin(name: 'P', kind: 'series', id: 'S1', title: 'S'));
    OnDeckHidden.instance.setSeries('S9', true);
    await tester.pump(const Duration(seconds: 1));

    await s.clearAccount(); // what signing out does (main.dart)
    await Pins.instance.clearAccount();
    await OnDeckHidden.instance.clearAccount();

    final b = FakeKomga(); // another account, nothing saved there yet
    await s.load(b);
    await Pins.instance.load(b);
    await OnDeckHidden.instance.load(b);
    await tester.pump(const Duration(seconds: 3));
    expect(s.series, isEmpty);
    expect(Pins.instance.items, isEmpty);
    expect(OnDeckHidden.instance.isEmpty, isTrue);
    expect(b.written, isEmpty, reason: "nothing of account A's was sent to B");
  });
}
