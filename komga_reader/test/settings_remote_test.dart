import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:komga_reader/home_sections.dart';
import 'package:komga_reader/offline/connection.dart';
import 'package:komga_reader/offline/downloads.dart';
import 'package:komga_reader/screens/app_settings.dart';
import 'package:komga_reader/widgets/setting_rows.dart';
import 'package:komga_reader/settings.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/helpers.dart';
import 'support/no_network.dart';
import 'support/status_server.dart';

/// Settings with the remote: every page walked with the arrows; and every page at phone width with large text (test
/// audit, 2026-09-30: no test went through the pages the way the remote does, or laid them all out narrow).
///
/// Downloads are set up (so the Downloads page and Server's Offline group are there), night mode is on a schedule
/// (its times and Warmth show), and the test platform is Android (volume keys, rotation, Wi-Fi only): every row
/// the tablet has.

/// Two libraries, so Library & Home has its switches.
class TwoLibraries extends StatusServer {
  @override
  Future<List<dynamic>> libraries() async => [{'id': 'L1', 'name': 'Events'}, {'id': 'L2', 'name': 'Ongoing'}];
}

/// Settings' pages as the side list names them (a switch: a new page doesn't compile here until it's added).
String label(SettingsPage p) => switch (p) {
      SettingsPage.reading => 'Reading',
      SettingsPage.comics => 'Comics',
      SettingsPage.ebooks => 'eBooks',
      SettingsPage.keys => 'Remote and keys',
      SettingsPage.server => 'Server and sync',
      SettingsPage.library => 'Library & Home',
      SettingsPage.downloads => 'Downloads',
      SettingsPage.look => 'Look',
      SettingsPage.about => 'About',
    };

/// Downloads set up in a temporary folder (undone when the test ends).
Future<void> setUpDownloads(WidgetTester tester) async {
  final conn = Connection.instance, d = Downloads.instance;
  final dir = (await tester.runAsync(() => Directory.systemTemp.createTemp('komga_settings_remote')))!;
  addTearDown(() {
    conn.reset();
    d.store = null; // downloads not set up again, for the other tests
    dir.deleteSync(recursive: true);
  });
  await tester.runAsync(() => d.attach(noNetwork(StatusServer.new), root: dir, start: false));
  expect(d.ready, isTrue);
}

/// Every row on: night mode on a schedule (its times, Warmth). Put back when the test ends.
void everyRowShown() {
  final s = AppSettings.instance;
  s.setDisplay(const DisplayPrefs(night: true, nightSchedule: true));
  addTearDown(() => s.setDisplay(const DisplayPrefs()));
}

/// The row [n] is in (RowNav, widgets/setting_rows.dart - from its own list of rows, not a debug label).
FocusNode? rowOf(FocusNode n) => RowNav.rowOf(n);

FocusNode focus() => FocusManager.instance.primaryFocus!;

/// Whether [n]'s widget is inside what [f] finds.
bool under(FocusNode n, Finder f) {
  final target = f.evaluate().single;
  var found = false;
  n.context?.visitAncestorElements((e) => !(found = e == target));
  return found;
}

Rect rectOf(FocusNode n) {
  final box = n.context!.findRenderObject()! as RenderBox;
  return MatrixUtils.transformRect(box.getTransformTo(null), Offset.zero & box.size);
}

/// A focused control, for messages: its text, else its tooltip.
String name(FocusNode n) {
  final texts = find.descendant(of: find.byWidget(n.context!.widget), matching: find.byType(Text));
  final t = texts.evaluate().isEmpty ? null : (texts.evaluate().first.widget as Text).data;
  return t ?? n.context!.findAncestorWidgetOfExactType<Tooltip>()?.message ?? n.toString();
}

