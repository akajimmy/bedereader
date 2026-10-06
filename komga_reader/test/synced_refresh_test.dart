// Synced lists and settings refreshed from Komga while the app runs (code review 2026-10-05: #1, #2, #3, #6, #12,
// #34). Each test failed on the code before the fix.
import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:komga_reader/ondeck_hidden.dart';
import 'package:komga_reader/pins.dart';
import 'package:komga_reader/refresh_gate.dart';
import 'package:komga_reader/screens/home.dart';
import 'package:komga_reader/settings.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'ondeck_hidden_test.dart' show DeckKomga;
import 'support/client_settings.dart';
import 'support/no_network.dart';

/// [DeckKomga] counting how often Home asks for On deck - one per Home load.
class CountingDeck extends DeckKomga {
  int onDecks = 0;
  @override
  Future<Map<String, dynamic>> onDeck({String? libraryId, int size = 30}) {
    onDecks++;
    return super.onDeck(libraryId: libraryId, size: size);
  }
}

Future<void> settle() => Future<void>.delayed(const Duration(milliseconds: 20));

void main() {
  final h = OnDeckHidden.instance;
  final pins = Pins.instance;
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    h.reset();
    RefreshGate.gap = Duration.zero; // every refresh asks
  });
  tearDown(() async {
    RefreshGate.gap = const Duration(seconds: 10);
    await pins.clearAccount();
  });

  test('#1: a hide made while Home is open stays hidden - Home refreshing at that moment put back the list from '
      'before it (it re-read the device copy before the hide was saved there)', () async {
    final api = noNetwork(DeckKomga.new)..written[OnDeckHidden.komgaKey] = '{"series":[],"books":[]}';
    await h.load(api);
    void home() => h.refresh(); // what Home does when it hears of the change
    h.addListener(home);
    h.setSeries('S1', true);
    await settle();
    await settle();
    h.removeListener(home);
    expect(h.seriesHidden('S1'), isTrue, reason: 'still hidden here');
    expect(api.written[OnDeckHidden.komgaKey], contains('S1'), reason: 'and on Komga');
  });

  test('#2: at start-up, a change not sent last time goes as it was saved - going online before the device copy was '
      'read sent an empty list to Komga', () async {
    SharedPreferences.setMockInitialValues({
      'ondeck.hidden': '{"series":["S1"],"books":[]}', 'ondeck.hidden.unsent': true,
      'pins': '[{"name":"Mine","kind":"library","title":"Comics"}]', 'pins.unsent': true,
    });
    final api = noNetwork(DeckKomga.new);
    h.useApi(api); // the connection comes up first (main.dart)
    pins.useApi(api);
    await settle();
    expect(api.written[OnDeckHidden.komgaKey], isNull, reason: 'nothing sent before the list is read');
    expect(api.written[Pins.komgaKey], isNull);
    await h.load(api);
    await pins.load(api);
    await settle();
    expect(api.written[OnDeckHidden.komgaKey], contains('S1'));
    expect(api.written[Pins.komgaKey], contains('Mine'));
  });

  test('#3: a change made while an earlier one is still on its way reaches Komga - a quick failure and a slow '
      'success cleared the "unsent" mark with the later change never sent', () async {
    final api = noNetwork(DeckKomga.new)..written[OnDeckHidden.komgaKey] = '{"series":[],"books":[]}';
    await h.load(api);
    api.holdPut = Completer<void>();
    h.setSeries('S1', true); // on its way, slowly
    await settle();
    api.down = true;
    h.setSeries('S2', true); // Komga refuses this one at once
    await settle();
    api.down = false;
    api.holdPut!.complete();
    api.holdPut = null;
    await settle();
    await settle();
    expect(api.written[OnDeckHidden.komgaKey], allOf(contains('S1'), contains('S2')));
  });

  test('#6: pins - turning sync off while a send is failing stops the retries (a minute later the device-only '
      'list went over the shared pins)', () async {
    final api = noNetwork(SettingsServer.new);
    await pins.load(api);
    api.holdPut = Completer<void>();
    pins.add(const Pin(name: 'Shared', kind: 'library', title: 'Comics'));
    await settle();
    await pins.setSync(false); // while the send is on its way
    api.holdPut!.completeError(StateError('Komga refused'));
    api.holdPut = null;
    await settle();
    expect(pins.retrying, isFalse, reason: 'no try in a minute: the list is this device\'s now');
    await pins.setSync(true);
  });

  test("#12: reader settings - a change made while Komga's copy was on its way stays (the refresh brought back the "
      'older value)', () async {
    final s = AppSettings.instance;
    final api = noNetwork(SettingsServer.new);
    await s.load(api);
    // Komga's copy: the default size
    api.written[AppSettings.komgaKey] = jsonEncode({'v': 1, 'default': const ReaderPrefs().toJson(),
        'epub': const EpubPrefs().toJson(), 'series': {}});
    api.holdPut = Completer<void>(); // the change's own send waits
    s.setEpub(s.epub.copyWith(size: 24)); // changed here...
    await s.refresh(); // ...and Home refreshes at once (it used to re-read the device copy, not saved yet)
    expect(s.epub.size, 24, reason: "this device's change, not Komga's older copy");
    api.holdPut!.complete();
    api.holdPut = null;
    await s.clearAccount();
  });

  testWidgets('#34: one Home load per reload - the refreshes told everyone twice even when nothing had changed, '
      'and Home loaded three times', (tester) async {
    final api = noNetwork(CountingDeck.new)..written[OnDeckHidden.komgaKey] = '{"series":[],"books":[]}';
    await tester.runAsync(() => h.load(api));
    await tester.pumpWidget(MaterialApp(home: HomeScreen(api: api, onSignOut: () {})));
    for (var i = 0; i < 10; i++) {
      await tester.runAsync(settle);
      await tester.pump();
    }
    expect(api.onDecks, 1, reason: 'Komga had nothing new: Home loaded once');
  });
}
