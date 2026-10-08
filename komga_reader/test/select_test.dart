import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:komga_reader/screens/actions.dart';
import 'package:komga_reader/screens/readlist.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/no_network.dart';
import 'support/readlist_server.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('"already in that state" rules: in progress counts as not read, and as not unread', () {
    expect(needsChange(listBook('A'), read: true), isTrue);
    expect(needsChange(listBook('A'), read: false), isFalse); // unread already
    expect(needsChange(listBook('B', read: true), read: true), isFalse); // read already
    expect(needsChange(listBook('C', page: 5), read: true), isTrue);
    expect(needsChange(listBook('C', page: 5), read: false), isTrue); // clears its page
  });

  /// Read list of three: A unread, B read, C in progress.
  Future<ReadListServer> open(WidgetTester tester) async {
    final api = noNetwork(() => ReadListServer([listBook('A'), listBook('B', read: true), listBook('C', page: 5)]));
    await tester.pumpWidget(MaterialApp(home: ReadListScreen(api: api, readList: const {'id': 'RL', 'name': 'List', 'bookIds': []})));
    await tester.pump();
    await tester.pump();
    return api;
  }

  testWidgets('book menu: mark read / unread always offered - unread, read or in progress - plus select multiple',
      (tester) async {
    // test audit, 2026-09-30: "always" now covers every read state, not just the unread book
    await open(tester);
    for (final b in ['S #A', 'S #B', 'S #C']) { // unread, read, in progress
      await tester.longPress(find.text(b));
      await tester.pumpAndSettle();
      expect(find.text('Mark as read'), findsOneWidget, reason: b);
      expect(find.text('Mark as unread'), findsOneWidget, reason: b);
      expect(find.text('Select multiple'), findsOneWidget, reason: b);
      Navigator.of(tester.element(find.text('Mark as read'))).pop();
      await tester.pumpAndSettle();
    }
  });

  testWidgets('select multiple -> mark read touches only the books not yet read, then leaves selection', (tester) async {
    final api = await open(tester);
    await tester.tap(find.byTooltip('Select multiple'));
    await tester.pump();
    expect(find.text('Select books'), findsOneWidget);
    await tester.tap(find.byTooltip('Select all'));
    await tester.pump();
    expect(find.text('3 selected'), findsOneWidget);
    await tester.tap(find.text('S #A')); // untick A
    await tester.pump();
    expect(find.text('2 selected'), findsOneWidget);
    await tester.tap(find.byTooltip('Mark as read')); // B (read) and C (in progress)
    await tester.pump();
    await tester.pump();
    expect(api.readCalls, ['C']); // B already read: skipped
    expect(find.text('1 marked read (1 already read)'), findsOneWidget);
    expect(find.byTooltip('Select multiple'), findsOneWidget); // back to the normal top bar
    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets('long-press -> Select multiple starts with that book ticked; Back ends selecting, not the screen',
      (tester) async {
    await open(tester);
    await tester.longPress(find.text('S #C'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Select multiple')); // the menu scrolls on a short window
    await tester.pumpAndSettle();
    await tester.tap(find.text('Select multiple'));
    await tester.pumpAndSettle();
    expect(find.text('1 selected'), findsOneWidget);
    await tester.binding.handlePopRoute();
    await tester.pump();
    expect(find.text('1 selected'), findsNothing);
    expect(find.byType(ReadListScreen), findsOneWidget);
  });
}
