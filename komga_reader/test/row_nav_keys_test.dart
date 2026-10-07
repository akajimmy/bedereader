import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:komga_reader/reader_keys.dart';
import 'package:komga_reader/screens/app_settings.dart';
import 'package:komga_reader/settings.dart';
import 'package:komga_reader/widgets/epub_settings.dart';
import 'package:komga_reader/widgets/setting_rows.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'settings_remote_test.dart' show TwoLibraries, everyRowShown, focus, name;
import 'support/helpers.dart';
import 'support/no_network.dart';

/// Settings rows with the remote, as in the release app (user, 2026-10-07: from the rightmost control of "Show the
/// controls", Down jumped past "Close the book" to "Zoom in"; in the EPUB panel, from Font to Line spacing and from
/// Margins to Book's formatting). The rows' Up / Down (RowNav) found its rows by their focus nodes' debug labels,
/// which Flutter keeps in debug builds only: the tests, run in debug mode, passed while the release app skipped rows.
/// So each scenario here first empties every label, as a release build has them.
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

  testWidgets('Remote and keys: Down from the far right of a row goes to the next row, however short it is; Up back',
      (tester) async {
    setView(tester, const Size(1280, 720));
    everyRowShown();
    await tester.pumpWidget(MaterialApp(home: AppSettingsScreen(api: noNetwork(TwoLibraries.new), onSignOut: () {},
        initialPage: SettingsPage.keys)));
    await tester.pumpAndSettle();
    asInRelease();
    // the action rows: each one's controls, by the row they're in
    Finder addIn(String label) => find.descendant(
        of: find.ancestor(of: find.text(label), matching: find.byType(Column)).first,
        matching: find.widgetWithText(TextButton, 'Add'));
    FocusNode nodeOf(Finder f) => Focus.of(tester.element(find.descendant(of: f, matching: find.byType(Text)).first));
    final controlsAdd = nodeOf(addIn('Show the controls'));
    controlsAdd.requestFocus(); // the rightmost control of "Show the controls"
    await tester.pumpAndSettle();
    expect(focus(), controlsAdd);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown, platform: 'android');
    await tester.pumpAndSettle();
    expect(name(focus()), 'Esc', reason: '"Close the book", its first control');

    // from a key chip (as on the tablet: Space, Next page's last chip, Down went to Previous page's Add - straight
    // below - not its first control)
    final space = Focus.of(tester.element(find.descendant(
        of: find.widgetWithText(InputChip, 'Space'), matching: find.byType(Text)).first));
    space.requestFocus();
    await tester.pumpAndSettle();
    expect(name(focus()), 'Space');
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown, platform: 'android');
    await tester.pumpAndSettle();
    expect(name(focus()), '←', reason: "Previous page's first control");
  });

  testWidgets("with Android's navigation bar over the bottom of the screen (user, 2026-10-07: Comics > Keep the screen "
      'on, focused, sat behind it), every row reached with Down is above the bar', (tester) async {
    setView(tester, const Size(1280, 720));
    tester.view.padding = const FakeViewPadding(bottom: 72); // the bar, as edge-to-edge Android reports it
    tester.view.viewPadding = const FakeViewPadding(bottom: 72);
    addTearDown(tester.view.resetPadding);
    addTearDown(tester.view.resetViewPadding);
    everyRowShown();
    await tester.pumpWidget(MaterialApp(home: AppSettingsScreen(api: noNetwork(TwoLibraries.new), onSignOut: () {},
        initialPage: SettingsPage.reader)));
    await tester.pumpAndSettle();
    asInRelease();
    final barTop = 720.0 - 72 / tester.view.devicePixelRatio;
    Focus.of(tester.element(find.descendant(of: find.byType(SegmentedButton<PageTurn>), matching: find.byType(Text))
        .first)).requestFocus(); // the page's first row
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
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: SettingsColumn(child: Builder(builder: (c) =>
        ListView(children: epubSettingRows(c, const EpubPrefs(), (_) {})))))));
    await tester.pumpAndSettle();
    asInRelease();
    final seen = <String>[];
    Focus.of(tester.element(find.text('Literata'))).requestFocus();
    await tester.pumpAndSettle();
    for (var i = 0; i < 7; i++) {
      seen.add(name(focus()));
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown, platform: 'android');
      await tester.pumpAndSettle();
    }
    expect(seen, ['Literata', 'Smaller', 'Tight', 'None', 'Narrow', 'Dark', "Book's"]); // (Alignment's first, 2026-10-07)
  });

  testWidgets("rows whose controls changed while the page was open (keys loaded or edited): Up / Down still go to the "
      "next row's first control on screen - the focus tree's order (which put a row's kept Add button before its new "
      'chips) no longer decides', (tester) async {
    setView(tester, const Size(1280, 720));
    everyRowShown();
    final k = ReaderKeys.instance;
    addTearDown(() => tester.runAsync(k.reset));
    await tester.pumpWidget(MaterialApp(home: AppSettingsScreen(api: noNetwork(TwoLibraries.new), onSignOut: () {},
        initialPage: SettingsPage.keys)));
    await tester.pumpAndSettle();
    // Close the book gains two keys while the page is open: its Add button is kept, the new chips come after it in
    // the focus tree, though they show before it
    await tester.runAsync(() async {
      await k.assign(ReaderAction.close, LogicalKeyboardKey.keyQ);
      await k.assign(ReaderAction.close, LogicalKeyboardKey.keyW);
    });
    await tester.pumpAndSettle();
    asInRelease();
    FocusNode chip(String label) =>
        Focus.of(tester.element(find.descendant(of: find.widgetWithText(InputChip, label), matching: find.byType(Text)).first));
    // from the far right of Show the controls (its Add), Down: Close the book's first control - Esc, at its left
    final controlsAdd = Focus.of(tester.element(find.descendant(
        of: find.descendant(of: find.ancestor(of: find.text('Show the controls'), matching: find.byType(Column)).first,
            matching: find.widgetWithText(TextButton, 'Add')),
        matching: find.byType(Text)).first));
    controlsAdd.requestFocus();
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown, platform: 'android');
    await tester.pumpAndSettle();
    expect(focus(), chip('Esc'), reason: "Close the book's first control on screen, not ${name(focus())}");
    // and from Zoom in's first control, Up: Close the book's first control again
    chip('=').requestFocus();
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp, platform: 'android');
    await tester.pumpAndSettle();
    expect(focus(), chip('Esc'), reason: 'Up: the row above, its first control - not ${name(focus())}');
  });
}
