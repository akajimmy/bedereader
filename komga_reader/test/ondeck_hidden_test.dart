import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:komga_reader/ondeck_hidden.dart';
import 'package:komga_reader/screens/home.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/client_settings.dart';
import 'support/home_server.dart';
import 'support/no_network.dart';

/// On deck with two books (series S1 and S2); Komga's client settings kept in memory, or unreachable.
class DeckKomga extends HomeServer with ClientSettingsStore {
  DeckKomga() : super(onDeckBooks: [
          {'id': 'B1', 'seriesId': 'S1', 'seriesTitle': 'Hidden Series', 'name': 'b1', 'metadata': {'number': '4'}},
          {'id': 'B2', 'seriesId': 'S2', 'seriesTitle': 'Shown Series', 'name': 'b2', 'metadata': {'number': '7'}},
        ]);
}

void main() {
  final h = OnDeckHidden.instance;
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    h.reset();
  });

  test('a hidden series hides all its books; a hidden book only itself', () {
    h.setSeries('S1', true);
    h.setBook('B9', true);
    expect(h.hides({'id': 'B1', 'seriesId': 'S1'}), isTrue);
    expect(h.hides({'id': 'B9', 'seriesId': 'S3'}), isTrue);
    expect(h.hides({'id': 'B2', 'seriesId': 'S2'}), isFalse);
    h.setSeries('S1', false);
    expect(h.hides({'id': 'B1', 'seriesId': 'S1'}), isFalse);
  });

  test('synced through Komga: another device gets the list', () async {
    final api = noNetwork(DeckKomga.new);
    await h.load(api);
    h.setSeries('S1', true);
    await Future<void>.delayed(const Duration(milliseconds: 10));
    expect(api.written[OnDeckHidden.komgaKey], contains('S1'));

    SharedPreferences.setMockInitialValues({}); // a second device
    h.reset();
    await h.load(api);
    expect(h.seriesHidden('S1'), isTrue);
  });

  test("changed while Komga can't be reached: kept, and sent at the next start instead of being overwritten",
      () async {
    final api = noNetwork(DeckKomga.new)..written[OnDeckHidden.komgaKey] = '{"series":[],"books":[]}';
    await h.load(api);
    api.down = true;
    h.setBook('B1', true);
    await Future<void>.delayed(const Duration(milliseconds: 10));
    api.down = false;
    h.reset(); // restart
    await h.load(api);
    expect(h.bookHidden('B1'), isTrue);
    expect(api.written[OnDeckHidden.komgaKey], contains('B1'));
  });

  test('changed while offline: sent as soon as the app is back online, not only at the next start (test audit)',
      () async {
    final api = noNetwork(DeckKomga.new)..written[OnDeckHidden.komgaKey] = '{"series":[],"books":[]}';
    await h.load(api);
    api.down = true;
    h.setSeries('S2', true); // offline: can't be sent
    await Future<void>.delayed(const Duration(milliseconds: 10));
    expect(api.written[OnDeckHidden.komgaKey], isNot(contains('S2')));
    api.down = false;
    h.useApi(api); // back online (what Connection does)
    await Future<void>.delayed(const Duration(milliseconds: 10));
    expect(api.written[OnDeckHidden.komgaKey], contains('S2'));
  });

  testWidgets('Home leaves hidden series out of On deck, and brings them back', (tester) async {
    final api = noNetwork(DeckKomga.new);
    h.setSeries('S1', true);
    await tester.pumpWidget(MaterialApp(home: HomeScreen(api: api, onSignOut: () {})));
    await tester.pump();
    await tester.pump();
    expect(find.text('Shown Series #7'), findsOneWidget);
    expect(find.text('Hidden Series #4'), findsNothing);
    h.setSeries('S1', false);
    await tester.pump();
    await tester.pump();
    expect(find.text('Hidden Series #4'), findsOneWidget);
  });
}
