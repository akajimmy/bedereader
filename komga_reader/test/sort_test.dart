import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:komga_reader/pins.dart';
import 'package:komga_reader/screens/library.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/browse_server.dart';
import 'support/helpers.dart';
import 'support/no_network.dart';

void main() {
  Future<BrowseServer> open(WidgetTester tester, {Pin? pin}) async {
    final api = noNetwork(BrowseServer.new);
    setView(tester, const Size(1280, 900));
    await tester.pumpWidget(MaterialApp(home: LibraryScreen(key: UniqueKey(), api: api, onSignOut: () {}, libraryId: 'L1', pin: pin)));
    await tester.pump();
    await tester.pump();
    return api;
  }

  Future<void> pick(WidgetTester tester, String item) async {
    await tester.tap(find.byWidgetPredicate((w) => w is PopupMenuButton && (w.tooltip ?? '').startsWith('Sort')));
    await tester.pumpAndSettle();
    await tester.tap(find.text(item).last);
    await tester.pumpAndSettle();
  }

  testWidgets('sort menu: fields start in their natural direction, and the direction can be flipped', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final api = await open(tester);
    expect(api.sorts.last, 'metadata.titleSort,asc'); // default: title A -> Z

    await pick(tester, 'Z → A');
    expect(api.sorts.last, 'metadata.titleSort,desc');

    await pick(tester, 'Date added'); // new field: its natural direction (newest first)
    expect(api.sorts.last, 'createdDate,desc');

    await pick(tester, 'Oldest first');
    expect(api.sorts.last, 'createdDate,asc');

    final saved = jsonDecode((await SharedPreferences.getInstance()).getString('view.library.L1')!) as Map;
    expect(saved['sort'], 'added');
    expect(saved['desc'], false);
    expect(find.byTooltip('Clear filters'), findsOneWidget); // not the default any more
  });

  testWidgets("a saved view without a direction opens in its sort's natural one", (tester) async {
    SharedPreferences.setMockInitialValues({'view.library.L1': jsonEncode({'mode': 'series', 'sort': 'updated'})});
    final api = await open(tester);
    expect(api.sorts.last, 'lastModifiedDate,desc');
  });

  testWidgets('pins carry the direction ("key:dir"); old pins with just the key still open', (tester) async {
    SharedPreferences.setMockInitialValues({});
    var api = await open(tester, pin: const Pin(name: 'x', kind: 'library', id: 'L1', title: 'Events', mode: 'series',
        sort: 'added:asc'));
    expect(api.sorts.last, 'createdDate,asc');
    api = await open(tester, pin: const Pin(name: 'x', kind: 'library', id: 'L1', title: 'Events', mode: 'series',
        sort: 'title'));
    expect(api.sorts.last, 'metadata.titleSort,asc');
  });
}
