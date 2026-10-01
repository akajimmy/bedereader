import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:komga_reader/widgets/setting_rows.dart';

/// The shared setting rows (widgets/setting_rows.dart): how they look and how they lay out. Moved here from
/// row_nav_test, which is about Up / Down only (test audit, 2026-09-30).
void main() {
  testWidgets('disabled (following the defaults), the choice in force is still highlighted', (tester) async {
    await tester.pumpWidget(MaterialApp(theme: ThemeData(colorScheme: const ColorScheme.dark(primary: Colors.blue)),
        home: Scaffold(body: SettingsGroup(children: [
          SegmentRow<int>(title: 'Fit', value: 2, enabled: false, onChanged: (_) {},
              choices: const [Choice(1, 'Screen'), Choice(2, 'Width'), Choice(3, 'Height')]),
        ]))));
    final b = tester.widget<SegmentedButton<int>>(find.byType(SegmentedButton<int>));
    expect(b.onSelectionChanged, isNull); // disabled
    final bg = b.style!.backgroundColor!.resolve({WidgetState.selected, WidgetState.disabled});
    expect(bg, isNotNull);
    expect(bg!.a, greaterThan(0.2)); // a dimmed accent, not nothing
    expect(b.style!.backgroundColor!.resolve({WidgetState.disabled}), isNull); // the others as usual
  });

  testWidgets('alignment: choices beside their labels share one width, flush right; one under its label spans the row',
      (tester) async {
    tester.view.physicalSize = const Size(700, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    // six choices long enough not to fit beside their label at 700 px in any font - not only in the test font, which
    // is about twice as wide as a real one (test audit, 2026-09-30)
    const long = [
      Choice(1, 'the first of the choices'), Choice(2, 'the second of the choices'),
      Choice(3, 'the third of the choices'), Choice(4, 'the fourth of the choices'),
      Choice(5, 'the fifth of the choices'), Choice(6, 'the sixth of the choices'),
    ];
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: SettingsColumn(child: ListView(children: [
      SettingsGroup(children: [
        SegmentRow<int>(title: 'A', value: 1, onChanged: (_) {}, choices: const [Choice(1, 'x'), Choice(2, 'y')]),
        SegmentRow<int>(title: 'B', value: 1, onChanged: (_) {},
            choices: const [Choice(1, 'aaaa'), Choice(2, 'bbbb'), Choice(3, 'cccc')]),
        SegmentRow<int>(title: 'Keep it', value: 1, onChanged: (_) {}, choices: long),
      ]),
    ])))));
    await tester.pump();
    await tester.pump(); // the shared width settles after the first frame
    final row = tester.getRect(find.byType(SettingsGroup));
    // the premise, measured in the font in use (SegmentRow's own sum): the long row has no room beside its label
    final ctx = tester.element(find.text('Keep it'));
    final widest = [for (final c in long) textWidth(ctx, c.label, 13)].reduce((a, b) => a > b ? a : b);
    final own = long.length * (widest + 28);
    expect(row.width - 28 - own, lessThan(textWidth(ctx, 'Keep it', 14.5) + 12), reason: 'too wide to sit beside');

    final buttons = find.byType(SegmentedButton<int>);
    final a = tester.getRect(buttons.at(0)), b = tester.getRect(buttons.at(1)), c = tester.getRect(buttons.at(2));
    expect(a.width, closeTo(b.width, 0.5), reason: "the long one under its label doesn't widen the column");
    expect(a.right, closeTo(b.right, 0.5));
    expect(a.right, closeTo(row.right - 14, 1)); // flush with the row's right edge, inside its padding
    expect(c.top, greaterThan(tester.getRect(find.text('Keep it')).bottom - 0.5)); // under its label
    expect(c.left, closeTo(row.left + 14, 1)); // the full width of the row, inside its padding
    expect(c.right, closeTo(row.right - 14, 1));
  });
}
