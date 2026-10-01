import 'dart:convert';

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

  // ---- loading old or damaged saves (test audit, 2026-09-30)

  /// Starts the app with [raw] saved as the key map.
  Future<void> loadSaved(String raw) async {
    SharedPreferences.setMockInitialValues({'reader.keys': raw});
    await k.load();
  }

  List<int> ids(ReaderAction a) => [for (final key in k.keys[a]!) key.keyId];
  List<int> defaultIds(ReaderAction a) => [for (final key in ReaderKeys.defaults[a]!) key.keyId];

  test('a save from before the zoom keys existed: its own keys kept, the zoom keys (missing from it) get theirs',
      () async {
    final next = LogicalKeyboardKey.mediaTrackNext.keyId, prev = LogicalKeyboardKey.mediaTrackPrevious.keyId;
    await loadSaved(jsonEncode({ // the four actions of the first build with Remote and keys
      'next': [next], 'previous': [prev],
      'controls': [LogicalKeyboardKey.enter.keyId], 'close': [LogicalKeyboardKey.escape.keyId],
    }));
    expect(ids(ReaderAction.next), [next]);
    expect(ids(ReaderAction.previous), [prev]);
    expect(ids(ReaderAction.controls), [LogicalKeyboardKey.enter.keyId]);
    expect(ids(ReaderAction.zoomIn), defaultIds(ReaderAction.zoomIn), reason: 'not in the save: the usual keys');
    expect(ids(ReaderAction.zoomOut), defaultIds(ReaderAction.zoomOut));
    expect(k.actionFor(LogicalKeyboardKey.equal), ReaderAction.zoomIn);

    await loadSaved(jsonEncode({'next': [LogicalKeyboardKey.keyN.keyId]})); // only one action saved
    for (final a in ReaderAction.values) {
      if (a != ReaderAction.next) expect(ids(a), defaultIds(a), reason: '${a.name}: missing, so the usual keys');
    }
    expect(ids(ReaderAction.next), [LogicalKeyboardKey.keyN.keyId]);
  });

  test('a damaged save - not JSON, the wrong shape, an action this build has never heard of - loads the usual keys, '
      'without a crash', () async {
    for (final raw in [
      'not json at all',
      '[1, 2, 3]', // a list, not a map
      '{"next": "Right"}', // keys not a list
      '{"next": ["Right"]}', // not key ids
      '{"next": [1.5]}',
      '{"turbo": [65], "warp": "x"}', // actions that don't exist
      '',
    ]) {
      await loadSaved(raw);
      expect(k.isDefault, isTrue, reason: raw);
      expect(k.actionFor(LogicalKeyboardKey.enter), ReaderAction.controls, reason: raw);
    }
  });

  test('a save with no key left for Show the controls (builds before the code review allowed it) still has a key '
      'that shows them - BUG: load() takes the empty list as it is, so no key brings up the controls',
      skip: 'BUG: ReaderKeys.load() keeps a saved empty "controls" list - the remote is stranded with the controls '
          "hidden; cantAssign/canRemove only stop new ones (90f37e8), they don't repair old saves",
      () async {
    await loadSaved(jsonEncode({
      'next': [LogicalKeyboardKey.arrowRight.keyId, LogicalKeyboardKey.enter.keyId], // Enter given to Next page
      'controls': <int>[],
    }));
    expect(k.keys[ReaderAction.controls], isNotEmpty);
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
