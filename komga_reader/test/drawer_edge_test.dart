import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:komga_reader/api.dart';
import 'package:komga_reader/widgets/drawer.dart';

class FakeKomga extends Komga {
  FakeKomga() : super('http://test', 'k');
  @override
  Future<List<dynamic>> libraries() async => [{'id': 'L1', 'name': 'Events'}];
}

void main() {
  testWidgets('Left from the leftmost item opens the side menu; Right closes it and returns focus', (tester) async {
    final scaffold = GlobalKey<ScaffoldState>();
    final edge = GlobalKey<DrawerEdgeState>();
    final a = FocusNode(debugLabel: 'A'), b = FocusNode(debugLabel: 'B');
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        key: scaffold,
        onDrawerChanged: (open) { if (!open) edge.currentState?.restore(); },
        drawer: AppDrawer(api: FakeKomga(), onSignOut: () {}),
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
}
