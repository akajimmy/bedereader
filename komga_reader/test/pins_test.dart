import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:komga_reader/pins.dart';
import 'package:komga_reader/screens/home.dart';
import 'package:komga_reader/screens/readlist.dart';
import 'package:komga_reader/widgets/refresh_on_return.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/client_settings.dart';
import 'support/home_server.dart';
import 'support/helpers.dart' show onePage;
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
    Pins.refreshGap = Duration.zero; // each refresh asks (the one-per-10-s limit has its own test)
  });
  tearDown(() => Pins.refreshGap = const Duration(seconds: 10));

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
    Pins.refreshGap = const Duration(seconds: 10);
    final api = server();
    await Pins.instance.load(api);
    final asked = api.gets;
    await Future.wait([Pins.instance.refresh(), Pins.instance.refresh(), Pins.instance.refresh()]);
    expect(api.gets, asked, reason: 'just asked at the start: none again within 10 s');
    Pins.refreshGap = Duration.zero;
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

  testWidgets('Home reloading (back on Home, pull to refresh) fetches the pins from Komga', (tester) async {
    final api = noNetwork(PinnedHome.new);
    await Pins.instance.load(api);
    await tester.pumpWidget(MaterialApp(home: HomeScreen(api: api, onSignOut: () {})));
    await tester.pump();
    await tester.pump();
    expect(find.text('Ultimate Universe · unread'), findsNothing);
    api.written[Pins.komgaKey] = jsonEncode([uu.toJson()]); // pinned on the tablet
    (tester.state(find.byType(HomeScreen)) as RefreshOnReturn).refreshView(); // as coming back to Home
    await tester.pump();
    await tester.pump();
    await tester.pump();
    expect(Pins.instance.items.single.id, 'RL1');
    expect(find.text('Ultimate Universe · unread'), findsOneWidget, reason: 'its tile on Home');
  });

  testWidgets('a read list opened from a pin starts with that pin\'s filter, and its pin button shows pinned', (tester) async {
    final api = server();
    await Pins.instance.load(api);
    Pins.instance.add(uu);
    await tester.pumpWidget(MaterialApp(home: ReadListScreen(api: api, pin: uu,
        readList: const {'id': 'RL1', 'name': 'Ultimate Universe', 'bookIds': []})));
    await tester.pump();
    expect(find.byTooltip('Read hidden (show read)'), findsOneWidget); // hide-read is on, from the pin
    expect(find.byIcon(Icons.push_pin), findsOneWidget); // filled pin = this view is pinned
    expect(find.text('Nothing unread in this list'), findsOneWidget);
  });
}
