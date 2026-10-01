import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:komga_reader/reader_keys.dart';
import 'package:komga_reader/screens/app_settings.dart';
import 'package:komga_reader/screens/reader.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/helpers.dart';
import 'support/no_network.dart';
import 'support/reader_server.dart';

/// Settings > Remote and keys: the reader's keys, changed, kept, and used.
void main() {
  final k = ReaderKeys.instance;
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await k.load();
  });

  test('the usual keys; a key has one job; Show the controls keeps one; right to left swaps Left and Right', () async {
    expect(k.isDefault, isTrue);
    expect(k.actionFor(LogicalKeyboardKey.arrowRight), ReaderAction.next);
    expect(k.actionFor(LogicalKeyboardKey.arrowRight, rtl: true), ReaderAction.previous);
    expect(k.actionFor(LogicalKeyboardKey.enter), ReaderAction.controls);
    expect(k.actionFor(LogicalKeyboardKey.keyQ), isNull);

    expect(await k.assign(ReaderAction.controls, LogicalKeyboardKey.space), ReaderAction.next); // moved, and said
    expect(k.actionFor(LogicalKeyboardKey.space), ReaderAction.controls);
    expect(k.keys[ReaderAction.next], isNot(contains(LogicalKeyboardKey.space)));

    for (final key in List.of(k.keys[ReaderAction.controls]!)) {
      await k.remove(ReaderAction.controls, key);
    }
    expect(k.keys[ReaderAction.controls]!.length, 1); // the last one stays

    await k.assign(ReaderAction.next, LogicalKeyboardKey.mediaTrackNext);
    await k.load(); // next start
    expect(k.actionFor(LogicalKeyboardKey.mediaTrackNext), ReaderAction.next); // kept on the device
    await k.reset();
    expect(k.isDefault, isTrue);
  });

  test("the only key that shows the controls can't be given to another action - and it says why (code review)",
      () async {
    for (final key in List.of(k.keys[ReaderAction.controls]!)) {
      await k.remove(ReaderAction.controls, key);
    }
    final last = k.keys[ReaderAction.controls]!.single;
    expect(k.cantAssign(ReaderAction.next, last), contains('only key that shows the controls'));
    expect(await k.assign(ReaderAction.next, last), isNull);
    expect(k.keys[ReaderAction.controls], [last], reason: 'still there: the remote can always bring up the controls');
    expect(k.cantAssign(ReaderAction.next, LogicalKeyboardKey.keyN), isNull); // any other key: fine
  });

  testWidgets("the press-a-key dialog: Back and Esc cancel - they're never taken as the key (code review)",
      (tester) async {
    setView(tester, const Size(1000, 2000));
    await tester.pumpWidget(MaterialApp(home: AppSettingsScreen(api: noNetwork(ReaderServer.new), onSignOut: () {},
        initialPage: SettingsPage.keys)));
    await tester.pump();
    for (final cancel in [LogicalKeyboardKey.goBack, LogicalKeyboardKey.escape]) {
      await tester.tap(find.text('Add').first); // Next page
      await tester.pumpAndSettle();
      expect(find.text('Next page: press a key'), findsOneWidget);
      // the remote's Back (the test kit knows no physical key for it, so one is named)
      await tester.sendKeyEvent(cancel, physicalKey: PhysicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(find.text('Next page: press a key'), findsNothing, reason: 'cancelled');
      expect(k.keys[ReaderAction.next], isNot(contains(cancel)), reason: '${ReaderKeys.nameOf(cancel)} not added');
    }
    expect(k.isDefault, isTrue);
  });

  testWidgets('the reader follows the map: a remapped key turns the page', (tester) async {
    await k.assign(ReaderAction.next, LogicalKeyboardKey.mediaTrackNext);
    await k.assign(ReaderAction.previous, LogicalKeyboardKey.arrowRight); // Right now goes back
    final api = noNetwork(ReaderServer.new);
    await tester.pumpWidget(MaterialApp(home: ReaderScreen(api: api, book: api.theBook)));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    double page() => tester.widget<PageView>(find.byType(PageView)).controller!.page!;
    Future<void> press(LogicalKeyboardKey key) async {
      await tester.sendKeyEvent(key);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
    }

    await press(LogicalKeyboardKey.mediaTrackNext);
    expect(page(), 1.0);
    await press(LogicalKeyboardKey.arrowRight);
    expect(page(), 0.0);
    await tester.pump(const Duration(seconds: 2));
  });

  testWidgets('Settings: + Add takes the next key pressed; a chip removes its key', (tester) async {
    setView(tester, const Size(1000, 2000));
    await tester.pumpWidget(MaterialApp(home: AppSettingsScreen(api: noNetwork(ReaderServer.new), onSignOut: () {},
        initialPage: SettingsPage.keys)));
    await tester.pump();
    expect(find.text('Next page'), findsOneWidget);
    expect(find.text('PgDn'), findsOneWidget);
    final chip = tester.widget<InputChip>(find.ancestor(of: find.text('PgDn'), matching: find.byType(InputChip)));
    expect(chip.onDeleted, isNull, reason: 'one stop per key for the remote - no separate delete button');
    await tester.tap(find.text('Add').first); // Next page
    await tester.pumpAndSettle();
    expect(find.text('Next page: press a key'), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyN);
    await tester.pumpAndSettle();
    expect(k.actionFor(LogicalKeyboardKey.keyN), ReaderAction.next);
    expect(find.text('N'), findsOneWidget);
    await tester.tap(find.text('PgDn'));
    await tester.pumpAndSettle();
    expect(k.actionFor(LogicalKeyboardKey.pageDown), isNull);
    await tester.tap(find.text('Reset keys'));
    await tester.pumpAndSettle();
    expect(k.isDefault, isTrue);
  });
}
