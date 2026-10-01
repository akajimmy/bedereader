import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:komga_reader/api.dart';
import 'package:komga_reader/widgets/poster.dart';

/// The remote's OK on a poster: a press opens it, holding it opens its menu (like a long press or a right-click).
void main() {
  var opened = 0, menus = 0;

  // the guard's held key is app-wide (static): one test's unfinished press mustn't swallow the next test's keys
  // (test audit, 2026-09-30)
  setUp(HoldOkGuard.debugReset);
  tearDown(HoldOkGuard.debugReset);

  Future<void> tile(WidgetTester tester, {bool withMenu = true}) async {
    opened = menus = 0;
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: SizedBox(width: 170, height: 330, child: PosterTile(
      api: Komga('http://test', 'k'),
      imageUrl: '',
      image: const ColoredBox(color: Colors.grey), // no network in tests
      title: 'Planet Comics',
      autofocus: true,
      onOpen: () => opened++,
      onMenu: withMenu ? () => menus++ : null,
    )))));
    await tester.pump();
  }

  testWidgets('a press of OK opens the tile; holding it opens the menu instead', (tester) async {
    await tile(tester);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.enter);
    await tester.pump(const Duration(milliseconds: 150));
    await tester.sendKeyUpEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    expect([opened, menus], [1, 0]);

    await tester.sendKeyDownEvent(LogicalKeyboardKey.select); // the remote's OK
    await tester.pump(const Duration(milliseconds: 600));
    expect([opened, menus], [1, 1]); // the menu, while still held
    await tester.sendKeyUpEvent(LogicalKeyboardKey.select);
    await tester.pump();
    expect([opened, menus], [1, 1]); // letting go after a hold opens nothing
  });

  testWidgets("held on: the key's repeats and release don't press the menu's first item (tablet, build 55)",
      (tester) async {
    // the real menu: a sheet whose first entry takes focus - on the tablet, holding OK opened Details at once
    var details = 0;
    await tester.pumpWidget(MaterialApp(
      builder: (context, child) => HoldOkGuard(child: child!), // as in main.dart
      home: Scaffold(body: Builder(builder: (context) => SizedBox(width: 170, height: 330, child: PosterTile(
        api: Komga('http://test', 'k'),
        imageUrl: '',
        image: const ColoredBox(color: Colors.grey),
        title: 'Planet Comics',
        autofocus: true,
        onOpen: () {},
        onMenu: () => showModalBottomSheet<void>(context: context, builder: (_) => ListTile(
            autofocus: true, title: const Text('Details'), onTap: () => details++)),
      )))),
    ));
    await tester.pump();
    await tester.sendKeyDownEvent(LogicalKeyboardKey.select);
    await tester.pump(const Duration(milliseconds: 600)); // held: the menu opens
    await tester.pumpAndSettle();
    expect(find.text('Details'), findsOneWidget);
    for (var i = 0; i < 5; i++) { // Android keeps sending repeats while it's held
      await tester.sendKeyRepeatEvent(LogicalKeyboardKey.select);
      await tester.pump(const Duration(milliseconds: 50));
    }
    await tester.sendKeyUpEvent(LogicalKeyboardKey.select);
    await tester.pumpAndSettle();
    expect(details, 0, reason: 'the held press is spent on opening the menu');
    expect(find.text('Details'), findsOneWidget); // the menu stays open

    await tester.sendKeyEvent(LogicalKeyboardKey.select); // a fresh press in the menu works
    await tester.pumpAndSettle();
    expect(details, 1);
  });

  testWidgets('a tile without a menu opens on OK as before', (tester) async {
    await tile(tester, withMenu: false);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    expect(opened, 1);
  });
}
