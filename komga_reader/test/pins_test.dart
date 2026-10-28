import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:komga_reader/api.dart' show Komga;
import 'package:komga_reader/ondeck_hidden.dart';
import 'package:komga_reader/pins.dart';
import 'package:komga_reader/refresh_gate.dart';
import 'package:komga_reader/screens/home.dart';
import 'package:komga_reader/screens/readlist.dart';
import 'package:komga_reader/settings.dart';
import 'package:komga_reader/widgets/pins_editor.dart';
import 'package:komga_reader/widgets/refresh_on_return.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/client_settings.dart';
import 'support/home_server.dart';
import 'support/helpers.dart' show onePage;
import 'support/no_network.dart';

/// Home, with Komga's client settings (where pins are kept: what's written, whether it can be reached), an empty read
/// list (a pinned one opened, a pin's tile) and the account (Settings > Server and sync's status).
class PinsServer extends HomeServer with ClientSettingsStore {
  @override
  Future<Map<String, dynamic>> readListBooks(String readListId, {List<String>? readStatus, int page = 0, int size = 1000}) async =>
      onePage([]);
  @override
  Future<Map<String, dynamic>?> me({via, Duration limit = Komga.timeout}) async => {'email': 'nick@test'};
}

PinsServer server() => noNetwork(PinsServer.new);

