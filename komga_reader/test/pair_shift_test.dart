// Comics in two pages: the books whose pairing is shifted by one - per book, synced through Komga (user, 2026-10-16).
// The sync itself is On deck hidden's (lib/synced_ids.dart; its own tests in ondeck_hidden_test.dart).
import 'package:flutter_test/flutter_test.dart';
import 'package:komga_reader/ondeck_hidden.dart';
import 'package:komga_reader/synced_ids.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/deck_server.dart';
import 'support/no_network.dart';

void main() {
  final s = PairShift.instance;
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    s.reset();
    OnDeckHidden.instance.reset();
  });

  test('a book shifted on one device is shifted on another; shifted back, back on both', () async {
    final api = noNetwork(DeckKomga.new);
    await s.load(api);
    expect(s.shifted('B1'), isFalse);
    s.setShifted('B1', true);
    expect(s.shifted('B1'), isTrue);
    expect(s.shifted('B2'), isFalse, reason: 'per book');
    await pumpEventQueue();
    expect(api.written[PairShift.komgaKey], contains('B1'));

    SharedPreferences.setMockInitialValues({}); // a second device
    s.reset();
    await s.load(api);
    expect(s.shifted('B1'), isTrue);
    s.setShifted('B1', false);
    await pumpEventQueue();
    expect(api.written[PairShift.komgaKey], isNot(contains('B1')));
  });

  test("kept apart from On deck's list, though they share how they sync", () async {
    final api = noNetwork(DeckKomga.new);
    await s.load(api);
    await OnDeckHidden.instance.load(api);
    s.setShifted('B1', true);
    OnDeckHidden.instance.setBook('B2', true);
    await pumpEventQueue();
    expect(OnDeckHidden.instance.bookHidden('B1'), isFalse);
    expect(s.shifted('B2'), isFalse);
    expect(api.written[OnDeckHidden.komgaKey], allOf(contains('B2'), isNot(contains('B1'))));
    expect(api.written[PairShift.komgaKey], allOf(contains('B1'), isNot(contains('B2'))));
    // and so on another device
    SharedPreferences.setMockInitialValues({});
    s.reset();
    OnDeckHidden.instance.reset();
    await s.load(api);
    await OnDeckHidden.instance.load(api);
    expect((s.shifted('B1'), s.shifted('B2')), (true, false));
    expect((OnDeckHidden.instance.bookHidden('B2'), OnDeckHidden.instance.bookHidden('B1')), (true, false));
  });

  test('signing out: the account\'s list goes from this device', () async {
    final api = noNetwork(DeckKomga.new);
    await s.load(api);
    s.setShifted('B1', true);
    await pumpEventQueue();
    await s.clearAccount();
    expect(s.shifted('B1'), isFalse);
  });
}
