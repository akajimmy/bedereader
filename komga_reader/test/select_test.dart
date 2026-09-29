import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:komga_reader/api.dart';
import 'package:komga_reader/screens/actions.dart';
import 'package:komga_reader/screens/readlist.dart';
import 'package:shared_preferences/shared_preferences.dart';

Map<String, dynamic> book(String id, {bool read = false, int? page}) => {
      'id': id, 'seriesTitle': 'S', 'name': id, 'metadata': {'number': id, 'title': 'T$id'},
      'media': {'pagesCount': 20},
      'readProgress': read ? {'completed': true, 'page': 20} : page != null ? {'completed': false, 'page': page} : null,
    };

/// Read list of three: A unread, B read, C in progress.
class FakeKomga extends Komga {
  FakeKomga() : super('http://test', 'k');
  final list = [book('A'), book('B', read: true), book('C', page: 5)];
  final marked = <String>[], unmarked = <String>[];
  @override
  Future<Map<String, dynamic>> readListBooks(String readListId, {List<String>? readStatus, int page = 0, int size = 1000}) async =>
      {'content': list, 'totalElements': list.length, 'last': true};
  @override
  Future<void> markRead(String bookId) async => marked.add(bookId);
  @override
  Future<void> markUnread(String bookId) async => unmarked.add(bookId);
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('"already in that state" rules: in progress counts as not read, and as not unread', () {
    expect(needsChange(book('A'), read: true), isTrue);
    expect(needsChange(book('A'), read: false), isFalse); // unread already
    expect(needsChange(book('B', read: true), read: true), isFalse); // read already
    expect(needsChange(book('C', page: 5), read: true), isTrue);
    expect(needsChange(book('C', page: 5), read: false), isTrue); // clears its page
  });

  Future<FakeKomga> open(WidgetTester tester) async {
    final api = FakeKomga();
    await tester.pumpWidget(MaterialApp(home: ReadListScreen(api: api, readList: const {'id': 'RL', 'name': 'List', 'bookIds': []})));
    await tester.pump();
    await tester.pump();
    return api;
  }

  testWidgets('book menu: mark as read and mark as unread always offered, no "clear progress", plus select multiple',
      (tester) async {
    await open(tester);
    await tester.longPress(find.text('S #A'));
    await tester.pumpAndSettle();
    expect(find.text('Mark as read'), findsOneWidget);
    expect(find.text('Mark as unread'), findsOneWidget);
    expect(find.textContaining('Clear progress'), findsNothing);
    expect(find.text('Select multiple'), findsOneWidget);
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
    expect(api.marked, ['C']); // B already read: skipped
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
