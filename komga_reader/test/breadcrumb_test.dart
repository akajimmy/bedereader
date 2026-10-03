import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:komga_reader/screens/library.dart';
import 'package:komga_reader/screens/readlist.dart';
import 'package:komga_reader/screens/series.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/browse_server.dart';
import 'support/helpers.dart';
import 'support/no_network.dart';

/// [BrowseServer], with the books of a series (the series screen lists them).
class CrumbServer extends BrowseServer {
  @override
  Future<Map<String, dynamic>> seriesBooks(String seriesId, {List<String>? readStatus,
          String sort = 'metadata.numberSort,asc', int page = 0, int size = 500}) async =>
      onePage([]);
}

/// The breadcrumb's parent is a link (user, 2026-10-02): "Events › Series 1" opens Events, "Read lists › Infinity"
/// the read lists, "Collections › ..." the collections - back to the library screen the user came through when
/// there is one, else a new one.
void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));
  const parent = ValueKey('breadcrumb-parent');

  Future<CrumbServer> start(WidgetTester tester, Widget Function(CrumbServer) home) async {
    final api = noNetwork(CrumbServer.new);
    setView(tester, const Size(1280, 900));
    await tester.pumpWidget(MaterialApp(home: home(api)));
    await tester.pump();
    await tester.pump();
    return api;
  }

  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 60)); // page transitions (no settle: spinners)
    }
  }

  BrowseMode? shownMode(WidgetTester tester) {
    for (final m in BrowseMode.values) {
      final chip = find.widgetWithText(ChoiceChip, switch (m) {
        BrowseMode.series => 'Series', BrowseMode.books => 'Books',
        BrowseMode.collections => 'Collections', BrowseMode.readLists => 'Read lists',
      });
      if (chip.evaluate().isNotEmpty && tester.widget<ChoiceChip>(chip.first).selected) return m;
    }
    return null;
  }

  testWidgets('series opened from its library: the library name goes back to that library screen (not a second one)',
      (tester) async {
    await start(tester, (api) => LibraryScreen(api: api, onSignOut: () {}, libraryId: 'L1'));
    await tester.tap(find.text('Series 1'));
    await settle(tester);
    expect(find.byType(SeriesScreen), findsOneWidget);
    expect(find.descendant(of: find.byKey(parent), matching: find.text('Events')), findsOneWidget,
        reason: 'the library, as a link');
    await tester.tap(find.byKey(parent));
    await settle(tester);
    expect(find.byType(SeriesScreen), findsNothing, reason: 'gone back');
    expect(find.byType(LibraryScreen), findsOneWidget, reason: 'the same library screen - not a new one on top');
    expect(shownMode(tester), BrowseMode.series);
  });

  testWidgets('a read list opened from a library: "Read lists" goes back to it, on its read lists - even when it was '
      'showing something else', (tester) async {
    final api = await start(tester, (api) => LibraryScreen(api: api, onSignOut: () {}, libraryId: 'L1'));
    await tester.tap(find.widgetWithText(ChoiceChip, 'Read lists'));
    await settle(tester);
    await tester.tap(find.text('Infinity'));
    await settle(tester);
    expect(find.byType(ReadListScreen), findsOneWidget);
    await tester.tap(find.byKey(parent));
    await settle(tester);
    expect(find.byType(ReadListScreen), findsNothing);
    expect(find.byType(LibraryScreen), findsOneWidget);
    expect(shownMode(tester), BrowseMode.readLists);

    // the library on Series, a read list on top of it (as from search): back to it, switched to its read lists
    await tester.tap(find.widgetWithText(ChoiceChip, 'Series'));
    await settle(tester);
    expect(shownMode(tester), BrowseMode.series);
    unawaited(tester.state<NavigatorState>(find.byType(Navigator)).push(MaterialPageRoute(
        builder: (_) => ReadListScreen(api: api, readList: {'id': 'RL1', 'name': 'Infinity'}))));
    await settle(tester);
    await tester.tap(find.byKey(parent));
    await settle(tester);
    expect(find.byType(ReadListScreen), findsNothing);
    expect(find.byType(LibraryScreen), findsOneWidget);
    expect(shownMode(tester), BrowseMode.readLists);
  });

  testWidgets('nothing to go back to (opened from Home or search): a library screen is opened - the series\' '
      'library on its series; all libraries on their read lists - and Back returns', (tester) async {
    final api = await start(tester, (api) => SeriesScreen(api: api,
        series: {'id': 'S1', 'name': 'Series 1', 'libraryId': 'L1', 'metadata': {'title': 'Series 1'}}));
    await tester.pump();
    await tester.tap(find.byKey(parent));
    await settle(tester);
    expect(find.byType(LibraryScreen), findsOneWidget);
    expect(tester.widget<LibraryScreen>(find.byType(LibraryScreen)).libraryId, 'L1');
    expect(shownMode(tester), BrowseMode.series);
    expect(api.requests.last, 'series p0 all');
    await tester.binding.handlePopRoute(); // Back
    await settle(tester);
    expect(find.byType(SeriesScreen), findsOneWidget, reason: 'back to the series');

    await tester.pumpWidget(const SizedBox());
    await start(tester, (api) => ReadListScreen(api: api, readList: {'id': 'RL1', 'name': 'Infinity'}));
    await tester.tap(find.byKey(parent));
    await settle(tester);
    expect(tester.widget<LibraryScreen>(find.byType(LibraryScreen)).libraryId, isNull, reason: 'all libraries');
    expect(shownMode(tester), BrowseMode.readLists);
  });

  testWidgets('the remote reaches the link, and OK opens it', (tester) async {
    await start(tester, (api) => ReadListScreen(api: api, readList: {'id': 'RL1', 'name': 'Infinity'}));
    final link = tester.widget<InkWell>(find.byKey(parent));
    expect(link.canRequestFocus, isTrue);
    Focus.of(tester.element(find.descendant(of: find.byKey(parent), matching: find.text('Read lists'))))
        .requestFocus();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await settle(tester);
    expect(find.byType(LibraryScreen), findsOneWidget);
  });
}
