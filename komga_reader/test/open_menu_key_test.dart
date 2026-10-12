// The "Open the side menu" key (user, 2026-10-12: a key for it on Windows, none by default): Settings > Remote and
// keys gives it one; it opens the side menu of the screen on top, or closes it - never while typing, or with a dialog
// or the reader over that screen.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:komga_reader/reader_keys.dart';
import 'package:komga_reader/widgets/drawer.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await ReaderKeys.instance.load();
  });

  test('no key by default; a save from before the key existed keeps it without one', () async {
    expect(ReaderKeys.instance.keys[ReaderAction.openMenu], isEmpty);
    SharedPreferences.setMockInitialValues({'reader.keys': '{"close": [${LogicalKeyboardKey.escape.keyId}]}'});
    await ReaderKeys.instance.load();
    expect(ReaderKeys.instance.keys[ReaderAction.openMenu], isEmpty);
    await ReaderKeys.instance.assign(ReaderAction.openMenu, LogicalKeyboardKey.f2);
    expect(ReaderKeys.instance.actionFor(LogicalKeyboardKey.f2), ReaderAction.openMenu);
  });

  /// A screen with the side menu, its body a text box.
  Widget screen() {
    final scaffold = GlobalKey<ScaffoldState>();
    return Scaffold(
      key: scaffold,
      drawer: const Drawer(child: Text('the side menu')),
      body: DrawerEdge(scaffoldKey: scaffold, child: const Center(child: SizedBox(width: 200, child: TextField()))),
    );
  }

  testWidgets('the key opens the side menu of the screen on top, and closes it again', (tester) async {
    await tester.pumpWidget(MaterialApp(home: screen()));
    expect(DrawerEdgeState.toggleOnTop(), isTrue);
    await tester.pumpAndSettle();
    expect(find.text('the side menu'), findsOneWidget);
    expect(DrawerEdgeState.toggleOnTop(), isTrue);
    await tester.pumpAndSettle();
    expect(find.text('the side menu'), findsNothing);
  });

  testWidgets('nothing while typing in a text box, with a dialog over the screen, or with a screen without a side '
      'menu (the reader) on top', (tester) async {
    await tester.pumpWidget(MaterialApp(home: screen()));
    await tester.tap(find.byType(TextField));
    await tester.pump();
    expect(DrawerEdgeState.toggleOnTop(), isFalse, reason: 'typing: the key is a letter');
    await tester.pumpAndSettle();
    expect(find.text('the side menu'), findsNothing);
    FocusManager.instance.primaryFocus?.unfocus();
    await tester.pump();

    final context = tester.element(find.byType(TextField));
    unawaited(showDialog<void>(context: context, builder: (_) => const AlertDialog(content: Text('a dialog'))));
    await tester.pumpAndSettle();
    expect(DrawerEdgeState.toggleOnTop(), isFalse, reason: 'a dialog over it');
    Navigator.of(tester.element(find.text('a dialog'))).pop();
    await tester.pumpAndSettle();

    unawaited(Navigator.of(context)
        .push(MaterialPageRoute<void>(builder: (_) => const Scaffold(body: Text('the reader')))));
    await tester.pumpAndSettle();
    expect(DrawerEdgeState.toggleOnTop(), isFalse, reason: 'no side menu on the screen on top');
  });
}
