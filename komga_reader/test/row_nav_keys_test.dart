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
    // Text, then Formatting (2026-10-07: Page colours moved to the Page group; Alignment and Paragraphs open on Book's)
    expect(seen, ['Literata', 'Smaller', 'Tight', 'None', 'Narrow', "Book's", "Book's"]);
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
}
