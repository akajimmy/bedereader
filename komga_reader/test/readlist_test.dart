import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:komga_reader/api.dart';
import 'package:komga_reader/screens/actions.dart';
import 'package:komga_reader/screens/readlist.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:komga_reader/widgets/readlist_tile.dart';

/// A 5-book read list: 2 unread, 1 in progress, 2 read.
class FakeKomga extends Komga {
  FakeKomga() : super('http://test', 'k');
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

  Future<void> run(WidgetTester tester, FakeKomga api, String action, {required bool confirm}) async {
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
    final api = FakeKomga();
    await run(tester, api, 'Mark all as read', confirm: true);
    expect(api.readCalls..sort(), ['a', 'c', 'd']);
    expect(find.text('3 books marked read'), findsOneWidget);
  });

  testWidgets('mark all unread touches only books with progress', (tester) async {
    final api = FakeKomga();
    await run(tester, api, 'Mark all as unread', confirm: true);
    expect(api.unreadCalls..sort(), ['b', 'c', 'e']);
  });

  testWidgets('cancel changes nothing', (tester) async {
    final api = FakeKomga();
    await run(tester, api, 'Mark all as unread', confirm: false);
    expect(api.unreadCalls, isEmpty);
    expect(api.readCalls, isEmpty);
  });

  testWidgets('read-list tile: books still to read - unread and in progress - from the lookup', (tester) async {
    // code review, 2026-09-30: in progress counts as not read yet, as everywhere else (a list whose last books were
    // in progress showed as read)
    ReadListTile.invalidate();
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: SizedBox(width: 150, height: 290,
        child: ReadListTile(api: FakeKomga(), readList: rl, onOpen: () {})))));
    await tester.pump();
    expect(find.text('3 of 5 unread'), findsOneWidget); // a and d unread, c in progress
  });

  testWidgets('header count shows the total for the current filter, in a box left of Hide read',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    await tester.pumpWidget(MaterialApp(home: ReadListScreen(api: FakeKomga(), readList: rl)));
    await tester.pump();
    await tester.pump();
    expect(find.text('5'), findsOneWidget); // all 5 books
    await tester.tap(find.byTooltip('Hide read'));
    await tester.pump();
    await tester.pump();
    expect(find.text('3'), findsOneWidget); // 2 unread + 1 in progress
    expect(tester.getTopLeft(find.text('3')).dx < tester.getTopLeft(find.byTooltip('Read hidden (show read)')).dx, isTrue);
  });
}

