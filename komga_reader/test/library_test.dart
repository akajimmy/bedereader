import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:komga_reader/screens/library.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/browse_server.dart';
import 'support/helpers.dart';
import 'support/no_network.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  Future<BrowseServer> open(WidgetTester tester, {BrowseServer? server}) async {
    final api = server ?? noNetwork(BrowseServer.new);
    setView(tester, const Size(1280, 900));
    await tester.pumpWidget(MaterialApp(home: LibraryScreen(key: UniqueKey(), api: api, onSignOut: () {},
        libraryId: 'L1')));
    await tester.pump();
    await tester.pump();
    return api;
  }

  Future<void> mode(WidgetTester tester, String label) async {
    await tester.tap(find.widgetWithText(ChoiceChip, label));
    await tester.pump();
    await tester.pump();
  }

  // ---- modes, filter, paging (test audit, 2026-09-30: only the sort menu had a test)

  testWidgets('the four ways to browse: each chip lists its own kind, and the library opens the way it was left',
      (tester) async {
    final api = await open(tester);
    expect(api.requests.last, 'series p0 all'); // Series, the first time
    expect(find.text('Series 1'), findsOneWidget);
    expect(find.text('Saga #1'), findsNothing);

    await mode(tester, 'Books');
    expect(api.requests.last, 'books p0 all');
    expect(find.text('Saga #1'), findsOneWidget);
    expect(find.text('Series 1'), findsNothing);

    await mode(tester, 'Collections');
    expect(api.requests.last, 'collections p0');
    expect(find.text('Marvel cosmic'), findsOneWidget);
    expect(find.byTooltip('Hide read'), findsNothing, reason: 'no read filter for collections');

    await mode(tester, 'Read lists');
    expect(api.requests.last, 'readLists p0');
    expect(find.text('Infinity'), findsOneWidget);

    await mode(tester, 'Books');
    final saved = jsonDecode((await SharedPreferences.getInstance()).getString('view.library.L1')!) as Map;
    expect(saved['mode'], 'books');
    final again = await open(tester); // next time
    expect(again.requests, ['books p0 all']);
    expect(tester.widget<ChoiceChip>(find.widgetWithText(ChoiceChip, 'Books')).selected, isTrue);
  });

  testWidgets('Hide read asks Komga for unread and in-progress only, and the grid and its count narrow to them; '
      'again shows everything', (tester) async {
    final api = await open(tester);
    await mode(tester, 'Books');
    expect(find.text('Saga #1'), findsOneWidget);
    expect(find.text('3'), findsOneWidget); // the count beside the filter

    await tester.tap(find.byTooltip('Hide read'));
    await tester.pump();
    await tester.pump();
    expect(api.requests.last, 'books p0 UNREAD+IN_PROGRESS');
    expect(find.text('Saga #1'), findsNothing, reason: 'B1 is read');
    expect(find.text('Saga #2'), findsOneWidget);
    expect(find.text('Saga #3'), findsOneWidget, reason: 'in progress is not read');
    expect(find.text('2'), findsOneWidget);
    expect(find.byTooltip('Clear filters'), findsOneWidget);

    await tester.tap(find.byTooltip('Read hidden (show read)'));
    await tester.pump();
    await tester.pump();
    expect(api.requests.last, 'books p0 all');
    expect(find.text('Saga #1'), findsOneWidget);
  });

  testWidgets('a big library: the first page only, then the next one once the grid is scrolled near its end',
      (tester) async {
    final api = await open(tester, server: noNetwork(() => BrowseServer(seriesCount: 150))); // pages of 100
    expect(api.requests, ['series p0 all'], reason: 'one page to start with');
    expect(find.text('150'), findsOneWidget); // Komga's total, before the rest is loaded
    final grid = find.byType(CustomScrollView);
    await tester.drag(grid, const Offset(0, -3000));
    await tester.pumpAndSettle();
    expect(api.requests, ['series p0 all', 'series p1 all']);
    for (var i = 0; i < 10 && !shows(find.text('150 shown')); i++) {
      await tester.drag(grid, const Offset(0, -3000));
      await tester.pumpAndSettle();
    }
    expect(find.text('Series 150'), findsOneWidget);
    expect(find.text('150 shown'), findsOneWidget, reason: 'the end: no third page');
    expect(api.requests.length, 2);
  });

  testWidgets('a big library by remote: Down through the grid loads the next page before the end', (tester) async {
    final api = await open(tester, server: noNetwork(() => BrowseServer(seriesCount: 150)));
    expect(FocusManager.instance.primaryFocus?.context?.findAncestorWidgetOfExactType<InkWell>(), isNotNull,
        reason: 'the first poster has the focus');
    Future<void> down() async {
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300)); // scrolled to the focused row (spinners never settle)
    }

    var downs = 0;
    for (; downs < 20 && api.requests.length < 2; downs++) {
      await down();
    }
    expect(api.requests, ['series p0 all', 'series p1 all']);
    // 7 Downs here; asking only once the last poster is built would take 11 (8 posters a row, 100 in the page)
    expect(downs, lessThanOrEqualTo(8), reason: 'asked for about 30 posters (4 rows) before the end');
    for (var i = 0; i < 10 && !shows(find.text('Series 101')); i++) {
      await down(); // and on into it
    }
    expect(find.text('Series 101'), findsOneWidget);
  });

  // ---- deleting (test audit, 2026-09-30: Cancel, bulk and a partial failure had no test)

  Future<void> bookMenu(WidgetTester tester, String book) async {
    await tester.longPress(find.text(book));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Delete book…')); // the menu scrolls on a short window
    await tester.pumpAndSettle();
    await tester.tap(find.text('Delete book…'));
    await tester.pumpAndSettle();
  }

  testWidgets('delete one book: asks first, Cancel (focused) deletes nothing; Delete deletes that book and it leaves '
      'the grid', (tester) async {
    final api = await open(tester);
    await mode(tester, 'Books');
    await bookMenu(tester, 'Saga #2');
    expect(find.text('Delete "Saga #2"?'), findsOneWidget);
    final cancel = find.widgetWithText(TextButton, 'Cancel');
    expect(tester.widget<TextButton>(cancel).autofocus, isTrue, reason: 'an OK pressed by mistake cancels');
    await tester.tap(cancel);
    await tester.pumpAndSettle();
    expect(api.deleted, isEmpty);
    expect(find.text('Saga #2'), findsOneWidget);

    await bookMenu(tester, 'Saga #2');
    await tester.tap(find.widgetWithText(TextButton, 'Delete'));
    await tester.pumpAndSettle();
    expect(api.deleted, ['B2']);
    expect(find.text('Saga #2'), findsNothing, reason: 'the grid reloaded');
    expect(find.text('Saga #1'), findsOneWidget);
  });

  Future<void> selectAndDelete(WidgetTester tester, List<String> books, {required bool confirm}) async {
    await tester.tap(find.byTooltip('Select multiple'));
    await tester.pump();
    for (final b in books) {
      await tester.tap(find.text(b));
      await tester.pump();
    }
    expect(find.text('${books.length} selected'), findsOneWidget);
    await tester.tap(find.byTooltip('Delete…'));
    await tester.pumpAndSettle();
    expect(find.text('Delete ${books.length} books?'), findsOneWidget);
    await tester.tap(find.widgetWithText(TextButton, confirm ? 'Delete' : 'Cancel'));
    await tester.pumpAndSettle();
  }

  testWidgets('delete several (selected): Cancel deletes nothing and keeps the selection; Delete deletes those, in '
      'the order picked, says how many, and the grid reloads', (tester) async {
    final api = await open(tester);
    await mode(tester, 'Books');
    await selectAndDelete(tester, ['Saga #3', 'Saga #1'], confirm: false);
    expect(api.deleted, isEmpty);
    expect(find.text('2 selected'), findsOneWidget, reason: 'still selecting');

    await tester.tap(find.byTooltip('Stop selecting'));
    await tester.pump();
    await selectAndDelete(tester, ['Saga #3', 'Saga #1'], confirm: true);
    expect(api.deleted, ['B3', 'B1']);
    expect(find.text('Deleted 2 books'), findsOneWidget);
    expect(find.text('Saga #1'), findsNothing);
    expect(find.text('Saga #3'), findsNothing);
    expect(find.text('Saga #2'), findsOneWidget, reason: 'not selected: kept');
    expect(find.byTooltip('Select multiple'), findsOneWidget, reason: 'selecting ended');
    await tester.pump(const Duration(seconds: 5)); // the message
  });

  testWidgets('delete several, one refused by Komga: the ones before it are deleted, it says how far it got and why '
      'it stopped, and the refused one and those after it stay', (tester) async {
    final api = await open(tester);
    api.failing.add('B2');
    await mode(tester, 'Books');
    await selectAndDelete(tester, ['Saga #1', 'Saga #2', 'Saga #3'], confirm: true);
    expect(api.deleted, ['B1'], reason: 'B2 refused; B3 not tried after it');
    expect(find.textContaining('Deleted 1 of 3, then stopped'), findsOneWidget);
    expect(find.textContaining('admin'), findsOneWidget, reason: 'why: deleting needs an admin account');
    expect(find.text('Saga #1'), findsNothing);
    expect(find.text('Saga #2'), findsOneWidget);
    expect(find.text('Saga #3'), findsOneWidget);
    await tester.pump(const Duration(seconds: 7)); // the message
  });
}
