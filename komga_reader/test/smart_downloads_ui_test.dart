import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:komga_reader/offline/downloads.dart';
import 'package:komga_reader/offline/smart_downloads.dart';
import 'package:komga_reader/screens/actions.dart';
import 'package:komga_reader/screens/downloads_screen.dart';
import 'package:komga_reader/widgets/download_badge.dart';
import 'package:komga_reader/widgets/smart_rule.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/helpers.dart';
import 'support/library_server.dart';
import 'support/no_network.dart';

/// Series S1 of four unread books, B1 to B4.
class FourBooks extends LibraryServer {
  @override
  Future<Map<String, dynamic>> seriesBooks(String seriesId,
      {List<String>? readStatus, String sort = 'metadata.numberSort,asc', int page = 0, int size = 500}) async {
    final all = [
      for (var n = 1; n <= 4; n++)
        {'id': 'B$n', 'seriesId': 'S1', 'seriesTitle': 'Silver Surfer', 'name': 'B$n', 'metadata': {'number': '$n'}},
    ];
    return {'content': all.take(size).toList(), 'totalElements': all.length};
  }
}

void main() {
  late Directory dir;
  final d = Downloads.instance, s = SmartDownloads.instance;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    d.reset();
    s.reset();
    dir = await Directory.systemTemp.createTemp('komga_smart_ui');
  });
  tearDown(() async {
    d.paused = false;
    d.store = null;
    await deleteTemp(dir);
  });

  Future<FourBooks> attached(WidgetTester tester) async {
    final api = noNetwork(FourBooks.new);
    await tester.runAsync(() async {
      await d.attach(api, root: dir);
      d.pauseAll(); // (queued only: nothing downloads here)
      // loaded, not started: no top-up runs here - it writes the queue to disk, which a widget test doesn't wait on
      // (code review, 2026-11-12); what a top-up does is smart_downloads_test's
      await s.load();
    });
    return api;
  }

  testWidgets("a series' menu sets its rule (user, 2026-11-12)",
      (tester) async {
    final api = await attached(tester);
    setView(tester, const Size(1000, 1800)); // (the whole menu on screen)
    await tester.pumpWidget(MaterialApp(home: Builder(builder: (context) => TextButton(
        onPressed: () => showSeriesActions(context, api,
            {'id': 'S1', 'name': 'Silver Surfer', 'metadata': {'title': 'Silver Surfer'}, 'booksCount': 4},
            onChanged: () {}),
        child: const Text('menu')))));
    await tester.tap(find.text('menu'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byIcon(smartIcon));
    await tester.tap(find.byIcon(smartIcon));
    await tester.pumpAndSettle();
    // the choices: Off, then 1 to 10 - the third is "the next 2"
    await tester.tap(find.descendant(of: find.byType(SimpleDialog), matching: find.byType(ListTile)).at(2));
    await tester.pumpAndSettle();
    expect(s.ruleFor(RuleKind.series, 'S1')!.keep, 2);
  });

  testWidgets("a rule's book has its own mark on the poster; one you downloaded, the tick", (tester) async {
    await attached(tester);
    for (final id in ['B1', 'B2']) {
      d.store!.books[id] = {'state': 'done', 'bytes': 1, 'book': {'id': id}};
    }
    s.books.add('B1');
    await tester.pumpWidget(const MaterialApp(home: Row(children: [DownloadBadge.book('B1'), DownloadBadge.book('B2')])));
    // (in the row's order: B1's, then B2's)
    final icons = tester.widgetList<Icon>(find.byType(Icon)).map((i) => i.icon).toList();
    expect(icons, [smartIcon, Icons.download_done]);
  });

  testWidgets("Downloads' Smart tab lists the rules, and one taken off goes", (tester) async {
    await attached(tester);
    await s.setRule(RuleKind.series, 'S1', 'Silver Surfer', 3);
    setView(tester, const Size(1000, 900));
    await tester.pumpWidget(const MaterialApp(home: DownloadsScreen()));
    await tester.tap(find.byType(Tab).at(2));
    await tester.pumpAndSettle();
    expect(find.widgetWithIcon(ListTile, smartIcon), findsOneWidget);
    await tester.tap(find.byIcon(Icons.close));
    await tester.pumpAndSettle();
    expect(s.rules, isEmpty);
    expect(find.widgetWithIcon(ListTile, smartIcon), findsNothing);
  });
}
