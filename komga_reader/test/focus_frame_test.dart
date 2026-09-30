import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:komga_reader/api.dart';
import 'package:komga_reader/widgets/focus_style.dart';
import 'package:komga_reader/widgets/poster.dart';

void main() {
  bool outlined(WidgetTester tester) {
    final box = tester.widget<AnimatedContainer>(find.byType(AnimatedContainer).first);
    final border = (box.decoration as BoxDecoration).border as Border;
    return border.top.color != Colors.transparent;
  }

  testWidgets('first tile has focus but no outline until an arrow key is pressed; touch hides it again', (tester) async {
    final api = Komga('http://test', 'k');
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Row(children: [
          for (var i = 0; i < 2; i++)
            SizedBox(width: 150, height: 290,
                child: PosterTile(api: api, imageUrl: 'http://test/$i', title: 'Book $i', autofocus: i == 0, onOpen: () {})),
        ]),
      ),
    ));
    FocusManager.instance.highlightStrategy = FocusHighlightStrategy.automatic;
    await tester.tap(find.text('Book 1')); // a touch, as on the tablet
    await tester.pump();
    expect(outlined(tester), isFalse);

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    await tester.pump(const Duration(milliseconds: 200));
    expect(outlined(tester), isTrue);

    await tester.tap(find.text('Book 1'));
    await tester.pump(const Duration(milliseconds: 200));
    expect(outlined(tester), isFalse);
  });

  testWidgets('Windows: no highlight on start-up; arrows show it, a mouse click hides it again', (tester) async {
    // the bug: on Windows the first Continue reading book showed highlighted as soon as the app opened
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    focusHighlightFollowsInput(); // what main() does
    final api = Komga('http://test', 'k');
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Row(children: [
          for (var i = 0; i < 2; i++)
            SizedBox(width: 150, height: 290,
                child: PosterTile(api: api, imageUrl: 'http://test/$i', title: 'Book $i', autofocus: i == 0, onOpen: () {})),
        ]),
      ),
    ));
    await tester.pump(const Duration(milliseconds: 200));
    expect(FocusManager.instance.primaryFocus?.context?.widget, isNotNull); // the first tile has focus...
    expect(outlined(tester), isFalse); // ...but no highlight until the keyboard is used

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pump(const Duration(milliseconds: 200));
    expect(FocusManager.instance.highlightMode, FocusHighlightMode.traditional);

    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: tester.getCenter(find.text('Book 0')));
    await mouse.down(tester.getCenter(find.text('Book 0')));
    await mouse.up();
    await tester.pump(const Duration(milliseconds: 200));
    expect(outlined(tester), isFalse); // clicked: plain again
    await mouse.removePointer();
    FocusManager.instance.highlightStrategy = FocusHighlightStrategy.automatic; // leave the default for other tests
    debugDefaultTargetPlatformOverride = null; // (inside the test: Flutter checks it before tear-downs run)
  });

  testWidgets('right-click on a tile opens its menu, like a long-press', (tester) async {
    var menus = 0;
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: SizedBox(width: 150, height: 290,
        child: PosterTile(api: Komga('http://test', 'k'), imageUrl: 'http://test/x', title: 'T', onOpen: () {},
            onMenu: () => menus++)))));
    await tester.tap(find.text('T'), buttons: kSecondaryButton);
    await tester.pump();
    expect(menus, 1);
  });
}
