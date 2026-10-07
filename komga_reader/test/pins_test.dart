import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:komga_reader/ondeck_hidden.dart';
import 'package:komga_reader/pins.dart';
import 'package:komga_reader/refresh_gate.dart';
import 'package:komga_reader/screens/app_settings.dart';
import 'package:komga_reader/screens/home.dart';
import 'package:komga_reader/screens/readlist.dart';
import 'package:komga_reader/settings.dart';
import 'package:komga_reader/widgets/refresh_on_return.dart';
import 'package:komga_reader/widgets/setting_rows.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/client_settings.dart';
import 'support/home_server.dart';
import 'support/helpers.dart' show onePage, setView;
import 'support/no_network.dart';

/// Komga's client settings (what's written, whether it can be reached), and an empty read list to open.
class PinsServer extends SettingsServer {
  @override
  Future<Map<String, dynamic>> readListBooks(String readListId, {List<String>? readStatus, int page = 0, int size = 1000}) async =>
      onePage([]);
}

PinsServer server() => noNetwork(PinsServer.new);

/// Home, with the client settings (where pins are kept) and the read list a pin's tile shows.
class PinnedHome extends HomeServer with ClientSettingsStore {
  @override
  Future<Map<String, dynamic>> readListBooks(String readListId, {List<String>? readStatus, int page = 0, int size = 1000}) async =>
      onePage([]);
}