/// Opens Settings from a screen with one button, by the remote (OK), and walks [page]: Down along the list of pages
/// to it, OK, Right into it, Down to its last row and Up to its first - every row reached, the focus always on
/// screen - then Left back to the list, and Back out of Settings.
Future<void> walk(WidgetTester tester, SettingsPage page) async {
  setView(tester, const Size(1280, 720)); // the tablet's landscape: most pages are taller than this
  await setUpDownloads(tester);
  everyRowShown();
  await tester.pumpWidget(MaterialApp(home: Builder(builder: (context) => Scaffold(body: Center(child: TextButton(
      autofocus: true,
      onPressed: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) =>
          AppSettingsScreen(api: noNetwork(TwoLibraries.new), onSignOut: () {}))),
      child: const Text('Open settings')))))));
  await tester.pump();

  Future<void> press(LogicalKeyboardKey key) async {
    await tester.sendKeyEvent(key);
    await tester.pumpAndSettle(); // a row scrolled into view
  }

  await press(LogicalKeyboardKey.enter); // OK on "Open settings"
  expect(find.byType(AppSettingsScreen), findsOneWidget);

  final list = find.byType(ListView).first; // wide: the list of pages down the side
  final pageView = find.byType(ListView).at(1); // and the page beside it
  String? navLabel(FocusNode n) {
    for (final p in SettingsPage.values) {
      final tile = find.widgetWithText(ListTile, label(p));
      if (tile.evaluate().isNotEmpty && under(n, find.descendant(of: list, matching: tile))) return label(p);
    }
    return null;
  }

  // Down into the list (the top bar's back button comes first), then along it to the page, and OK
  for (var i = 0; i < 12 && navLabel(focus()) != label(page); i++) {
    await press(LogicalKeyboardKey.arrowDown);
  }
  expect(navLabel(focus()), label(page), reason: 'Down along the list reaches ${page.name}');
  await press(LogicalKeyboardKey.enter);
  expect(tester.widget<ListTile>(find.descendant(of: list, matching: find.widgetWithText(ListTile, label(page))))
      .selected, isTrue, reason: '${page.name} chosen');
  expect(find.descendant(of: pageView, matching: find.text(label(page))), findsOneWidget, reason: 'and shown');

  // the page's controls, in the order the focus tree has them, and the rows they're in
  final controls = [
    for (final n in focus().nearestScope!.traversalDescendants)
      if (n.canRequestFocus && !n.skipTraversal && under(n, pageView)) n,
  ];
  expect(controls, isNotEmpty);
  // the rows with something to focus, in the order they're laid out (top to bottom), each with its first control
  final rows = [
    ...{for (final c in controls) if (rowOf(c) != null) rowOf(c)!},
  ]..sort((a, b) => rectOf(a).top.compareTo(rectOf(b).top));
  final firstOf = {for (final r in rows) r: controls.firstWhere((c) => rowOf(c) == r)};
  String rowName(FocusNode? r) => r == null ? 'no row' : name(firstOf[r] ?? r);

  final screen = tester.getRect(pageView);
  void onScreen(String how) {
    final r = rectOf(focus());
    expect(r.top >= screen.top - 0.5 && r.bottom <= screen.bottom + 0.5, isTrue,
        reason: '${page.name}, $how: "${name(focus())}" ($r) has the focus but is off the screen ($screen)');
  }

  await press(LogicalKeyboardKey.arrowRight);
  expect(rows, contains(rowOf(focus())), reason: 'Right from the list goes into a row of ${page.name}');
  onScreen('Right');
  // Up to the first row, Down to the last, Up to the first again: each step to the next row that way (its first
  // control), none skipped, the focus on screen
  for (final (key, step, sweep) in [
    (LogicalKeyboardKey.arrowUp, -1, false),
    (LogicalKeyboardKey.arrowDown, 1, true),
    (LogicalKeyboardKey.arrowUp, -1, true),
  ]) {
    final end = step < 0 ? rows.first : rows.last;
    if (sweep) {
      expect(rowOf(focus()), step < 0 ? rows.last : rows.first, reason: 'a sweep starts at the other end');
    }
    while (rowOf(focus()) != end) {
      final at = rows.indexOf(rowOf(focus())!);
      final how = '${key.debugName} from "${rowName(rows[at])}"';
      await press(key);
      expect(rowOf(focus()), rows[at + step],
          reason: '${page.name}, $how: should be on "${rowName(rows[at + step])}", is on "${name(focus())}"');
      expect(focus(), firstOf[rows[at + step]], reason: "${page.name}, $how: the row's first control");
      onScreen(how);
    }
  }

  await press(LogicalKeyboardKey.arrowLeft); // from the first row's first control
  expect(navLabel(focus()), isNotNull, reason: '${page.name}: Left from the first row goes back to the list');

  // Back (the remote's, Android's): out of Settings, to where it was opened from
  await tester.binding.handlePopRoute();
  await tester.pumpAndSettle();
  expect(find.byType(AppSettingsScreen), findsNothing);
  expect(find.text('Open settings'), findsOneWidget);
}

