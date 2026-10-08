import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:komga_reader/api.dart';
import 'package:komga_reader/screens/actions.dart';
import 'package:komga_reader/screens/readlist.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:komga_reader/widgets/poster.dart';
import 'package:komga_reader/widgets/readlist_tile.dart';

import 'support/no_network.dart';
import 'support/readlist_server.dart';

/// A 5-book read list: 2 unread (a, d), 1 in progress (c), 2 read (b, e).
ReadListServer fiveBooks() => noNetwork(() => ReadListServer(
    [listBook('a'), listBook('b', read: true), listBook('c', page: 5), listBook('d'), listBook('e', read: true)]));

/// A read list longer than one page: [unread] unread books (u0, u1...) then [read] read ones (r0...).
ReadListServer longList({required int unread, required int read}) => noNetwork(() => ReadListServer([
      for (var i = 0; i < unread; i++) listBook('u$i'),
      for (var i = 0; i < read; i++) listBook('r$i', read: true),
    ]));

void main() {
  final rl = {'id': 'RL', 'name': 'Civil War', 'bookIds': ['a', 'b', 'c', 'd', 'e']};

  Future<void> run(WidgetTester tester, Komga api, String action, {required bool confirm}) async {
    await tester.pumpWidget(MaterialApp(key: UniqueKey(), home: Scaffold(body: Builder(builder: (context) =>
        TextButton(onPressed: () => showReadListActions(context, api, rl, onChanged: () {}), child: const Text('go'))))));
    await tester.tap(find.text('go'));
    await tester.pumpAndSettle();
    await tester.tap(find.text(action));
    await tester.pumpAndSettle();
    await tester.tap(find.text(confirm ? (action.contains('unread') ? 'Mark unread' : 'Mark read') : 'Cancel'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
  }

  testWidgets('mark all read touches only the unfinished books, mark all unread only books with progress; cancel '
      'changes nothing', (tester) async {
    for (final (action, confirm, read, unread, says) in [
      ('Mark all as read', true, ['a', 'c', 'd'], <String>[], '3 books marked read'),
      ('Mark all as unread', true, <String>[], ['b', 'c', 'e'], '3 books marked unread'),
      ('Mark all as unread', false, <String>[], <String>[], null),
    ]) {
      final api = fiveBooks();
      await run(tester, api, action, confirm: confirm);
      final why = '$action, ${confirm ? 'confirmed' : 'cancelled'}';
      expect(api.readCalls..sort(), read, reason: why);
      expect(api.unreadCalls..sort(), unread, reason: why);
      if (says != null) expect(find.text(says), findsOneWidget, reason: why);
    }
  });

  testWidgets('read-list tile: books still to read - unread and in progress - from the lookup', (tester) async {
    // code review, 2026-09-30: in progress counts as not read yet, as everywhere else (a list whose last books were
    // in progress showed as read)
    ReadListTile.invalidate();
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: SizedBox(width: 150, height: 290,
        child: ReadListTile(api: fiveBooks(), readList: rl, onOpen: () {})))));
    await tester.pump();
    expect(find.text('3 of 5 unread'), findsOneWidget); // a and d unread, c in progress
  });

  testWidgets('header count shows the total for the current filter, in a box left of Hide read',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    await tester.pumpWidget(MaterialApp(home: ReadListScreen(api: fiveBooks(), readList: rl)));
    await tester.pump();
    await tester.pump();
    // the count read from the badge itself, not any "5" on screen (test audit, 2026-09-30)
    Finder badge(String n) => find.descendant(of: find.byType(CountBadge), matching: find.text(n));
    expect(badge('5'), findsOneWidget); // all 5 books
    await tester.tap(find.byTooltip('Showing all (hide read)'));
    await tester.pump();
    await tester.pump();
    expect(badge('3'), findsOneWidget); // 2 unread + 1 in progress
    expect(tester.getTopLeft(badge('3')).dx < tester.getTopLeft(find.byTooltip('Read hidden (hide unread)')).dx, isTrue);
  });

  // test audit, 2026-09-30: every fake answered in one page, so paging was never exercised
  testWidgets('mark all read reaches the books on every page of the list, not just the first', (tester) async {
    final api = longList(unread: 520, read: 3); // the action asks 500 at a time: two pages of unread
    await run(tester, api, 'Mark all as read', confirm: true);
    expect(api.asked, containsAll(['UNREAD p0', 'UNREAD p1']));
    expect(api.readCalls.toSet(), {for (var i = 0; i < 520; i++) 'u$i'});
    expect(api.readCalls, hasLength(520), reason: 'each once');
    expect(find.text('520 books marked read'), findsOneWidget);
  });

  testWidgets('the read list grid loads the next page when scrolled to the end', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final api = longList(unread: 150, read: 0); // the grid asks 100 at a time (Paged.pageSize)
    await tester.pumpWidget(MaterialApp(home: ReadListScreen(api: api,
        readList: {'id': 'RL', 'name': 'Long', 'bookIds': [for (var i = 0; i < 150; i++) 'u$i']})));
    await tester.pump();
    await tester.pump();
    expect(api.asked, ['all p0'], reason: 'one page until the grid nears its end');
    expect(find.descendant(of: find.byType(CountBadge), matching: find.text('150')), findsOneWidget); // server total
    final grid = find.descendant(of: find.byType(CustomScrollView), matching: find.byType(Scrollable));
    for (var i = 0; i < 20 && api.asked.length < 2; i++) { // scroll down until the grid asks, or well past the end
      await tester.drag(grid, const Offset(0, -600));
      await tester.pump();
    }
    expect(api.asked, ['all p0', 'all p1'], reason: 'nearing the end of page 0 loads page 1, once');
    await tester.scrollUntilVisible(find.text('150 shown'), 600, scrollable: grid);
    expect(find.text('S #u149'), findsOneWidget); // the last book, from the second page
  });
}
