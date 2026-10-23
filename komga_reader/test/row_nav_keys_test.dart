// row nav keys (test audit, 2026-10-23: row_nav_test.dart folded in).
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:komga_reader/reader_keys.dart';
import 'package:komga_reader/screens/app_settings.dart';
import 'package:komga_reader/settings.dart';
import 'package:komga_reader/widgets/epub_settings.dart';
import 'package:komga_reader/widgets/setting_rows.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/helpers.dart';
import 'support/no_network.dart';
import 'support/settings_pages.dart';

// Settings rows with the remote, as in the release app (user, 2026-10-07: from the rightmost control of "Show the
// controls", Down jumped past "Close the book" to "Zoom in"; in the EPUB panel, from Font to Line spacing and from
// Margins to Book's formatting). The rows' Up / Down (RowNav) found its rows by their focus nodes' debug labels,
// which Flutter keeps in debug builds only: the tests, run in debug mode, passed while the release app skipped rows.
// So each scenario here first empties every label, as a release build has them.

// ---- from row_nav_test.dart
// Settings with the remote: Up / Down go row to row, never skipping a row because a wide control sat over a short
// one (user, 2026-09-30). How the rows look and lay out: setting_rows_test.

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  /// As in the release app: no focus node has a debug label (Flutter keeps them in debug builds only).
  void asInRelease() {
    void clear(FocusNode n) {
      n.debugLabel = null;
      for (final c in n.children) {
        clear(c);
      }
    }
    clear(FocusManager.instance.rootScope);
  }

  testWidgets("with Android's navigation bar over the bottom of the screen (user, 2026-10-07: Comics > Keep the screen "
      'on, focused, sat behind it), every row reached with Down is above the bar', (tester) async {
    setView(tester, const Size(1280, 720));
    tester.view.padding = const FakeViewPadding(bottom: 72); // the bar, as edge-to-edge Android reports it
    tester.view.viewPadding = const FakeViewPadding(bottom: 72);
    addTearDown(tester.view.resetPadding);
    addTearDown(tester.view.resetViewPadding);
    everyRowShown();
    await tester.pumpWidget(MaterialApp(home: AppSettingsScreen(api: noNetwork(TwoLibraries.new), onSignOut: () {},
        initialPage: SettingsPage.comics)));
    await tester.pumpAndSettle();
    asInRelease();
    final barTop = 720.0 - 72 / tester.view.devicePixelRatio;
    Focus.of(tester.element(find.descendant(of: find.byType(SegmentedButton<PageTurn>), matching: find.byType(Text))
        .first)).requestFocus(); // a row near the top
    await tester.pumpAndSettle();
    final passed = <String>[];
    for (var i = 0; i < 30; i++) {
      final before = focus();
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown, platform: 'android');
      await tester.pumpAndSettle();
      if (focus() == before) break; // the last row
      final box = focus().context!.findRenderObject()! as RenderBox;
      final bottom = box.localToGlobal(Offset(0, box.size.height)).dy;
      passed.add(name(focus()));
      expect(bottom, lessThanOrEqualTo(barTop + 0.5), reason: '${name(focus())} ends at $bottom, under the bar at $barTop');
    }
    expect(passed, isNotEmpty);
  });

  testWidgets('the EPUB Text group (user, 2026-10-07: Down skipped from Font to Line spacing, and from Margins to '
      "Book's formatting): every row in turn", (tester) async {
    setView(tester, const Size(1280, 720));
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: Builder(builder: (c) =>
        ListView(children: epubSettingRows(c, const EpubPrefs(), (_) {}))))));
    await tester.pumpAndSettle();
    asInRelease();
    // the rows by where their controls are on screen (not by what they're called: rows and steps get renamed and
    // moved - audit, 2026-10-11: this test was edited twice in a day only for that)
    final list = tester.getRect(find.byType(ListView));
    final rows = {
      for (final n in FocusManager.instance.rootScope.descendants)
        if (n.canRequestFocus && list.contains(n.rect.center)) n.rect.top.roundToDouble(),
    }.toList()
      ..sort();
    final seen = <double>[];
    final first = rows.first;
    FocusManager.instance.rootScope.descendants
        .firstWhere((n) => n.canRequestFocus && n.rect.top.roundToDouble() == first && list.contains(n.rect.center))
        .requestFocus();
    await tester.pumpAndSettle();
    for (var i = 0; i < 6; i++) {
      seen.add(focus().rect.top.roundToDouble());
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown, platform: 'android');
      await tester.pumpAndSettle();
    }
    expect(seen, rows.take(6), reason: 'each Down the next row, none skipped');
  });

  // (the rows' order by screen position, not the focus tree's, is checked by settings_remote_test's walk of Library &
  // Home, whose library switches are added once the libraries arrive)
  testWidgets("Remote and keys: Down from anywhere in a row goes to the next row's first control, however short it "
      "is; Up to the row above's first control - also once a row's controls changed while the page was open (keys "
      'added: the kept Add button before the new chips in the focus tree)', (tester) async {
    setView(tester, const Size(1280, 720));
    everyRowShown();
    final k = ReaderKeys.instance;
    addTearDown(() => tester.runAsync(k.reset));
    await tester.pumpWidget(MaterialApp(home: AppSettingsScreen(api: noNetwork(TwoLibraries.new), onSignOut: () {},
        initialPage: SettingsPage.keys)));
    await tester.pumpAndSettle();
    FocusNode chip(String label) =>
        Focus.of(tester.element(find.descendant(of: find.widgetWithText(InputChip, label), matching: find.byType(Text)).first));
    FocusNode addOf(String row) => Focus.of(tester.element(find.descendant(
        of: find.descendant(of: find.ancestor(of: find.text(row), matching: find.byType(Column)).first,
            matching: find.widgetWithText(TextButton, 'Add')),
        matching: find.byType(Text)).first));
    Future<void> press(LogicalKeyboardKey key, FocusNode from) async {
      from.requestFocus();
      await tester.pumpAndSettle();
      expect(focus(), from);
      await tester.sendKeyEvent(key, platform: 'android');
      await tester.pumpAndSettle();
    }

    asInRelease();
    // from the far right of Show the controls (its Add), Down: Close the book's first control, Esc - at its left
    await press(LogicalKeyboardKey.arrowDown, addOf('Show the controls'));
    expect(focus(), chip('Esc'), reason: '"Close the book", its first control - not ${name(focus())}');
    // from a key chip (as on the tablet: Space, Next page's last chip, Down went to Previous page's Add - straight
    // below - not its first control)
    await press(LogicalKeyboardKey.arrowDown, chip('Space'));
    expect(name(focus()), '←', reason: "Previous page's first control");

    // Close the book gains two keys while the page is open: its Add button is kept, the new chips come after it in
    // the focus tree, though they show before it - the row's last control in focus order isn't its last on screen
    await tester.runAsync(() async {
      await k.assign(ReaderAction.close, LogicalKeyboardKey.keyQ);
      await k.assign(ReaderAction.close, LogicalKeyboardKey.keyW);
    });
    await tester.pumpAndSettle();
    asInRelease();
    final closeRow = RowNav.rowOf(chip('Esc'));
    expect([
      for (final n in chip('Esc').nearestScope!.traversalDescendants)
        if (n.canRequestFocus && RowNav.rowOf(n) == closeRow) name(n),
    ], ['Esc', 'Add', 'Q', 'W'], reason: 'the scenario: the kept Add before the new chips in the focus tree');
    await press(LogicalKeyboardKey.arrowDown, addOf('Show the controls'));
    expect(focus(), chip('Esc'), reason: "Close the book's first control, not ${name(focus())}");
    // and from Zoom in's first control, Up: Close the book's first control - not the row's last (W, or Add on screen)
    await press(LogicalKeyboardKey.arrowUp, chip('='));
    expect(focus(), chip('Esc'), reason: 'Up: the row above, its first control - not ${name(focus())}');
  });

  group('row nav', () {
    /// The text of the control with focus (a segment's label, a button's text).
    String? focusedText() {
      final f = FocusManager.instance.primaryFocus?.context;
      if (f == null) return null;
      final texts = find.descendant(of: find.byWidget(f.widget), matching: find.byType(Text));
      return texts.evaluate().isEmpty ? null : (texts.evaluate().first.widget as Text).data;
    }

    // (a page taller than the screen, Down keeping the focused row on screen: settings_remote_test's walk of every
    // page, and row_nav_keys_test's with Android's navigation bar)
    testWidgets('Down from a wide choice goes to the next row even when its only control is off to the side; '
        'then the one after; Up comes back', (tester) async {
      // The case the rows are for: the wide row's left segment sits straight over the row after next (the page's
      // choices share one width), and the row in between has only a small button at the far right. Flutter's own
      // Down goes to what is straight below - the row after next - skipping the button's row. (The old version of this
      // test started from the far right, over the skipped row's switch, and passed without RowNav - test audit,
      // 2026-09-30.)
      setView(tester, const Size(1000, 800));
      var a = 1, c = 1, pressed = 0;
      await tester.pumpWidget(MaterialApp(home: Scaffold(body: StatefulBuilder(builder: (context, set) =>
        ListView(children: [
          SettingsGroup(title: 'G', children: [
            SegmentRow<int>(title: 'Wide', value: a, onChanged: (v) => set(() => a = v),
                choices: const [Choice(1, 'One'), Choice(2, 'Two'), Choice(3, 'Three'), Choice(4, 'Four')]),
            ActionRow(title: 'Short', button: TextButton(onPressed: () => pressed++, child: const Text('Go'))),
            SegmentRow<int>(title: 'Another', value: c, onChanged: (v) => set(() => c = v),
                choices: const [Choice(1, 'A'), Choice(2, 'B')]),
          ]),
        ]),
      ))));
      await tester.pump();

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
  });
}
