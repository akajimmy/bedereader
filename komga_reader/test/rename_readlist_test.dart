// Renaming a read list (user, 2026-10-18: "starting with the ability to rename a read list"): from the read list's
// actions (⋮ on its screen, or its poster's menu), sent to Komga, its screen and its pins following; Komga's refusals
// said in words.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:komga_reader/api.dart';
import 'package:komga_reader/pins.dart';
import 'package:komga_reader/refresh_gate.dart';
import 'package:komga_reader/screens/readlist.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/browse_server.dart';
import 'support/client_settings.dart';
import 'support/helpers.dart';
import 'support/no_network.dart';

/// [BrowseServer], recording renames - or refusing them with [refuse] (Komga's HTTP status).
class RenameServer extends BrowseServer with ClientSettingsStore {
  int? refuse;
  final renamed = <String>[]; // "RL1 -> Secret Wars"
  @override
  Future<void> renameReadList(String id, String name) async {
    if (refuse != null) throw KomgaError(refuse!, '/api/v1/readlists/$id');
    renamed.add('$id -> $name');
  }
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    RefreshGate.gap = Duration.zero;
  });
  tearDown(() async {
    RefreshGate.gap = const Duration(seconds: 10);
    await Pins.instance.clearAccount();
  });

  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 60)); // (no settle: spinners)
    }
  }

  Future<RenameServer> open(WidgetTester tester, {List<Pin> pins = const []}) async {
    final api = noNetwork(RenameServer.new);
    await Pins.instance.load(api);
    for (final p in pins) {
      Pins.instance.add(p);
    }
    setView(tester, const Size(1280, 900));
    await tester.pumpWidget(MaterialApp(home: ReadListScreen(api: api, readList: {'id': 'RL1', 'name': 'Infinity'})));
    await settle(tester);
    return api;
  }

  /// ⋮ > Rename, [name] typed over the old one, then [button].
  Future<void> rename(WidgetTester tester, String name, {String button = 'Rename'}) async {
    await tester.tap(find.byTooltip('Read list actions'));
    await settle(tester);
    await tester.tap(find.text('Rename'));
    await settle(tester);
    expect(find.widgetWithText(TextField, 'Infinity'), findsOneWidget, reason: 'the old name, to type over');
    await tester.enterText(find.byType(TextField), name);
    await tester.tap(find.widgetWithText(button == 'Rename' ? FilledButton : TextButton, button));
    await settle(tester);
  }

  test("a list's pins follow its new name: its title, and the name where it was the list's - alone or before the "
      "view's words - but a name of your own stays", () {
    Pin pin(String name) => Pin(name: name, kind: 'readlist', id: 'RL1', title: 'Infinity');
    expect((pin('Infinity').retitled('Infinity', 'Secret Wars').name, pin('Infinity').retitled('Infinity', 'Secret Wars').title),
        ('Secret Wars', 'Secret Wars'));
    expect(pin('Infinity · Unread').retitled('Infinity', 'Secret Wars').name, 'Secret Wars · Unread');
    expect(pin('My crossover').retitled('Infinity', 'Secret Wars').name, 'My crossover');
    expect(pin('Infinity Gauntlet').retitled('Infinity', 'Secret Wars').name, 'Infinity Gauntlet',
        reason: 'only the whole name, not a word that starts with it');
  });

  testWidgets("⋮ > Rename: sent to Komga; the screen's title and the list's pins follow", (tester) async {
    final api = await open(tester, pins: [
      const Pin(name: 'Infinity · Unread', kind: 'readlist', id: 'RL1', title: 'Infinity', filter: 'hideRead'),
      const Pin(name: 'Infinity', kind: 'readlist', id: 'RL2', title: 'Infinity'), // another list of the same name
    ]);
    await rename(tester, '  Secret Wars ');
    expect(api.renamed, ['RL1 -> Secret Wars'], reason: 'the name, trimmed');
    expect(find.text('Renamed to "Secret Wars"'), findsOneWidget);
    expect(find.text('Secret Wars'), findsWidgets, reason: "the screen's title");
    expect(find.text('Infinity'), findsNothing);
    expect([for (final p in Pins.instance.items) '${p.id} ${p.name}'], ['RL1 Secret Wars · Unread', 'RL2 Infinity'],
        reason: "this list's pins only");
  });

  testWidgets('nothing is sent when cancelled, left the same, or emptied', (tester) async {
    final api = await open(tester);
    await rename(tester, 'Secret Wars', button: 'Cancel');
    await rename(tester, 'Infinity');
    await rename(tester, '   ');
    expect(api.renamed, isEmpty);
    expect(find.text('Infinity'), findsWidgets);
  });

  testWidgets("Komga's refusals in words: an account that isn't an admin's; a name another list has", (tester) async {
    final api = await open(tester);
    api.refuse = 403;
    await rename(tester, 'Secret Wars');
    expect(find.textContaining('needs an admin account'), findsOneWidget);
    ScaffoldMessenger.of(tester.element(find.byType(ReadListScreen))).hideCurrentSnackBar();
    await settle(tester);
    api.refuse = 400;
    await rename(tester, 'Secret Wars');
    expect(find.textContaining('Another read list may already be called "Secret Wars"'), findsOneWidget);
    expect(find.text('Infinity'), findsWidgets, reason: 'still its old name');
  });
}
