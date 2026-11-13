import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:komga_reader/reader/reader_bars.dart';
import 'package:komga_reader/screens/readlist.dart';
import 'package:komga_reader/screens/search.dart';
import 'package:komga_reader/settings.dart';
import 'package:komga_reader/widgets/breadcrumb.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/helpers.dart';
import 'support/no_network.dart';
import 'support/readlist_server.dart';

// The phone-width round (user, 2026-11-13, for the App Store): screens at an iPhone's width fit - an overflow fails
// the test by itself - and what a narrow bar folds away is still there.

/// An iPhone 17 (402 x 874), and the narrowest still about (375).
const phone = Size(402, 874), smallPhone = Size(375, 667);

void main() {
  final rl = {'id': 'RL', 'name': 'Civil War: the complete event, in reading order', 'bookIds': ['a', 'b']};
  ReadListServer twoBooks() => noNetwork(() => ReadListServer([listBook('a'), listBook('b', read: true)]));

  setUp(() => SharedPreferences.setMockInitialValues({}));
  tearDown(() => AppSettings.instance.setDisplay(const DisplayPrefs()));

  for (final size in [phone, smallPhone]) {
    testWidgets('a read list at ${size.width.round()} wide: the bar fits, and its ⋮ holds Select, Pin, Refresh, the '
        "list's actions and the poster sizes", (tester) async {
      setView(tester, size);
      await tester.pumpWidget(MaterialApp(home: ReadListScreen(api: twoBooks(), readList: rl)));
      await tester.pump();
      await tester.pump();
      expect(find.byKey(const ValueKey('bar.pin')), findsNothing, reason: 'folded into the menu');
      expect(find.byKey(const ValueKey('bar.eye')), findsOneWidget, reason: 'the eye stays in the bar');

      await tester.tap(find.byKey(const ValueKey('bar.menu')));
      await tester.pumpAndSettle();
      for (final k in ['select', 'pin', 'refresh', 'more', 'size.small', 'size.medium', 'size.large']) {
        expect(find.byKey(ValueKey('menu.$k')), findsOneWidget, reason: k);
      }
      await tester.tap(find.byKey(const ValueKey('menu.size.large')));
      await tester.pumpAndSettle();
      expect(AppSettings.instance.display.posterSize, PosterSize.large);

      await tester.tap(find.byKey(const ValueKey('bar.menu')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('menu.select')));
      await tester.pumpAndSettle();
      expect(find.byTooltip('Stop selecting'), findsOneWidget, reason: 'selecting');
    });
  }

  testWidgets('on a tablet the read list keeps its own buttons and has no folded menu', (tester) async {
    setView(tester, const Size(1024, 768));
    await tester.pumpWidget(MaterialApp(home: ReadListScreen(api: twoBooks(), readList: rl)));
    await tester.pump();
    expect(find.byKey(const ValueKey('bar.pin')), findsOneWidget);
    expect(find.byKey(const ValueKey('bar.menu')), findsNothing);
  });

  testWidgets('a title with its parent ("Events › Saga") shows the title alone where there is no room for both',
      (tester) async {
    Future<void> at(double width) => tester.pumpWidget(MaterialApp(home: Material(child: Center(
        child: SizedBox(width: width, child: Breadcrumb(parent: 'Events', title: 'Saga', onParent: () {}))))));
    await at(120);
    expect(find.text('Saga'), findsOneWidget);
    expect(find.text('Events'), findsNothing);
    await at(400);
    expect(find.text('Events'), findsOneWidget);
    expect(find.text('Saga'), findsOneWidget);
  });

  testWidgets("the reader's top bar fits a phone with six buttons: Close is its arrow, and still closes",
      (tester) async {
    setView(tester, smallPhone);
    var closed = 0;
    final node = FocusNode();
    addTearDown(node.dispose);
    final buttons = [
      for (var i = 0; i < 6; i++) IconButton(onPressed: () {}, icon: const Icon(Icons.star)),
    ];
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: ReaderTopBar(closeNode: node, heading: 'Saga',
        title: 'Chapter One: the long way round', buttons: buttons, onClose: () => closed++))));
    expect(find.text('Close'), findsNothing, reason: 'no label');
    await tester.tap(find.byTooltip('Close'));
    expect(closed, 1);
  });

  testWidgets('Search from a library with a long name fits a phone: the chip shortens', (tester) async {
    setView(tester, smallPhone);
    await tester.pumpWidget(MaterialApp(home: SearchScreen(api: noNetwork(TestKomga.new), libraryId: 'L1',
        libraryName: 'Marvel and DC events, crossovers and tie-ins')));
    await tester.pump();
    expect(find.text('All libraries'), findsOneWidget);
  });
}
