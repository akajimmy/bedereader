import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:komga_reader/api.dart';
import 'package:komga_reader/pins.dart';
import 'package:komga_reader/screens/readlist.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Records what was written to Komga's client settings.
class FakeKomga extends Komga {
  FakeKomga() : super('http://test', 'k');
  final written = <String, String>{};
  @override
  Future<Map<String, dynamic>> clientSettings() async => {for (final e in written.entries) e.key: {'value': e.value}};
  @override
  Future<void> putClientSetting(String key, String value) async => written[key] = value;
  @override
  Future<Map<String, dynamic>> readListBooks(String readListId, {List<String>? readStatus, int page = 0, int size = 1000}) async =>
      {'content': [], 'totalElements': 0, 'last': true};
}

/// [FakeKomga] that can't be reached while [down].
class DownKomga extends FakeKomga {
  bool down = false;
  @override
  Future<Map<String, dynamic>> clientSettings() async {
    if (down) throw KomgaUnreachable(baseUrl);
    return super.clientSettings();
  }

  @override
  Future<void> putClientSetting(String key, String value) async {
    if (down) throw KomgaUnreachable(baseUrl);
    return super.putClientSetting(key, value);
  }
}

void main() {
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    Pins.instance.items = [];
  });

  const uu = Pin(name: 'Ultimate Universe · unread', kind: 'readlist', id: 'RL1', title: 'Ultimate Universe',
      filter: 'hideRead');

  test('same view ignores the name; different filter is a different view', () {
    expect(uu.sameView(uu.renamed('UU')), isTrue);
    expect(uu.sameView(const Pin(name: 'x', kind: 'readlist', id: 'RL1', title: 'Ultimate Universe')), isFalse);
  });

  test('add, rename, remove - and each change is written to Komga', () async {
    final api = FakeKomga();
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
    final api = FakeKomga();
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
    final api = DownKomga();
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

  testWidgets('a read list opened from a pin starts with that pin\'s filter, and its pin button shows pinned', (tester) async {
    final api = FakeKomga();
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
