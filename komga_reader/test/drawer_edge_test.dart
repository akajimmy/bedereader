import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:komga_reader/widgets/drawer.dart';

import 'support/home_server.dart';
import 'support/no_network.dart';

void main() {
  testWidgets('Left from the leftmost item opens the side menu; Right closes it and returns focus', (tester) async {
    final scaffold = GlobalKey<ScaffoldState>();
    final edge = GlobalKey<DrawerEdgeState>();
    final a = FocusNode(debugLabel: 'A'), b = FocusNode(debugLabel: 'B');
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        key: scaffold,
        onDrawerChanged: (open) { if (!open) edge.currentState?.restore(); },
        drawer: AppDrawer(api: noNetwork(HomeServer.new), onSignOut: () {}),
        body: DrawerEdge(key: edge, scaffoldKey: scaffold, child: Row(children: [
          TextButton(focusNode: a, onPressed: () {}, child: const Text('A')),
          TextButton(focusNode: b, onPressed: () {}, child: const Text('B')),
        ])),
      ),
    ));
    b.requestFocus();
    await tester.pump();

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft); // B -> A, a normal move
    await tester.pumpAndSettle();
    expect(a.hasPrimaryFocus, isTrue);
    expect(scaffold.currentState!.isDrawerOpen, isFalse);

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft); // nothing left of A -> side menu
    await tester.pumpAndSettle();
    expect(scaffold.currentState!.isDrawerOpen, isTrue);
    expect(FocusManager.instance.primaryFocus?.context?.findAncestorWidgetOfExactType<Drawer>(), isNotNull);

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight); // close
    await tester.pumpAndSettle();
    expect(scaffold.currentState!.isDrawerOpen, isFalse);
    expect(a.hasPrimaryFocus, isTrue); // back where it was
  });

  testWidgets('a left-to-right swipe anywhere opens the side menu; a sideways row still scrolls', (tester) async {
    final scaffold = GlobalKey<ScaffoldState>();
    final row = ScrollController();
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        key: scaffold,
        drawer: AppDrawer(api: noNetwork(HomeServer.new), onSignOut: () {}),
        body: DrawerEdge(scaffoldKey: scaffold, child: Column(children: [
          SizedBox(height: 100, child: ListView(controller: row, scrollDirection: Axis.horizontal, children: [
            for (var i = 0; i < 20; i++) SizedBox(width: 100, child: Text('tile $i')),
          ])),
          const Expanded(child: Center(child: Text('page'))),
        ])),
      ),
    ));
    row.jumpTo(300);
    await tester.pump();
    await tester.fling(find.text('tile 4'), const Offset(250, 0), 1500); // on the row: scrolls it back
    await tester.pumpAndSettle();
    expect(scaffold.currentState!.isDrawerOpen, isFalse);
    expect(row.offset, lessThan(300));

    await tester.fling(find.text('page'), const Offset(250, 0), 1500); // in the middle of the page
    await tester.pumpAndSettle();
    expect(scaffold.currentState!.isDrawerOpen, isTrue);
  });
}

