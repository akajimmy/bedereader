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

import 'support/deck_server.dart';
import 'support/client_settings.dart';
import 'support/helpers.dart';
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

  bool sentWith(ClientSettingsStore api, String key, String what) => api.written[key]?.contains(what) ?? false;

  test('#1: a hide made while Home is open stays hidden - Home refreshing at that moment put back the list from '
      'before it (it re-read the device copy before the hide was saved there)', () async {
    final api = noNetwork(DeckKomga.new)..written[OnDeckHidden.komgaKey] = '{"series":[],"books":[]}';
    await h.load(api);
    Future<void>? refreshing;
    void home() => refreshing ??= h.refresh(); // what Home does when it hears of the change
    h.addListener(home);
    addTearDown(() => h.removeListener(home));
    h.setSeries('S1', true);
    await refreshing;
    await waitUntil(() => sentWith(api, OnDeckHidden.komgaKey, 'S1'), reason: 'the hide sent to Komga');
    expect(h.seriesHidden('S1'), isTrue, reason: 'still hidden here');
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
    await pumpEventQueue();
    expect(api.written[OnDeckHidden.komgaKey], isNull, reason: 'nothing sent before the list is read');
    expect(api.written[Pins.komgaKey], isNull);
    await h.load(api);
    await pins.load(api);
    await waitUntil(() => sentWith(api, OnDeckHidden.komgaKey, 'S1') && sentWith(api, Pins.komgaKey, 'Mine'),
        reason: 'both unsent lists sent as they were saved');
  });

  test('#3: a change made while an earlier one is still on its way reaches Komga - a quick failure and a slow '
      'success cleared the "unsent" mark with the later change never sent', () async {
    final api = noNetwork(DeckKomga.new)..written[OnDeckHidden.komgaKey] = '{"series":[],"books":[]}';
    await h.load(api);
    api.holdPut = Completer<void>();
    h.setSeries('S1', true); // on its way, slowly
    await waitUntil(() => api.puts == 1, reason: 'the first send on its way');
    api.down = true;
    h.setSeries('S2', true); // Komga refuses this one at once
    await pumpEventQueue();
    api.down = false;
    api.holdPut!.complete();
    api.holdPut = null;
    await waitUntil(() => sentWith(api, OnDeckHidden.komgaKey, 'S1') && sentWith(api, OnDeckHidden.komgaKey, 'S2'),
        reason: 'both changes on Komga');
  });

  test('#6: pins - turning sync off while a send is failing stops the retries (a minute later the device-only '
      'list went over the shared pins)', () async {
    final api = noNetwork(SettingsServer.new);
    await pins.load(api);
    addTearDown(() => pins.setSync(true));
    api.holdPut = Completer<void>();
    pins.add(const Pin(name: 'Shared', kind: 'library', title: 'Comics'));
    await waitUntil(() => api.puts == 1, reason: 'the send on its way');
    await pins.setSync(false); // while the send is on its way
    api.holdPut!.completeError(StateError('Komga refused'));
    api.holdPut = null;
    await pumpEventQueue();
    expect(pins.retrying, isFalse, reason: 'no try in a minute: the list is this device\'s now');
  });

  testWidgets("#12: reader settings - a change made while Komga's copy was on its way stays (the refresh brought back "
      'the older value); a change not sent yet stays too', (tester) async {
    final s = AppSettings.instance;
    final api = noNetwork(SettingsServer.new);
    await s.load(api);
    addTearDown(s.clearAccount);
    double onKomga() => (((jsonDecode(api.written[AppSettings.komgaKey]!) as Map)['epub'] as Map)['lineSpacing']
        as num).toDouble();
    // Komga's copy: the default line spacing (synced - unlike the text size, which is each device's own)
    api.written[AppSettings.komgaKey] = jsonEncode({'v': 1, 'default': const ReaderPrefs().toJson(),
        'epub': const EpubPrefs().toJson(), 'series': {}});

    // 1. Home refreshes: Komga's copy (from before the change) is on its way ...
    final asked = api.gets;
    final answer = api.holdGet = Completer<void>();
    final refreshing = s.refresh();
    await tester.pump();
    expect(api.gets, asked + 1, reason: "the refresh's request is on its way");
    // ... the change is made here, sent and taken by Komga before that answer arrives
    api.holdGet = null;
    s.setEpub(s.epub.copyWith(lineSpacing: 2.0));
    await tester.pump(const Duration(seconds: 3)); // the send
    expect(onKomga(), 2.0, reason: 'sent');
    answer.complete();
    await refreshing;
    expect(s.epub.lineSpacing, 2.0, reason: "this device's change, not Komga's copy from before it");

    // 2. a change not sent yet: Komga's copy (the one before it) doesn't replace it
    s.setEpub(s.epub.copyWith(lineSpacing: 1.8));
    await s.refresh();
    expect(s.epub.lineSpacing, 1.8, reason: "this device's unsent change wins");
    await tester.pump(const Duration(seconds: 3)); // and it's sent
    expect(onKomga(), 1.8);
  });

  testWidgets('#34: one Home load per reload - the refreshes told everyone twice even when nothing had changed, '
      'and Home loaded three times', (tester) async {
    final api = noNetwork(CountingDeck.new)..written[OnDeckHidden.komgaKey] = '{"series":[],"books":[]}';
    await tester.runAsync(() => h.load(api));
    await tester.pumpWidget(MaterialApp(home: HomeScreen(api: api, onSignOut: () {})));
    await waitUntil(() => api.onDecks > 0, tester: tester, reason: 'Home loaded');
    for (var i = 0; i < 10; i++) { // time for any further load
      await tester.runAsync(pumpEventQueue);
      await tester.pump();
    }
    expect(api.onDecks, 1, reason: 'Komga had nothing new: Home loaded once');
  });
}
