import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:komga_reader/widgets/setting_rows.dart';

/// Settings with the remote: Up / Down go row to row, never skipping a row because a wide control sat over a short
/// one (user, 2026-09-30). How the rows look and lay out: setting_rows_test.
void main() {
  /// The text of the control with focus (a segment's label, a button's text).
  String? focusedText() {
    final f = FocusManager.instance.primaryFocus?.context;
    if (f == null) return null;
    final texts = find.descendant(of: find.byWidget(f.widget), matching: find.byType(Text));
    return texts.evaluate().isEmpty ? null : (texts.evaluate().first.widget as Text).data;
  }

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

  testWidgets('Down from a wide choice goes to the next row even when its only control is off to the side; '
      'then the one after; Up comes back', (tester) async {
    // The case the rows are for: the wide row's left segment sits straight over the row after next (the page's
    // choices share one width), and the row in between has only a small button at the far right. Flutter's own
    // Down goes to what is straight below - the row after next - skipping the button's row. (The old version of this
    // test started from the far right, over the skipped row's switch, and passed without RowNav - test audit,
    // 2026-09-30.)
    tester.view.physicalSize = const Size(1000, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    var a = 1, c = 1, pressed = 0;
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: StatefulBuilder(builder: (context, set) => SettingsColumn(
      child: ListView(children: [
        SettingsGroup(title: 'G', children: [
          SegmentRow<int>(title: 'Wide', value: a, onChanged: (v) => set(() => a = v),
              choices: const [Choice(1, 'One'), Choice(2, 'Two'), Choice(3, 'Three'), Choice(4, 'Four')]),
          ActionRow(title: 'Short', button: TextButton(onPressed: () => pressed++, child: const Text('Go'))),
          SegmentRow<int>(title: 'Another', value: c, onChanged: (v) => set(() => c = v),
              choices: const [Choice(1, 'A'), Choice(2, 'B')]),
        ]),
      ]),
    )))));
    await tester.pump();
    await tester.pump(); // the shared width settles after the first frame

    // the premise: the button is off to the right, and the next row's first choice is straight under the wide one's
    final one = tester.getRect(find.text('One')), go = tester.getRect(find.text('Go'));
    expect(go.left, greaterThan(one.right + 100)); // nowhere near under "One"
    expect(tester.getRect(find.widgetWithText(SegmentedButton<int>, 'A')).left, closeTo(
        tester.getRect(find.widgetWithText(SegmentedButton<int>, 'One')).left, 0.5));

    await tester.sendKeyEvent(LogicalKeyboardKey.tab); // the first control: the wide row's first segment
    await tester.pump();
    expect(focusedText(), 'One');

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();
    expect(focusedText(), 'Go', reason: 'the next row - not skipped');

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();
    expect(focusedText(), 'A', reason: 'the row after: its first control');

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await tester.pump();
    expect(focusedText(), 'Go');
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await tester.pump();
    expect(focusedText(), 'One', reason: "up to the previous row's first control");

    // and from the far end of the wide row too
    for (var i = 0; i < 3; i++) {
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pump();
    }
    expect(focusedText(), 'Four');
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();
    expect(focusedText(), 'Go');
    expect(pressed, 0);
  });
}
