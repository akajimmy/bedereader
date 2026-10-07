import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:komga_reader/api.dart';
import 'package:komga_reader/screens/actions.dart';
import 'package:komga_reader/screens/readlist.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:komga_reader/widgets/poster.dart';
import 'package:komga_reader/widgets/readlist_tile.dart';

import 'support/no_network.dart';

/// A 5-book read list: 2 unread, 1 in progress, 2 read.
class FakeKomga extends TestKomga {
  final status = {'a': 'UNREAD', 'b': 'READ', 'c': 'IN_PROGRESS', 'd': 'UNREAD', 'e': 'READ'};
  final readCalls = <String>[], unreadCalls = <String>[];

  @override
  Future<Map<String, dynamic>> readListBooks(String readListId, {List<String>? readStatus, int page = 0, int size = 1000}) async {
    final ids = status.entries.where((e) => readStatus == null || readStatus.contains(e.value)).map((e) => e.key).toList();
    return {
      'content': [
        for (final id in ids.take(size)) {'id': id, 'name': id, 'seriesTitle': 'S', 'metadata': {'number': id, 'title': 'T'}},
      ],
      'totalElements': ids.length,
      'last': true,
    };
  }

  @override
  Future<void> markRead(String bookId) async => readCalls.add(bookId);
  @override
  Future<void> markUnread(String bookId) async => unreadCalls.add(bookId);
}

void main() {
  final rl = {'id': 'RL', 'name': 'Civil War', 'bookIds': ['a', 'b', 'c', 'd', 'e']};

  Future<void> run(WidgetTester tester, Komga api, String action, {required bool confirm}) async {
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: Builder(builder: (context) => TextButton(
        onPressed: () => showReadListActions(context, api, rl, onChanged: () {}), child: const Text('go'))))));
    await tester.tap(find.text('go'));
    await tester.pumpAndSettle();
    await tester.tap(find.text(action));
    await tester.pumpAndSettle();
    await tester.tap(find.text(confirm ? (action.contains('unread') ? 'Mark unread' : 'Mark read') : 'Cancel'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
  }

  testWidgets('mark all read touches only the unfinished books', (tester) async {
    final api = noNetwork(FakeKomga.new);
    await run(tester, api, 'Mark all as read', confirm: true);
    expect(api.readCalls..sort(), ['a', 'c', 'd']);
    expect(find.text('3 books marked read'), findsOneWidget);
  });

  testWidgets('mark all unread touches only books with progress', (tester) async {
    final api = noNetwork(FakeKomga.new);
    await run(tester, api, 'Mark all as unread', confirm: true);
    expect(api.unreadCalls..sort(), ['b', 'c', 'e']);
  });

  testWidgets('cancel changes nothing', (tester) async {
    final api = noNetwork(FakeKomga.new);
    await run(tester, api, 'Mark all as unread', confirm: false);
    expect(api.unreadCalls, isEmpty);
    expect(api.readCalls, isEmpty);
  });

  testWidgets('read-list tile: books still to read - unread and in progress - from the lookup', (tester) async {
    // code review, 2026-09-30: in progress counts as not read yet, as everywhere else (a list whose last books were
    // in progress showed as read)
    ReadListTile.invalidate();
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: SizedBox(width: 150, height: 290,
        child: ReadListTile(api: noNetwork(FakeKomga.new), readList: rl, onOpen: () {})))));
    await tester.pump();
    expect(find.text('3 of 5 unread'), findsOneWidget); // a and d unread, c in progress
  });

  testWidgets('header count shows the total for the current filter, in a box left of Hide read',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    await tester.pumpWidget(MaterialApp(home: ReadListScreen(api: noNetwork(FakeKomga.new), readList: rl)));
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
    final api = noNetwork(() => _LongListKomga(unread: 520, read: 3)); // the action asks 500 at a time: two pages of unread
    await run(tester, api, 'Mark all as read', confirm: true);
    expect(api.asked, containsAll(['UNREAD p0', 'UNREAD p1']));
    expect(api.readCalls.toSet(), {for (var i = 0; i < 520; i++) 'u$i'});
    expect(api.readCalls, hasLength(520), reason: 'each once');
    expect(find.text('520 books marked read'), findsOneWidget);
  });

  testWidgets('the read list grid loads the next page when scrolled to the end', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final api = noNetwork(() => _LongListKomga(unread: 150, read: 0)); // the grid asks 100 at a time (Paged.pageSize)
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

/// A read list longer than one page: `unread` unread books (u0, u1...) then `read` read ones (r0...). Answers each
/// page as Komga does - `size` books from `page * size`, last only on the final page - and records what was asked.
class _LongListKomga extends TestKomga {
  _LongListKomga({required int unread, required int read}) {
    entries = [
      for (var i = 0; i < unread; i++) {'id': 'u$i', 'status': 'UNREAD'},
      for (var i = 0; i < read; i++) {'id': 'r$i', 'status': 'READ'},
    ];
  }
  late final List<Map<String, String>> entries;
  final asked = <String>[], readCalls = <String>[];

  @override
  Future<Map<String, dynamic>> readListBooks(String readListId, {List<String>? readStatus, int page = 0, int size = 1000}) async {
    asked.add('${readStatus?.join('+') ?? 'all'} p$page');
    final match = entries.where((b) => readStatus == null || readStatus.contains(b['status'])).toList();
    final from = page * size, to = (from + size).clamp(0, match.length);
    return {
      'content': [
        for (final b in match.sublist(from.clamp(0, match.length), to))
          {'id': b['id'], 'name': b['id'], 'seriesTitle': 'S', 'metadata': {'number': b['id'], 'title': 'T'},
            'media': {'pagesCount': 20}, 'readProgress': b['status'] == 'READ' ? {'completed': true, 'page': 20} : null},
      ],
      'totalElements': match.length,
      'last': to >= match.length,
    };
  }

  @override
  Future<void> markRead(String bookId) async => readCalls.add(bookId);
}

