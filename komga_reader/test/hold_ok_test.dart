import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:komga_reader/api.dart';
import 'package:komga_reader/widgets/poster.dart';

/// The remote's OK on a poster: a press opens it, holding it opens its menu (like a long press or a right-click).
void main() {
  var opened = 0, menus = 0;

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

  testWidgets('a tile without a menu opens on OK as before', (tester) async {
    await tile(tester, withMenu: false);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    expect(opened, 1);
  });
}
