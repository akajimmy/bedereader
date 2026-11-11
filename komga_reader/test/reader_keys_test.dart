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

  // bug found 2026-09-30 (missing-tests audit): load() kept the saved empty list, stranding the remote; fixed in load()
  test('a save with no key left for Show the controls (builds before the code review allowed it) still has a key '
      'that shows them', () async {
    await loadSaved(jsonEncode({
      'next': [LogicalKeyboardKey.arrowRight.keyId, LogicalKeyboardKey.enter.keyId], // Enter given to Next page
      'controls': <int>[],
    }));
    expect(k.keys[ReaderAction.controls], isNotEmpty);
    expect(k.actionFor(LogicalKeyboardKey.enter), ReaderAction.controls, reason: 'its default key, taken back');
    expect(k.actionFor(LogicalKeyboardKey.arrowRight), ReaderAction.next, reason: 'the rest of the save kept');
  });

  testWidgets("Settings: + Add takes the next key pressed - Back cancels, it's never taken as the key (code review); "
      'Esc is a key like any other (user, 2026-10-31: a controller button sending Esc could not be set); a chip '
      'removes its key', (tester) async {
    // (two tests on the same page, merged - test audit, 2026-10-07)
    addTearDown(k.reset);
    setView(tester, const Size(1000, 2000));
    await tester.pumpWidget(MaterialApp(home: AppSettingsScreen(api: noNetwork(ReaderServer.new), onSignOut: () {},
        initialPage: SettingsPage.keys)));
    await tester.pump();
    await tester.tap(find.text('Add').first); // Next page
    await tester.pumpAndSettle();
    expect(find.text('Next page: press a key'), findsOneWidget);
    // the remote's Back (the test kit knows no physical key for it, so one is named)
    await tester.sendKeyEvent(LogicalKeyboardKey.goBack, physicalKey: PhysicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.text('Next page: press a key'), findsNothing, reason: 'cancelled');
    expect(k.keys[ReaderAction.next], isNot(contains(LogicalKeyboardKey.goBack)), reason: 'Back not added');
    expect(k.isDefault, isTrue);

    await tester.tap(find.text('Add').first); // Next page
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.text('Next page: press a key'), findsNothing, reason: 'Esc was the answer');
    expect(find.byType(AppSettingsScreen), findsOneWidget, reason: 'still in Settings');
    expect(k.actionFor(LogicalKeyboardKey.escape), ReaderAction.next, reason: 'Esc taken (off Close the book)');
    await k.reset();
    await tester.pumpAndSettle();

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
  }, tags: 'slow');

  testWidgets('Settings: + Add takes Volume down (and any key) even with the focus outside the dialog - on the '
      'tablet the dialog never got a key (user, build 92: "it does not let me set the volume keys")', (tester) async {
    addTearDown(k.reset);
    setView(tester, const Size(1000, 2000));
    await tester.pumpWidget(MaterialApp(home: AppSettingsScreen(api: noNetwork(ReaderServer.new), onSignOut: () {},
        initialPage: SettingsPage.keys)));
    await tester.pump();
    await tester.tap(find.text('Add').first); // Next page
    await tester.pumpAndSettle();
    expect(find.text('Next page: press a key'), findsOneWidget);
    FocusManager.instance.primaryFocus?.unfocus(); // as on the tablet: no focus in the dialog
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.audioVolumeDown);
    await tester.pumpAndSettle();
    expect(find.text('Next page: press a key'), findsNothing, reason: 'the key was the answer');
    expect(k.actionFor(LogicalKeyboardKey.audioVolumeDown), ReaderAction.next);
    expect(find.text('Volume down'), findsOneWidget);
  }, variant: TargetPlatformVariant.only(TargetPlatform.android));

  // ---- Up, Down, Left and Right (user, 2026-11-03: the 8BitDo Micro held sideways, its up and down to be left and right)

  /// The controller a quarter turn round: its Up goes left, its Down right, its Left down, its Right up.
  Future<void> sideways() async {
    await k.assignMove(Nav.left, LogicalKeyboardKey.arrowUp);
    await k.assignMove(Nav.right, LogicalKeyboardKey.arrowDown);
    await k.assignMove(Nav.down, LogicalKeyboardKey.arrowLeft);
    await k.assignMove(Nav.up, LogicalKeyboardKey.arrowRight);
  }

  KeyEvent down(LogicalKeyboardKey key, [PhysicalKeyboardKey physical = PhysicalKeyboardKey.keyA]) =>
      KeyDownEvent(physicalKey: physical, logicalKey: key, timeStamp: Duration.zero);
  KeyEvent again(LogicalKeyboardKey key, [PhysicalKeyboardKey physical = PhysicalKeyboardKey.keyA]) =>
      KeyRepeatEvent(physicalKey: physical, logicalKey: key, timeStamp: Duration.zero);
  KeyEvent up(LogicalKeyboardKey key, [PhysicalKeyboardKey physical = PhysicalKeyboardKey.keyA]) =>
      KeyUpEvent(physicalKey: physical, logicalKey: key, timeStamp: Duration.zero);

  test('the arrows turned a quarter: each comes through as the one set, down, repeat and up; kept; Reset puts them '
      'back', () async {
    const u = LogicalKeyboardKey.arrowUp, l = LogicalKeyboardKey.arrowLeft;
    expect(k.remap(down(u)).logicalKey, u, reason: 'as it is, to begin with');
    expect(k.remap(up(u)).logicalKey, u);
    await sideways();
    expect(k.isDefault, isFalse);
    expect(k.moves[Nav.left], [u]);
    expect(k.moves[Nav.up], [LogicalKeyboardKey.arrowRight]);
    expect(k.remap(down(u)).logicalKey, l);
    expect(k.remap(again(u)).logicalKey, l);
    expect(k.remap(up(u)).logicalKey, l);
    expect(k.moved(LogicalKeyboardKey.arrowRight), u);
    await k.load(); // next start
    expect(k.moved(u), l);
    await k.reset();
    expect(k.moved(u), u);
    expect(k.isDefault, isTrue);
    await k.load();
    expect(k.moved(u), u);
  });

  test('a press ends as it began, whatever is set while it is held; a press not changed stays so', () async {
    const key = LogicalKeyboardKey.keyK;
    await k.assignMove(Nav.right, key);
    expect(k.remap(down(key)).logicalKey, LogicalKeyboardKey.arrowRight);
    await k.removeMove(Nav.right, key);
    expect(k.remap(again(key)).logicalKey, LogicalKeyboardKey.arrowRight);
    expect(k.remap(up(key)).logicalKey, LogicalKeyboardKey.arrowRight);

    expect(k.remap(down(key)).logicalKey, key);
    await k.assignMove(Nav.right, key);
    expect(k.remap(up(key)).logicalKey, key, reason: 'the key it was pressed as');
  });

  test('a key on no direction is left alone; in a text box a letter stays a letter, an arrow still turns', () async {
    await k.assignMove(Nav.right, LogicalKeyboardKey.keyK);
    await k.assignMove(Nav.left, LogicalKeyboardKey.arrowUp);
    expect(k.remap(down(LogicalKeyboardKey.keyQ)).logicalKey, LogicalKeyboardKey.keyQ);
    expect(k.remap(down(LogicalKeyboardKey.keyK), typing: true).logicalKey, LogicalKeyboardKey.keyK);
    expect(k.remap(up(LogicalKeyboardKey.keyK)).logicalKey, LogicalKeyboardKey.keyK);
    expect(k.remap(down(LogicalKeyboardKey.arrowUp), typing: true).logicalKey, LogicalKeyboardKey.arrowLeft);
    expect(k.remap(up(LogicalKeyboardKey.arrowUp)).logicalKey, LogicalKeyboardKey.arrowLeft);
  });

  test('every arrow stays on one direction: its own can only be left by being given away, and comes back when taken '
      'off another', () async {
    const u = LogicalKeyboardKey.arrowUp;
    expect(k.canRemoveMove(Nav.up, u), isFalse);
    await k.removeMove(Nav.up, u);
    expect(k.moves[Nav.up], [u]);
    expect(await k.assignMove(Nav.left, u), 'Up'); // moved, and said
    expect(k.moves[Nav.up], isEmpty);
    expect(k.canRemoveMove(Nav.left, u), isTrue);
    await k.removeMove(Nav.left, u);
    expect(k.moves[Nav.left], [LogicalKeyboardKey.arrowLeft]);
    expect(k.moves[Nav.up], [u], reason: 'back on its own');
  });

  test('a key has one job: an action gives way to a direction and the other way round; an arrow stays on the reader '
      "lists, for its direction; the only key that shows the controls can't go", () async {
    const key = LogicalKeyboardKey.keyK;
    await k.assign(ReaderAction.zoomIn, key);
    expect(await k.assignMove(Nav.right, key), ReaderAction.zoomIn.label);
    expect(k.actionFor(key), isNull);
    await k.assign(ReaderAction.zoomIn, key);
    expect(k.moved(key), key, reason: 'off Right');
    expect(k.actionFor(key), ReaderAction.zoomIn);

    await k.assignMove(Nav.left, LogicalKeyboardKey.arrowUp);
    expect(k.actionFor(LogicalKeyboardKey.arrowUp), ReaderAction.previous, reason: 'kept: another key may send it');

    for (final c in List.of(k.keys[ReaderAction.controls]!)) {
      await k.remove(ReaderAction.controls, c);
    }
    final last = k.keys[ReaderAction.controls]!.single;
    await k.assignMove(Nav.up, last);
    expect(k.moved(last), last);
    expect(k.keys[ReaderAction.controls], [last]);
  });

  test('an arrow given to a reader action goes on as the arrow it now is: what the reader will get; the side menu, '
      'which looks before the change, gets it as pressed', () async {
    await k.assignMove(Nav.left, LogicalKeyboardKey.arrowUp);
    await k.assign(ReaderAction.zoomIn, LogicalKeyboardKey.arrowUp);
    expect(k.keys[ReaderAction.zoomIn], contains(LogicalKeyboardKey.arrowLeft));
    expect(k.keys[ReaderAction.zoomIn], isNot(contains(LogicalKeyboardKey.arrowUp)));
    await k.assign(ReaderAction.openMenu, LogicalKeyboardKey.arrowUp);
    expect(k.keys[ReaderAction.openMenu], [LogicalKeyboardKey.arrowUp]);
  });

  test('saved directions: unreadable, or leaving out an arrow, load the usual ones', () async {
    final none = jsonEncode({for (final m in Nav.values) m.name: <int>[]});
    for (final raw in ['not json', '[1]', '{"up": "x"}', '{"up": [1.5]}', none]) {
      SharedPreferences.setMockInitialValues({'reader.moves': raw});
      await k.load();
      expect(k.isDefault, isTrue, reason: raw);
    }
  });

  testWidgets('sideways, on a screen: the focus goes the way set, keys listened to at the keyboard itself get the key '
      'as pressed', (tester) async {
    k.remapKeysToFocus();
    addTearDown(k.stopRemappingKeys);
    addTearDown(k.reset);
    await sideways();
    final seen = <LogicalKeyboardKey>[];
    bool watch(KeyEvent e) {
      if (e is KeyDownEvent) seen.add(e.logicalKey);
      return false;
    }

    HardwareKeyboard.instance.addHandler(watch);
    addTearDown(() => HardwareKeyboard.instance.removeHandler(watch));
    final a = FocusNode(), b = FocusNode();
    addTearDown(a.dispose);
    addTearDown(b.dispose);
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: Row(children: [
      TextButton(focusNode: a, autofocus: true, onPressed: () {}, child: const Text('A')),
      const SizedBox(width: 100),
      TextButton(focusNode: b, onPressed: () {}, child: const Text('B')),
    ]))));
    await tester.pump();
    expect(a.hasPrimaryFocus, isTrue);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown); // the controller's Down: right
    await tester.pump();
    expect(b.hasPrimaryFocus, isTrue);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp); // its Up: left
    await tester.pump();
    expect(a.hasPrimaryFocus, isTrue);
    expect(seen, [LogicalKeyboardKey.arrowDown, LogicalKeyboardKey.arrowUp]);
  });

  testWidgets('a key set as OK presses what the focus is on, and shows the controls in the reader as OK does', (tester) async {
    k.remapKeysToFocus();
    addTearDown(k.stopRemappingKeys);
    addTearDown(k.reset);
    await k.assignMove(Nav.ok, LogicalKeyboardKey.keyK);
    expect(k.moves[Nav.ok], [LogicalKeyboardKey.enter, LogicalKeyboardKey.keyK]);
    var pressed = 0;
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: TextButton(autofocus: true, onPressed: () => pressed++,
        child: const Text('A')))));
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.keyK);
    await tester.pumpAndSettle();
    expect(pressed, 1);

    final api = noNetwork(ReaderServer.new);
    await tester.pumpWidget(MaterialApp(home: ReaderScreen(api: api, book: api.theBook)));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.byType(Slider), findsNothing);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyK);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byType(Slider), findsOneWidget, reason: 'the controls are up');
    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
  });

  testWidgets('a letter set to a direction moves the focus, and types in a text box', (tester) async {
    k.remapKeysToFocus();
    addTearDown(k.stopRemappingKeys);
    addTearDown(k.reset);
    await k.assignMove(Nav.right, LogicalKeyboardKey.keyK);
    final seen = <LogicalKeyboardKey>[];
    final box = FocusNode(), field = FocusNode();
    addTearDown(box.dispose);
    addTearDown(field.dispose);
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: Column(children: [
      Focus(focusNode: box, autofocus: true, onKeyEvent: (_, e) {
        if (e is KeyDownEvent) seen.add(e.logicalKey);
        return KeyEventResult.handled;
      }, child: const SizedBox(height: 50)),
      Focus(onKeyEvent: (_, e) {
        if (e is KeyDownEvent) seen.add(e.logicalKey);
        return KeyEventResult.ignored;
      }, child: TextField(focusNode: field)),
    ]))));
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.keyK);
    field.requestFocus();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.keyK);
    expect(seen, [LogicalKeyboardKey.arrowRight, LogicalKeyboardKey.keyK]);
  });

  testWidgets('Settings: Add on Left takes the key as pressed, even one that moves another way already; a chip off '
      'sends an arrow home', (tester) async {
    k.remapKeysToFocus();
    addTearDown(k.stopRemappingKeys);
    addTearDown(k.reset);
    setView(tester, const Size(1000, 3000));
    await k.assignMove(Nav.right, LogicalKeyboardKey.arrowUp);
    await tester.pumpWidget(MaterialApp(home: AppSettingsScreen(api: noNetwork(ReaderServer.new), onSignOut: () {},
        initialPage: SettingsPage.keys)));
    await tester.pump();
    final left = find.descendant(of: find.ancestor(of: find.text('Left'), matching: find.byType(Column)).first,
        matching: find.text('Add'));
    await tester.tap(left);
    await tester.pumpAndSettle();
    expect(find.text('Left: press a key'), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await tester.pumpAndSettle();
    expect(k.moves[Nav.left], contains(LogicalKeyboardKey.arrowUp), reason: 'not the → it was sent as');
    expect(k.moves[Nav.right], [LogicalKeyboardKey.arrowRight]);
    await tester.tap(find.descendant(of: find.ancestor(of: find.text('Left'), matching: find.byType(Column)).first,
        matching: find.text(ReaderKeys.nameOf(LogicalKeyboardKey.arrowUp))));
    await tester.pumpAndSettle();
    expect(k.moves[Nav.up], contains(LogicalKeyboardKey.arrowUp));
    expect(k.isDefault, isTrue);
  });

  testWidgets('the reader goes by the arrow a key stands for: with Up set as Right, Up turns forward', (tester) async {
    k.remapKeysToFocus();
    addTearDown(k.stopRemappingKeys);
    addTearDown(k.reset);
    await k.assignMove(Nav.right, LogicalKeyboardKey.arrowUp);
    final api = noNetwork(ReaderServer.new);
    await tester.pumpWidget(MaterialApp(home: ReaderScreen(api: api, book: api.theBook)));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    double page() => tester.widget<PageView>(find.byType(PageView)).controller!.page!;
    expect(page(), 0);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(page(), 1);
    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
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
}
