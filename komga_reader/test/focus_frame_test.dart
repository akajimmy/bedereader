import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:komga_reader/api.dart';
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
}
