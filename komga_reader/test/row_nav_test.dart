import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:komga_reader/widgets/setting_rows.dart';

/// Settings with the remote: Up / Down go row to row, never skipping a row because a wide control sat over a short
/// one (user, 2026-09-30).
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

  testWidgets('alignment: choices beside their labels share one width; one under its label spans the row',
      (tester) async {
    tester.view.physicalSize = const Size(700, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: SettingsColumn(child: ListView(children: [
      SettingsGroup(children: [
        SegmentRow<int>(title: 'A', value: 1, onChanged: (_) {}, choices: const [Choice(1, 'x'), Choice(2, 'y')]),
        SegmentRow<int>(title: 'B', value: 1, onChanged: (_) {},
            choices: const [Choice(1, 'aaaa'), Choice(2, 'bbbb'), Choice(3, 'cccc')]),
        // six long choices: can't sit beside its label at this width (the photo's "Keep the screen on")
        SegmentRow<int>(title: 'Keep it', value: 1, onChanged: (_) {}, choices: const [
          Choice(1, 'first one'), Choice(2, 'second one'), Choice(3, 'third one'), Choice(4, 'fourth one'),
          Choice(5, 'fifth one'), Choice(6, 'sixth one')]),
      ]),
    ])))));
    await tester.pump();
    await tester.pump(); // the shared width settles after the first frame
    final buttons = find.byType(SegmentedButton<int>);
    final a = tester.getRect(buttons.at(0)), b = tester.getRect(buttons.at(1)), c = tester.getRect(buttons.at(2));
    expect(a.width, closeTo(b.width, 0.5), reason: "the long one under its label doesn't widen the column");
    expect(a.right, closeTo(b.right, 0.5));
    final row = tester.getRect(find.byType(SettingsGroup));
    expect(c.left, closeTo(row.left + 14, 1)); // the full width of the row, inside its padding
    expect(c.right, closeTo(row.right - 14, 1));
  });

  testWidgets('a page taller than the screen: Down keeps the focused row on screen, scrolling as it goes (test audit)',
      (tester) async {
    tester.view.physicalSize = const Size(900, 500);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: ListView(children: [
      SettingsGroup(title: 'G', children: [
        for (var i = 0; i < 20; i++) SwitchRow(title: 'Row $i', value: false, onChanged: (_) {}),
      ]),
    ]))));
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.tab); // the first row
    await tester.pump();
    final screen = tester.getRect(find.byType(ListView));
    for (var i = 1; i < 15; i++) {
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pumpAndSettle();
      final focused = FocusManager.instance.primaryFocus!.context!;
      final r = tester.getRect(find.byWidget(focused.widget).first);
      expect(r.top >= screen.top - 0.5 && r.bottom <= screen.bottom + 0.5, isTrue,
          reason: 'after $i Downs the focused row ($r) is inside the screen ($screen)');
    }
  });

  testWidgets('Down from the far end of a wide choice goes to the next row, then the one after; Up comes back',
      (tester) async {
    tester.view.physicalSize = const Size(1000, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    var a = 1, c = 1;
    var b = false;
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: StatefulBuilder(builder: (context, set) => ListView(
      children: [
        SettingsGroup(title: 'G', children: [
          SegmentRow<int>(title: 'Wide', value: a, onChanged: (v) => set(() => a = v),
              choices: const [Choice(1, 'One'), Choice(2, 'Two'), Choice(3, 'Three'), Choice(4, 'Four')]),
          SwitchRow(title: 'Short', value: b, onChanged: (v) => set(() => b = v)), // its switch sits at the far right
          SegmentRow<int>(title: 'Another', value: c, onChanged: (v) => set(() => c = v),
              choices: const [Choice(1, 'A'), Choice(2, 'B')]),
        ]),
      ],
    )))));
    await tester.pump();

    String? focusedText() {
      final f = FocusManager.instance.primaryFocus?.context;
      if (f == null) return null;
      final texts = find.descendant(of: find.byWidget(f.widget), matching: find.byType(Text));
      return texts.evaluate().isEmpty ? null : (texts.evaluate().first.widget as Text).data;
    }

    // focus the wide row's first segment (a tap doesn't give a button keyboard focus), then its last with Right
    await tester.sendKeyEvent(LogicalKeyboardKey.tab); // the first control: the wide row's first segment
    await tester.pump();
    for (var i = 0; i < 3; i++) {
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pump();
    }
    expect(focusedText(), 'Four');

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();
    expect(focusedText(), 'Short', reason: 'the next row - not skipped');

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();
    expect(focusedText(), 'A', reason: "the row after: its first control");

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await tester.pump();
    expect(focusedText(), 'Short');
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await tester.pump();
    expect(focusedText(), 'One', reason: "up to the previous row's first control");
  });
}
