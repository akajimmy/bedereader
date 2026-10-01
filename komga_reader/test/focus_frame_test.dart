import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:komga_reader/api.dart';
import 'package:komga_reader/widgets/focus_style.dart';
import 'package:komga_reader/widgets/poster.dart';

void main() {
  /// Whether a tile's focus outline is drawn (whichever tile has focus: an arrow key can move it on).
  bool outlined(WidgetTester tester) {
    final frames = tester.widgetList<AnimatedContainer>(find.byType(AnimatedContainer)).where((box) =>
        box.decoration is BoxDecoration && (box.decoration as BoxDecoration).border is Border);
    expect(frames, isNotEmpty);
    return frames.any((box) => ((box.decoration as BoxDecoration).border as Border).top.color != Colors.transparent);
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
    // (Windows comes from the variant, which puts the platform back itself; the highlight strategy is put back in a
    // tear-down, so a failing check can't leave it set for the other tests - test audit, 2026-09-30)
    addTearDown(() => FocusManager.instance.highlightStrategy = FocusHighlightStrategy.automatic);
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
    expect(outlined(tester), isTrue); // and the tile shows it

    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: tester.getCenter(find.text('Book 0')));
    await mouse.down(tester.getCenter(find.text('Book 0')));
    await mouse.up();
    await tester.pump(const Duration(milliseconds: 200));
    expect(outlined(tester), isFalse); // clicked: plain again
    await mouse.removePointer();
  },variant: TargetPlatformVariant.only(TargetPlatform.windows));

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
