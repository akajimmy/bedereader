// The menus of series, read lists and collections (right-click / long-press a poster; user, 2026-10-18: "right click /
// context menu on a read list or series should allow pin" and, for collections, it "does not work / appear / have any
// options"): Pin to Home in all three; collections get a menu of their own.
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:komga_reader/api.dart';
import 'package:komga_reader/pins.dart';
import 'package:komga_reader/refresh_gate.dart';
import 'package:komga_reader/screens/actions.dart';
import 'package:komga_reader/screens/library.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/browse_server.dart';
import 'support/client_settings.dart';
import 'support/helpers.dart';
import 'support/no_network.dart';

/// [BrowseServer] with pins' settings store, recording series marked and collections renamed.
class MenuServer extends BrowseServer with ClientSettingsStore {
  final marked = <String>[], renamed = <String>[];
  @override
  Future<void> markSeriesRead(String seriesId) async => marked.add('$seriesId read');
  @override
  Future<void> markSeriesUnread(String seriesId) async => marked.add('$seriesId unread');
  @override
  Future<void> renameCollection(String id, String name) async => renamed.add('$id -> $name');
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

  Future<MenuServer> server() async {
    final api = noNetwork(MenuServer.new);
    await Pins.instance.load(api);
    return api;
  }

  /// A button that opens [menu] - the menus as the posters' right-click / long-press open them.
  Future<void> host(WidgetTester tester, Future<void> Function(BuildContext) menu) async {
    await tester.pumpWidget(MaterialApp(key: UniqueKey(), home: Scaffold(body: Builder(builder: (context) =>
        TextButton(onPressed: () => menu(context), child: const Text('menu'))))));
  }

  /// Opens the menu, "Pin to Home", and pins it under the name offered.
  Future<void> pinFromMenu(WidgetTester tester) async {
    await tester.tap(find.text('menu'));
    await settle(tester);
    await tester.tap(find.text('Pin to Home'));
    await settle(tester);
    await tester.tap(find.widgetWithText(FilledButton, 'Pin'));
    await settle(tester);
  }

  testWidgets('Pin to Home in the menus of a series, a read list and a collection: their plain view, as their own '
      'screen pins it; pinned, the menu says so', (tester) async {
    final api = await server();
    final s = {'id': 'S1', 'name': 'Saga', 'metadata': {'title': 'Saga'}, 'booksCount': 3};
    final rl = {'id': 'RL1', 'name': 'Infinity', 'bookIds': ['B1']};
    final c = {'id': 'C1', 'name': 'Marvel cosmic', 'seriesIds': ['S1', 'S2']};
    for (final (kind, id, name, menu) in [
      ('series', 'S1', 'Saga', (BuildContext ctx) => showSeriesActions(ctx, api, s, onChanged: () {})),
      ('readlist', 'RL1', 'Infinity', (BuildContext ctx) => showReadListActions(ctx, api, rl, onChanged: () {})),
      ('collection', 'C1', 'Marvel cosmic', (BuildContext ctx) => showCollectionActions(ctx, api, c, onChanged: () {})),
    ]) {
      await host(tester, menu);
      await pinFromMenu(tester);
      final pin = Pins.instance.find(listPin(kind, id, name));
      expect(pin, isNotNull, reason: kind);
      expect((pin!.name, pin.title, pin.filter, pin.sort, pin.filters.isEmpty), (name, name, 'all', null, true),
          reason: '$kind: its plain view');
      await tester.tap(find.text('menu'));
      await settle(tester);
      expect(find.text('Pinned as "$name"'), findsOneWidget, reason: '$kind: pinned already');
      await tester.tapAt(const Offset(5, 5)); // the sheet closed
      await settle(tester);
    }
    expect(Pins.instance.items, hasLength(3));
  }, tags: 'slow');

  testWidgets('collections have a menu: a right-click on one in the library opens it', (tester) async {
    final api = await server();
    setView(tester, const Size(1280, 900));
    await tester.pumpWidget(MaterialApp(home: LibraryScreen(api: api, onSignOut: () {}, libraryId: 'L1',
        startMode: BrowseMode.collections)));
    await settle(tester);
    await tester.tap(find.text('Marvel cosmic'), buttons: kSecondaryButton);
    await settle(tester);
    expect(find.text('Pin to Home'), findsOneWidget);
    expect(find.text('Mark all as read'), findsOneWidget);
    expect(find.text('Rename'), findsOneWidget);
  });

  testWidgets("a collection's menu: mark every series in it read or unread (asked first), rename it - its pins "
      'following', (tester) async {
    final api = await server();
    final c = {'id': 'C1', 'name': 'Marvel cosmic', 'seriesIds': ['S1', 'S2']};
    Pins.instance.add(listPin('collection', 'C1', 'Marvel cosmic'));
    await host(tester, (ctx) => showCollectionActions(ctx, api, c, onChanged: () {}));
    for (final (action, button) in [('Mark all as read', 'Mark read'), ('Mark all as unread', 'Mark unread')]) {
      await tester.tap(find.text('menu'));
      await settle(tester);
      await tester.tap(find.text(action));
      await settle(tester);
      expect(api.marked, isEmpty, reason: 'asked before anything is changed');
      await tester.tap(find.text(button));
      await settle(tester);
      expect(find.text('2 series marked ${button == 'Mark read' ? 'read' : 'unread'}'), findsOneWidget);
      final want = button == 'Mark read' ? ['S1 read', 'S2 read'] : ['S1 unread', 'S2 unread'];
      expect(api.marked, want);
      api.marked.clear();
      ScaffoldMessenger.of(tester.element(find.text('menu'))).hideCurrentSnackBar();
      await settle(tester);
    }
    await tester.tap(find.text('menu'));
    await settle(tester);
    await tester.tap(find.text('Rename'));
    await settle(tester);
    await tester.enterText(find.byType(TextField), 'Cosmic Marvel');
    await tester.tap(find.widgetWithText(FilledButton, 'Rename'));
    await settle(tester);
    expect(api.renamed, ['C1 -> Cosmic Marvel']);
    expect(Pins.instance.items.single.name, 'Cosmic Marvel', reason: 'its pin follows');
    expect(c['name'], 'Cosmic Marvel');
  });

  testWidgets("a collection's rename refused by Komga (an account that isn't an admin's): said so, nothing changed", (tester) async {
    final api = await server();
    final refusing = noNetwork(_RefusingServer.new);
    final c = {'id': 'C1', 'name': 'Marvel cosmic', 'seriesIds': ['S1']};
    await host(tester, (ctx) => renameCollection(ctx, refusing, c, onChanged: () {}));
    await tester.tap(find.text('menu'));
    await settle(tester);
    await tester.enterText(find.byType(TextField), 'Cosmic Marvel');
    await tester.tap(find.widgetWithText(FilledButton, 'Rename'));
    await settle(tester);
    expect(find.textContaining('needs an admin account'), findsOneWidget);
    expect(c['name'], 'Marvel cosmic');
    expect(api.renamed, isEmpty);
  });
}

/// Komga refusing collection renames (an account that isn't an admin's).
class _RefusingServer extends BrowseServer with ClientSettingsStore {
  @override
  Future<void> renameCollection(String id, String name) async => throw KomgaError(403, '/api/v1/collections/$id');
}