void main() {
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    RefreshGate.gap = Duration.zero; // each refresh asks (the one-per-10-s limit has its own test)
  });
  tearDown(() async {
    RefreshGate.gap = const Duration(seconds: 10);
    // all of it, not just the list: the server, what's unsent, a retry timer left by a send that failed (test
    // audit, 2026-10-07)
    await Pins.instance.clearAccount();
  });

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
    expect(api.written[Pins.komgaKey], contains('UU next'), reason: 'the rename reaches Komga');

    Pins.instance.add(uu.renamed('again')); // pinning the same view twice replaces, never duplicates
    expect(Pins.instance.items.single.name, 'again', reason: 'the second one replaces the first');

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
    final api = noNetwork(PinsServer.new);
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

  // pins always sync (user, 2026-10-21: "drop this setting entirely. pins always sync.")
  test('always synced: a device that had its own list (the switch from before) gets the shared list; the old keys '
      'go', () async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('pins.sync', false);
    await prefs.setString('pins.device', jsonEncode([const Pin(name: 'X-Books', kind: 'readlist', id: 'RL2',
        title: 'X-Books').toJson()]));
    final api = server()..written[Pins.komgaKey] = jsonEncode([uu.toJson()]);
    await Pins.instance.load(api);
    expect(Pins.instance.items.map((p) => p.id), ['RL1'], reason: 'the shared list');
    expect((prefs.containsKey('pins.sync'), prefs.containsKey('pins.device')), (false, false));
    final puts = api.puts;
    Pins.instance.add(const Pin(name: 'Pull List', kind: 'readlist', id: 'RL3', title: 'Pull List'));
    await pumpEventQueue();
    expect(api.puts, puts + 1, reason: 'sent');
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

  // ---- local pins (rebuild step 8; user, 2026-10-26: "keep local pins local"): a pin to a local library, its series
  // or a book is this device's own - the PC hasn't the tablet's folders
  group('pins to the local libraries', () {
    const saga = Pin(name: 'Saga', kind: 'series', id: 'ls0123456789abc', title: 'Saga');
    const comics = Pin(name: 'Comics', kind: 'library', id: 'll0123456789abc', title: 'Comics');
    tearDown(() => Pins.instance.items = []); // (signing out keeps them: gone here, for the next test)

    test('never sent to Komga, and kept on the device - Komga only ever has its own', () async {
      final api = server();
      await Pins.instance.load(api);
      Pins.instance.add(uu);
      Pins.instance.add(saga);
      await pumpEventQueue();
      expect(api.written[Pins.komgaKey], contains('RL1'));
      expect(api.written[Pins.komgaKey], isNot(contains('ls0123456789abc')));
      final puts = api.puts;
      Pins.instance.rename(saga, 'Saga next');
      await pumpEventQueue();
      expect(api.puts, puts, reason: "only this device's own changed: nothing for Komga");

      Pins.instance.items = [];
      await Pins.instance.load(api, fetch: false); // the next start
      expect([for (final p in Pins.instance.items) p.name], ['Ultimate Universe · unread', 'Saga next']);
    });

    test("Komga's list arriving (from another device) keeps this device's own", () async {
      final api = server();
      await Pins.instance.load(api);
      Pins.instance.add(saga);
      await pumpEventQueue();
      api.written[Pins.komgaKey] = jsonEncode([uu.toJson()]);
      await Pins.instance.refresh();
      expect([for (final p in Pins.instance.items) p.id], ['RL1', 'ls0123456789abc']);
    });

    test("signing out: the account's pins go, this device's own stay", () async {
      final api = server();
      await Pins.instance.load(api);
      Pins.instance.add(uu);
      Pins.instance.add(saga);
      await pumpEventQueue();
      await Pins.instance.clearAccount();
      expect([for (final p in Pins.instance.items) p.id], ['ls0123456789abc']);
      await Pins.instance.load(server(), fetch: false); // the next account
      expect([for (final p in Pins.instance.items) p.id], ['ls0123456789abc']);
    });

    // (user, 2026-10-26: carried over from the experiment) a library gone from a list Komga answered was deleted
    test("a library deleted on Komga: the pins to it, and to its series and books as their views showed them, go - "
        "the first list is only kept; a library still there keeps its pins", () async {
      await Pins.instance.load(server());
      const lib = Pin(name: 'Comics', kind: 'library', id: 'L1', title: 'Comics');
      const series = Pin(name: 'Batman', kind: 'series', id: 'S1', title: 'Batman');
      const other = Pin(name: 'Saga', kind: 'series', id: 'S2', title: 'Saga');
      for (final p in [lib, series, other, uu]) {
        Pins.instance.add(p);
      }
      await Pins.instance.learnLibrary('S1', 'L1');
      await Pins.instance.learnLibrary('S2', 'L2');
      await Pins.instance.librariesNow(['L1', 'L2']); // the first list: only kept
      expect(Pins.instance.items, hasLength(4));
      await Pins.instance.librariesNow(['L2']);
      expect([for (final p in Pins.instance.items) p.id], ['S2', 'RL1']);
      await pumpEventQueue();
    });

    test('Komga tells of its libraries each time it answers a fresh fetch - not from the kept list', () async {
      final told = <List<String>>[];
      Komga.onLibraries = (_, ids) => told.add(ids);
      addTearDown(() => Komga.onLibraries = null);
      final api = noNetwork(_TwoLibraries.new);
      await api.visibleLibraries();
      await api.visibleLibraries(kept: true);
      expect(told, [['L1', 'L2']]);
    });

    // Arrange pins (user, 2026-10-28)
    test("arranged: Komga's pins in their new order on Komga (every device); a local pin keeps its place among them "
        'through the next start and a fresh list from Komga', () async {
      const lib = Pin(name: 'Comics on Komga', kind: 'library', id: 'L1', title: 'Comics');
      final api = server();
      await Pins.instance.load(api);
      for (final p in [uu, saga, lib]) {
        Pins.instance.add(p);
      }
      Pins.instance.reorder(2, 0); // the Komga library first
      Pins.instance.move(saga, -1); // Saga between it and the read list
      await pumpEventQueue();
      expect([for (final p in Pins.instance.items) p.id], ['L1', 'ls0123456789abc', 'RL1']);
      expect([for (final j in jsonDecode(api.written[Pins.komgaKey]!) as List) j['id']], ['L1', 'RL1'],
          reason: "Komga has its pins' new order");

      Pins.instance.items = [];
      await Pins.instance.load(api, fetch: false); // the next start
      expect([for (final p in Pins.instance.items) p.id], ['L1', 'ls0123456789abc', 'RL1']);

      api.written[Pins.komgaKey] = jsonEncode([uu.toJson(), lib.toJson()]); // arranged on another device
      await Pins.instance.refresh();
      expect([for (final p in Pins.instance.items) p.id], ['ls0123456789abc', 'RL1', 'L1'],
          reason: 'Saga still comes just before the read list');

      Pins.instance.move(saga, 1);
      Pins.instance.move(saga, 1);
      await pumpEventQueue();
      Pins.instance.items = [];
      await Pins.instance.load(api, fetch: false);
      expect(Pins.instance.items.last.id, 'ls0123456789abc', reason: 'last, after every synced pin');
    });

    test('local pins saved before pins could be arranged show last, as before', () async {
      SharedPreferences.setMockInitialValues({'pins.here': jsonEncode([saga.toJson()])});
      final api = server();
      api.written[Pins.komgaKey] = jsonEncode([uu.toJson()]);
      await Pins.instance.load(api);
      expect([for (final p in Pins.instance.items) p.id], ['RL1', 'ls0123456789abc']);
    });

    testWidgets('the Arrange pins sheet: ▲ and ▼ move a pin; at the ends they do nothing', (tester) async {
      await tester.runAsync(() async {
        await Pins.instance.load(server(), fetch: false);
        Pins.instance.add(uu);
        Pins.instance.add(saga);
      });
      await tester.pumpWidget(const MaterialApp(home: Scaffold(body: PinsEditor())));
      await tester.tap(find.byTooltip('Move Saga up'));
      await tester.pump();
      expect([for (final p in Pins.instance.items) p.id], ['ls0123456789abc', 'RL1']);
      await tester.tap(find.byTooltip('Move Saga up')); // already first
      await tester.pump();
      expect([for (final p in Pins.instance.items) p.id], ['ls0123456789abc', 'RL1']);
      await tester.tap(find.byTooltip('Move Saga down'));
      await tester.pump();
      expect([for (final p in Pins.instance.items) p.id], ['RL1', 'ls0123456789abc']);
      await tester.runAsync(pumpEventQueue);
    });

    test('a local library removed: the pins to it, its series and books go; the rest stay', () async {
      await Pins.instance.load(server());
      Pins.instance.add(uu);
      Pins.instance.add(saga);
      Pins.instance.add(comics);
      Pins.instance.removeFor({'ll0123456789abc', 'ls0123456789abc', 'lb0123456789abc'});
      expect([for (final p in Pins.instance.items) p.id], ['RL1']);
      await pumpEventQueue();
    });
  });
}

/// Komga with two libraries.
class _TwoLibraries extends TestKomga {
  @override
  Future<List<dynamic>> libraries() async => [{'id': 'L1', 'name': 'Comics'}, {'id': 'L2', 'name': 'Books'}];
}