void main() {
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    Pins.instance.items = [];
    RefreshGate.gap = Duration.zero; // each refresh asks (the one-per-10-s limit has its own test)
  });
  tearDown(() => RefreshGate.gap = const Duration(seconds: 10));

  const uu = Pin(name: 'Ultimate Universe · unread', kind: 'readlist', id: 'RL1', title: 'Ultimate Universe',
      filter: 'hideRead');

  test('same view ignores the name; different filter is a different view', () {
    expect(uu.sameView(uu.renamed('UU')), isTrue);
    expect(uu.sameView(const Pin(name: 'x', kind: 'readlist', id: 'RL1', title: 'Ultimate Universe')), isFalse);
  });

  test('add, rename, remove - and each change is written to Komga', () async {
    final api = server();
    await Pins.instance.load(api);
    Pins.instance.add(uu);
    await pumpEventQueue();
    expect(Pins.instance.items.single.name, 'Ultimate Universe · unread');
    expect(api.written[Pins.komgaKey], contains('RL1'));

    Pins.instance.rename(uu, 'UU next');
    await pumpEventQueue();
    expect(Pins.instance.find(uu)!.name, 'UU next');

    Pins.instance.add(uu.renamed('again')); // pinning the same view twice replaces, never duplicates
    expect(Pins.instance.items.length, 1);

    Pins.instance.remove(uu);
    await pumpEventQueue();
    expect(Pins.instance.items, isEmpty);
    expect(api.written[Pins.komgaKey], '[]');
  });

  test('pins come back from Komga on another device', () async {
    final api = server();
    await Pins.instance.load(api);
    Pins.instance.add(uu);
    await pumpEventQueue();
    Pins.instance.items = [];
    SharedPreferences.setMockInitialValues({}); // "new device": nothing local
    await Pins.instance.load(api);
    expect(Pins.instance.items.single.id, 'RL1');
  });

  test("a pin added while Komga was down survives the next start and is sent then - not replaced by Komga's older "
      'list (code review, 2026-09-30)', () async {
    final api = server();
    await Pins.instance.load(api); // Komga has no pins
    api.down = true;
    Pins.instance.add(uu);
    await pumpEventQueue();
    expect(api.written[Pins.komgaKey], isNull); // couldn't be sent

    api.down = false;
    Pins.instance.items = []; // "the next start"
    await Pins.instance.load(api);
    expect(Pins.instance.items.single.id, 'RL1', reason: "this device's unsent pin wins");
    expect(api.written[Pins.komgaKey], contains('RL1'), reason: 'and reaches Komga');
  });

  // a pin made on the tablet never reached a PC app left open: pins came from Komga only at start-up (user,
  // 2026-10-05) - now each time Home reloads
  test('refresh: a pin made on another device arrives without restarting', () async {
    final api = server();
    await Pins.instance.load(api);
    expect(Pins.instance.items, isEmpty);
    api.written[Pins.komgaKey] = jsonEncode([uu.toJson()]); // pinned on the tablet
    await Pins.instance.refresh();
    expect(Pins.instance.items.single.id, 'RL1');
    final saved = (await SharedPreferences.getInstance()).getString('pins');
    expect(saved, contains('RL1'), reason: 'and kept on this device');
  });

  test('refresh: one fetch at a time, and none within 10 s of the last (going online reloads Home several times)',
      () async {
    RefreshGate.gap = const Duration(seconds: 10);
    final api = server();
    await Pins.instance.load(api);
    final asked = api.gets;
    await Future.wait([Pins.instance.refresh(), Pins.instance.refresh(), Pins.instance.refresh()]);
    expect(api.gets, asked, reason: 'just asked at the start: none again within 10 s');
    RefreshGate.gap = Duration.zero;
    api.holdGet = Completer<void>();
    final a = Pins.instance.refresh(), b = Pins.instance.refresh();
    await pumpEventQueue();
    expect(api.gets, asked + 1, reason: 'two at once: one fetch');
    api.holdGet!.complete();
    await Future.wait([a, b]);
  });

  test('refresh: a pin made here while the list from Komga was on its way is kept - the older list is dropped, and '
      'the new pin reaches Komga', () async {
    final api = server()..written[Pins.komgaKey] = '[]'; // Komga has a pin list (empty): that's what comes back
    await Pins.instance.load(api);
    api.holdGet = Completer<void>();
    final refreshing = Pins.instance.refresh(); // asked Komga: an empty list on its way
    await pumpEventQueue();
    Pins.instance.add(uu); // pinned here meanwhile
    await pumpEventQueue();
    api.holdGet!.complete();
    await refreshing;
    await pumpEventQueue();
    expect(Pins.instance.items.single.id, 'RL1', reason: 'not replaced by the list asked for before');
    expect(api.written[Pins.komgaKey], contains('RL1'));
  });

  testWidgets('Home reloading (back on Home, pull to refresh) fetches the pins, the reader settings and On deck '
      'hidden from Komga', (tester) async {
    final api = noNetwork(PinnedHome.new);
    await Pins.instance.load(api);
    await tester.runAsync(() async {
      await AppSettings.instance.load(api);
      await OnDeckHidden.instance.load(api);
    });
    addTearDown(() async {
      await AppSettings.instance.clearAccount();
      await OnDeckHidden.instance.clearAccount();
    });
    await tester.pumpWidget(MaterialApp(home: HomeScreen(api: api, onSignOut: () {})));
    await tester.pump();
    await tester.pump();
    expect(find.text('Ultimate Universe · unread'), findsNothing);
    // on the tablet: pinned a read list, made fit width the default, hid a series from On deck
    api.written[Pins.komgaKey] = jsonEncode([uu.toJson()]);
    api.written[AppSettings.komgaKey] =
        jsonEncode({'default': const ReaderPrefs(fit: FitMode.width).toJson(), 'series': <String, dynamic>{}});
    api.written[OnDeckHidden.komgaKey] = jsonEncode({'series': ['S9'], 'books': <String>[]});
    (tester.state(find.byType(HomeScreen)) as RefreshOnReturn).refreshView(); // as coming back to Home
    await tester.runAsync(pumpEventQueue);
    await tester.pump();
    await tester.pump();
    await tester.pump();
    expect(Pins.instance.items.single.id, 'RL1');
    expect(find.text('Ultimate Universe · unread'), findsOneWidget, reason: 'its tile on Home');
    expect(AppSettings.instance.defaults.fit, FitMode.width, reason: 'the reader settings too');
    expect(OnDeckHidden.instance.seriesHidden('S9'), isTrue, reason: 'and On deck hidden');
  });

  // Sync pins across devices, a switch per device (user, 2026-10-05): on by default
  group('sync pins across devices', () {
    const xb = Pin(name: 'X-Books', kind: 'readlist', id: 'RL2', title: 'X-Books');

    test('off: this device keeps a copy as its own list; pins made here stay here, and ones made elsewhere stay '
        'there - after a restart too', () async {
      final api = server()..written[Pins.komgaKey] = jsonEncode([uu.toJson()]);
      await Pins.instance.load(api);
      expect(Pins.instance.sync, isTrue, reason: 'on by default');
      await Pins.instance.setSync(false);
      expect(Pins.instance.items.single.id, 'RL1', reason: 'starts as a copy of the shared list');
      final puts = api.puts;
      Pins.instance.add(xb);
      await pumpEventQueue();
      expect(api.puts, puts, reason: 'not sent');
      expect(api.written[Pins.komgaKey], isNot(contains('RL2')));
      api.written[Pins.komgaKey] = '[]'; // unpinned everything on the tablet
      await Pins.instance.refresh();
      expect(Pins.instance.items.map((p) => p.id), ['RL1', 'RL2'], reason: "the tablet's change doesn't arrive");
      Pins.instance.items = []; // a restart
      await Pins.instance.load(api);
      expect(Pins.instance.sync, isFalse);
      expect(Pins.instance.items.map((p) => p.id), ['RL1', 'RL2'], reason: "this device's own list, kept");
    });

    test("back on: the shared list returns, from Komga; this device's own goes", () async {
      final api = server()..written[Pins.komgaKey] = jsonEncode([uu.toJson()]);
      await Pins.instance.load(api);
      await Pins.instance.setSync(false);
      Pins.instance.add(xb);
      await pumpEventQueue();
      expect(await Pins.instance.deviceOnly(), [xb], reason: 'what switching back on would drop');
      api.written[Pins.komgaKey] = jsonEncode([uu.toJson(), const Pin(name: 'Pull List', kind: 'readlist',
          id: 'RL3', title: 'Pull List').toJson()]); // changed elsewhere meanwhile
      await Pins.instance.setSync(true);
      expect(Pins.instance.items.map((p) => p.id), ['RL1', 'RL3'], reason: "Komga's list, as it is now");
      expect(await Pins.instance.deviceOnly(), isEmpty);
      expect((await SharedPreferences.getInstance()).getString('pins.device'), isNull);
    });

    test("signing out: this device's own pins go too (they were the account's)", () async {
      final api = server();
      await Pins.instance.load(api);
      await Pins.instance.setSync(false);
      Pins.instance.add(xb);
      await pumpEventQueue();
      await Pins.instance.clearAccount();
      expect((await SharedPreferences.getInstance()).getString('pins.device'), isNull);
    });

    testWidgets('Settings > Library & Home: the switch; back on with pins only this device has asks first, naming '
        'them - Cancel keeps it off', (tester) async {
      setView(tester, const Size(1280, 1600));
      final api = noNetwork(PinnedHome.new)..written[Pins.komgaKey] = jsonEncode([uu.toJson()]);
      await tester.runAsync(() async {
        await Pins.instance.load(api);
        await Pins.instance.setSync(false);
      });
      Pins.instance.add(xb);
      await tester.runAsync(pumpEventQueue);
      await tester.pumpWidget(MaterialApp(home: AppSettingsScreen(api: api, onSignOut: () {},
          initialPage: SettingsPage.library)));
      await tester.pump();
      final row = find.widgetWithText(SwitchRow, 'Sync pins across devices');
      await tester.ensureVisible(row);
      expect(find.text('This device has its own pins'), findsOneWidget);
      await tester.tap(find.descendant(of: row, matching: find.byType(Switch)));
      await tester.runAsync(pumpEventQueue);
      await tester.pumpAndSettle();
      expect(find.textContaining('This device has 1 pin the shared list doesn\'t (X-Books)'), findsOneWidget);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(Pins.instance.sync, isFalse, reason: 'cancelled: still off');
      await tester.tap(find.descendant(of: row, matching: find.byType(Switch)));
      await tester.runAsync(pumpEventQueue);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Sync'));
      await tester.runAsync(pumpEventQueue);
      await tester.pumpAndSettle();
      expect(Pins.instance.sync, isTrue);
      expect(Pins.instance.items.single.id, 'RL1', reason: 'the shared list');
      expect(find.text('The same pins on every device signed in to this account'), findsOneWidget);
    });
  });

  test('On deck hidden, refreshed: something hidden here while the list from Komga was on its way is kept, and '
      'reaches Komga', () async {
    final api = server()..written[OnDeckHidden.komgaKey] = jsonEncode({'series': <String>[], 'books': <String>[]});
    await OnDeckHidden.instance.load(api);
    addTearDown(OnDeckHidden.instance.clearAccount);
    api.holdGet = Completer<void>();
    final refreshing = OnDeckHidden.instance.refresh(); // an empty list on its way
    await pumpEventQueue();
    OnDeckHidden.instance.setSeries('S1', true); // hidden here meanwhile
    await pumpEventQueue();
    api.holdGet!.complete();
    await refreshing;
    await pumpEventQueue();
    expect(OnDeckHidden.instance.seriesHidden('S1'), isTrue, reason: 'not replaced by the list asked for before');
    expect(api.written[OnDeckHidden.komgaKey], contains('S1'));
  });

  testWidgets('a read list opened from a pin starts with that pin\'s filter, and its pin button shows pinned', (tester) async {
    final api = server();
    await Pins.instance.load(api);
    Pins.instance.add(uu);
    await tester.pumpWidget(MaterialApp(home: ReadListScreen(api: api, pin: uu,
        readList: const {'id': 'RL1', 'name': 'Ultimate Universe', 'bookIds': []})));
    await tester.pump();
    expect(find.byTooltip('Read hidden (hide unread)'), findsOneWidget); // hide-read is on, from the pin
    expect(find.byIcon(Icons.push_pin), findsOneWidget); // filled pin = this view is pinned
    expect(find.text('Nothing unread in this list'), findsOneWidget);
  });
}
