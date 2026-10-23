// side menu (test audit, 2026-10-23: dock_test.dart, drawer_edge_test.dart, open_menu_key_test.dart folded in).
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:komga_reader/reader_keys.dart';
import 'package:komga_reader/screens/home.dart';
import 'package:komga_reader/side_menu.dart';
import 'package:komga_reader/widgets/drawer.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/helpers.dart';
import 'support/home_server.dart';
import 'support/no_network.dart';

void main() {
  group('dock', () {
    setUp(() => SharedPreferences.setMockInitialValues({}));
    tearDown(() => SideMenu.instance.pinned = false);

    Future<void> home(WidgetTester tester, Size size) async {
      setView(tester, size);
      await tester.pumpWidget(MaterialApp(home: HomeScreen(api: noNetwork(HomeServer.new), onSignOut: () {})));
      await tester.pump();
      await tester.pump();
    }

    testWidgets('wide screen: the pin keeps the menu open beside the page; unpinning slides it away', (tester) async {
      await home(tester, const Size(1280, 800));
      expect(find.text('Settings'), findsNothing); // slide-out menu, closed (Settings = a side-menu item)
      await tester.tap(find.byTooltip('Open navigation menu'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Keep the side menu open'));
      await tester.pumpAndSettle();
      expect(SideMenu.instance.pinned, isTrue);
      expect(find.text('Settings'), findsOneWidget); // docked, visible without opening
      expect(find.byTooltip('Open navigation menu'), findsNothing); // no menu button needed
      expect(tester.getTopLeft(find.text('Home').last).dx, greaterThanOrEqualTo(SideMenu.width)); // page shifted right
      expect((await SharedPreferences.getInstance()).getBool('sidemenu.pinned'), isTrue);

      await tester.tap(find.byTooltip('Let the side menu slide away'));
      await tester.pumpAndSettle();
      expect(find.text('Settings'), findsNothing);
      expect(find.byTooltip('Open navigation menu'), findsOneWidget);
    });

    testWidgets('narrow screen: never docked, and the pin button is hidden', (tester) async {
      SideMenu.instance.pinned = true; // pinned on a wide screen earlier
      await home(tester, const Size(600, 900));
      expect(find.text('Settings'), findsNothing);
      await tester.tap(find.byTooltip('Open navigation menu'));
      await tester.pumpAndSettle();
      expect(find.text('Settings'), findsOneWidget); // slides out as usual
      expect(find.byTooltip('Let the side menu slide away'), findsNothing);
      expect(find.byTooltip('Keep the side menu open'), findsNothing);
    });
  });

  group('drawer edge', () {
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
  });

  // The "Open the side menu" key (user, 2026-10-12: a key for it on Windows, none by default): Settings > Remote and
  // keys gives it one; it opens the side menu of the screen on top, or closes it - never while typing, or with a dialog
  // or the reader over that screen.
  group('open menu key', () {
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
  });
}
