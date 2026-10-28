// A local library's series and books in what's synced through Komga (the review of 1.6, 2026-10-26): their reader
// settings, and On deck hidden, are this device's own - as the local pins are: never sent to Komga, kept when Komga's
// copy comes, kept through signing out.
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:komga_reader/ondeck_hidden.dart';
import 'package:komga_reader/refresh_gate.dart';
import 'package:komga_reader/settings.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/client_settings.dart';
import 'support/no_network.dart';

const _localSeries = 'ls0123456789abc', _localBook = 'lb0123456789abc';

void main() {
  final s = AppSettings.instance, h = OnDeckHidden.instance;
  setUp(() async {
    RefreshGate.gap = Duration.zero; // (each refresh asks)
    SharedPreferences.setMockInitialValues({});
    await s.clearAccount();
    s.resetAllSeries();
    h.reset();
  });
  tearDown(() async {
    RefreshGate.gap = const Duration(seconds: 10);
    s.resetAllSeries(); // (signing out keeps them: gone here, for the next test)
    h.reset();
  });

  testWidgets("a local series' own reader settings: never sent; kept when Komga's copy comes and through signing out",
      (tester) async {
    final api = noNetwork(() => SettingsServer());
    await s.load(api);
    s.setSeries('S1', const ReaderPrefs(fit: FitMode.width));
    s.setSeries(_localSeries, const ReaderPrefs(fit: FitMode.height));
    await tester.pump(const Duration(seconds: 3)); // sent
    final sent = (jsonDecode(api.written[AppSettings.komgaKey]!) as Map)['series'] as Map;
    expect(sent.keys, ['S1']);

    await s.refresh(); // Komga's copy again
    expect(s.series[_localSeries]?.fit, FitMode.height, reason: "Komga's copy hasn't it: kept");

    await s.clearAccount();
    expect(s.series.keys, [_localSeries]);
    await s.load(noNetwork(() => SettingsServer()), fetch: false); // the next start, another account
    expect(s.series[_localSeries]?.fit, FitMode.height);
    await tester.pump(const Duration(minutes: 2));
  });

  test("a local book or series hidden from On deck: never sent; kept when Komga's list comes and through signing out",
      () async {
    final api = noNetwork(() => SettingsServer());
    await h.load(api);
    h.setSeries('S1', true);
    h.setBook(_localBook, true);
    h.setSeries(_localSeries, true);
    await pumpEventQueue();
    final sent = jsonDecode(api.written[OnDeckHidden.komgaKey]!) as Map;
    expect([...sent['series'] as List, ...sent['books'] as List], ['S1']);

    api.written[OnDeckHidden.komgaKey] = jsonEncode({'series': ['S2'], 'books': []}); // from another device
    await h.refresh();
    expect(h.series, {'S2', _localSeries});
    expect(h.bookHidden(_localBook), isTrue);

    await h.clearAccount();
    expect(h.series, {_localSeries});
    expect(h.books, {_localBook});
    h.reset();
    await h.load(noNetwork(() => SettingsServer()), fetch: false); // the next start
    expect(h.bookHidden(_localBook), isTrue);
  });
}
