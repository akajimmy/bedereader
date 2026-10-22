import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:komga_reader/widgets/setting_rows.dart';

import 'support/helpers.dart';

/// The shared setting rows (widgets/setting_rows.dart): how they look and how they lay out. Moved here from
/// row_nav_test, which is about Up / Down only (test audit, 2026-09-30).
void main() {
  testWidgets('slim buttons (user, 2026-10-21: the mock-ups\' A): the choice in force a tint of the accent with light '
      'accent text, not the solid accent; a lighter outline; lower than before', (tester) async {
    const accent = Colors.blue;
    await tester.pumpWidget(MaterialApp(theme: ThemeData(colorScheme: const ColorScheme.dark(primary: accent)),
        home: Scaffold(body: SettingsGroup(children: [
          SegmentRow<int>(title: 'Fit', value: 2, onChanged: (_) {},
              choices: const [Choice(1, 'Screen'), Choice(2, 'Width'), Choice(3, 'Height')]),
        ]))));
    final b = tester.widget<SegmentedButton<int>>(find.byType(SegmentedButton<int>));
    final bg = b.style!.backgroundColor!.resolve({WidgetState.selected})!;
    expect(bg.a, lessThan(0.5), reason: 'a tint');
    expect((bg.r, bg.g, bg.b), (accent.r, accent.g, accent.b), reason: 'of the accent');
    final fg = b.style!.foregroundColor!.resolve({WidgetState.selected})!;
    expect(fg.computeLuminance(), greaterThan(accent.computeLuminance()), reason: 'lighter than the accent');
    expect(tester.getSize(find.byType(SegmentedButton<int>)).height, lessThan(36), reason: 'lower');
  });

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
    expect(bg!.a, greaterThan(0.05)); // shaded, not nothing
    expect(b.style!.backgroundColor!.resolve({WidgetState.disabled}), isNull); // the others as usual
  });

  testWidgets('disabled shows no accent at all - grey - so it reads apart from enabled (user, 2026-10-22: "hard to '
      'tell disabled from enabled")', (tester) async {
    await tester.pumpWidget(MaterialApp(theme: ThemeData(colorScheme: const ColorScheme.dark(primary: Colors.orange)),
        home: const Scaffold(body: SizedBox())));
    final style = slimButtonStyle(Theme.of(tester.element(find.byType(SizedBox))).colorScheme);
    bool grey(Color c) => (c.r - c.g).abs() < 0.01 && (c.g - c.b).abs() < 0.01;
    const off = {WidgetState.disabled};
    for (final states in [off, {...off, WidgetState.selected}]) {
      final fg = style.foregroundColor!.resolve(states)!;
      expect(grey(fg), isTrue, reason: 'text, $states');
      final bg = style.backgroundColor!.resolve(states);
      if (bg != null) expect(grey(bg), isTrue, reason: 'fill, $states');
      expect(grey(style.side!.resolve(states)!.color), isTrue, reason: 'outline, $states');
    }
    expect(grey(style.foregroundColor!.resolve({WidgetState.selected})!), isFalse, reason: 'enabled: the accent');
    // the disabled choice in force is dimmer than an enabled one
    expect(style.foregroundColor!.resolve({...off, WidgetState.selected})!.a,
        lessThan(style.foregroundColor!.resolve({})!.a + 0.001));
  });

  testWidgets('choices too long for the row: the labels shrink, the buttons keep their full height and the row\'s width '
      '(user, 2026-10-08: shrinking the whole control "just makes it harder to tap")', (tester) async {
    const long = [
      Choice(1, 'the first of the choices'), Choice(2, 'the second of the choices'),
      Choice(3, 'the third of the choices'), Choice(4, 'the fourth of the choices'),
    ];
    Future<Size> buttons(double width) async {
      setView(tester, Size(width, 800));
      await tester.pumpWidget(MaterialApp(home: Scaffold(body: ListView(children: [
        SettingsGroup(children: [SegmentRow<int>(title: 'Keep it', value: 1, onChanged: (_) {}, choices: long)]),
      ]))));
      return tester.getRect(find.byType(SegmentedButton<int>)).size; // as drawn: a scaled-down control is smaller
    }

    final roomy = await buttons(3000); // all of it fits
    final narrow = await buttons(320); // a phone: far too narrow for those labels
    expect(tester.takeException(), isNull, reason: 'no overflow');
    expect(narrow.height, roomy.height, reason: 'as tall as when everything fits');
    expect(narrow.width, greaterThan(320 - 2 * 14 - 28 - 1), reason: "the row's width, not shrunk inside it");
  });

  testWidgets('every choice under its label, the full width of the row - a short one too, with room beside it '
      '(user, 2026-10-22: "all the selection controls go to their own line, full width of the space allowed")',
      (tester) async {
    setView(tester, const Size(1400, 800));
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: ListView(children: [
      SettingsGroup(children: [
        SegmentRow<int>(title: 'A', value: 1, onChanged: (_) {}, choices: const [Choice(1, 'x'), Choice(2, 'y')]),
        ToggleChipsRow(title: 'B', chips: [ToggleChip('p', true, (_) {}), ToggleChip('q', false, (_) {})]),
      ]),
    ]))));
    final row = tester.getRect(find.byType(SettingsGroup));
    for (final (label, buttons) in [('A', find.byType(SegmentedButton<int>).first),
        ('B', find.byType(SegmentedButton<int>).last)]) {
      final r = tester.getRect(buttons);
      expect(r.top, greaterThan(tester.getRect(find.text(label)).bottom - 0.5), reason: '$label: under its label');
      expect(r.left, closeTo(row.left + 14, 1), reason: '$label: from the left edge, inside the padding');
      expect(r.right, closeTo(row.right - 14, 1), reason: '$label: to the right edge');
    }
  });

  testWidgets('on/off choices (the position text, the poster lines): each lit while on, a tap flips that one only',
      (tester) async {
    var p = true, q = false;
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: StatefulBuilder(builder: (context, set) =>
        SettingsGroup(children: [
          ToggleChipsRow(title: 'Show', chips: [
            ToggleChip('Clock', p, (v) => set(() => p = v)),
            ToggleChip('Battery', q, (v) => set(() => q = v)),
          ]),
        ])))));
    final b = tester.widget<SegmentedButton<int>>(find.byType(SegmentedButton<int>));
    expect(b.selected, {0}, reason: 'Clock lit, Battery not');
    await tester.tap(find.text('Battery'));
    await tester.pump();
    expect((p, q), (true, true));
    await tester.tap(find.text('Clock'));
    await tester.pump();
    expect((p, q), (false, true));
    await tester.tap(find.text('Battery'));
    await tester.pump();
    expect((p, q), (false, false), reason: 'all off is allowed');
  });
}