/// The real Roboto (Android's font), from the Flutter SDK: the test font is about twice as wide as a real one, so a
/// layout test in it fails on rows that fit on any device (test audit, 2026-09-30). Once loaded, it's the font of
/// every test in this file (Material's default family on Android is Roboto).
Future<void> loadRoboto() async {
  final root = Platform.environment['FLUTTER_ROOT'];
  if (root == null) fail('FLUTTER_ROOT not set: the real font comes from the Flutter SDK');
  final loader = FontLoader('Roboto');
  for (final f in ['roboto-regular.ttf', 'roboto-medium.ttf']) {
    final file = File([root, 'bin', 'cache', 'artifacts', 'material_fonts', f].join(Platform.pathSeparator));
    loader.addFont(file.readAsBytes().then((b) => ByteData.sublistView(b)));
  }
  await loader.load();
}

void main() {
  setUpAll(loadRoboto);
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await HomeSections.instance.load();
  });

  group('by remote: into the page from the list, every row reached with Up / Down and on screen when focused, Left '
      'back to the list, Back leaves Settings -', () {
    // bug found 2026-09-30 (missing-tests audit): on Library & Home the library switches came after Home sections in
    // RowNav's order (the focus tree's: they're added once the libraries arrive); RowNav now goes by screen position
    for (final p in SettingsPage.values) {
      testWidgets(label(p), (tester) => walk(tester, p));
    }
  });

  // bug found 2026-09-30 (missing-tests audit): every page shared one ListView, so the next page opened at the last
  // one's scroll offset; each page has its own list now
  testWidgets('a page chosen from the list opens at its top, not scrolled as far as the page before it was',
      (tester) async {
    setView(tester, const Size(1280, 720));
    everyRowShown();
    await tester.pumpWidget(MaterialApp(home: AppSettingsScreen(api: noNetwork(TwoLibraries.new), onSignOut: () {},
        initialPage: SettingsPage.comics)));
    await tester.pump();
    final pageView = find.byType(ListView).at(1);
    await tester.drag(pageView, const Offset(0, -2000)); // to the end of a long page
    await tester.pumpAndSettle();
    expect(find.text('Comics'), findsOneWidget, reason: 'the list still has it'); // (the title is off the screen)
    await tester.tap(find.widgetWithText(ListTile, 'eBooks')); // another long page
    await tester.pumpAndSettle();
    expect(tester.state<ScrollableState>(find.descendant(of: pageView, matching: find.byType(Scrollable)).first)
        .position.pixels, 0, reason: 'eBooks opens at its top');
    expect(find.descendant(of: pageView, matching: find.text('eBooks')), findsOneWidget, reason: 'its title shows');
  });

  testWidgets("at phone width (320 x 640), the app's largest text size on top of a large device text size (130%), "
      'in a real font: every page lays out with nothing overflowing', (tester) async {
    setView(tester, const Size(320, 640));
    await setUpDownloads(tester);
    everyRowShown();
    final biggest = DisplayPrefs.textScales.reduce((a, b) => a > b ? a : b);
    for (final p in SettingsPage.values) {
      await tester.pumpWidget(MaterialApp(
        theme: ThemeData(fontFamily: 'Roboto'), // loaded in setUpAll
        // the app's text size on top of the device's, applied as main.dart does
        builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(1.3 * biggest)), child: child!),
        home: AppSettingsScreen(key: ValueKey(p), api: noNetwork(TwoLibraries.new), onSignOut: () {}, initialPage: p),
      ));
      await tester.pump();
      await tester.pump(); // the libraries, the shared segment width
      // narrow: the pages on top, under their headings (all of them, by the end of the scroll: at this size the last
      // heading's are below the part of the list that's built at first)
      final chips = <String>{};
      void seen() => chips.addAll([
            for (final c in tester.widgetList<ChoiceChip>(find.byType(ChoiceChip)))
              if (c.label case Text(:final data?)) data,
          ]);
      seen();
      expect(tester.takeException(), isNull, reason: '${p.name}: at the top');
      // down the whole page, a screen at a time (rows are only laid out once they're near the screen)
      final scroll = tester.state<ScrollableState>(find.byType(Scrollable).first).position;
      for (var i = 0; i < 40 && scroll.pixels < scroll.maxScrollExtent; i++) {
        await tester.drag(find.byType(Scrollable).first, const Offset(0, -500));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull, reason: '${p.name}: at ${scroll.pixels}');
        seen();
      }
      expect(chips, containsAll([for (final q in SettingsPage.values) label(q)]), reason: '${p.name}: every page on top');
      expect(scroll.pixels, scroll.maxScrollExtent, reason: '${p.name}: reached the end');
    }
  });
}
