import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:komga_reader/offline/downloads.dart';
import 'package:komga_reader/screens/actions.dart';
import 'package:komga_reader/screens/downloads_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'downloads_test.dart' show FakeKomga;

void main() {
  late Directory dir;
  final d = Downloads.instance;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    dir = await Directory.systemTemp.createTemp('komga_downloads_ui');
  });
  tearDown(() async {
    d.paused = false;
    await dir.delete(recursive: true);
  });

  /// Pause and wait (on a real clock) until the worker has finished its last save, so the folder can go.
  Future<void> quiet(WidgetTester tester) => tester.runAsync(() async {
        d.pauseAll();
        for (var i = 0; i < 300 && d.busy; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }
      });

  testWidgets('book menu: Download queues the book; the Downloads screen shows it, then Remove download frees it',
      (tester) async {
    final api = FakeKomga();
    await tester.runAsync(() => d.attach(api, root: dir));
    d.pauseAll(); // keep it in the queue so the queue view can be checked
    final b = {'id': 'B1', 'seriesTitle': 'Silver Surfer', 'name': 'b1', 'metadata': {'number': '1', 'title': 'T'}};
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: Builder(builder: (context) => TextButton(
        onPressed: () => showBookActions(context, api, b, onChanged: () {}), child: const Text('menu'))))));
    await tester.tap(find.text('menu'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Download'));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
    await tester.pumpAndSettle();
    expect(d.jobFor('B1'), isNotNull);

    await tester.pumpWidget(const MaterialApp(home: DownloadsScreen()));
    expect(find.text('Queue · 1 · paused'), findsOneWidget);
    expect(find.text('Silver Surfer #1'), findsOneWidget);
    expect(find.text('Waiting'), findsOneWidget);

    await tester.runAsync(() async {
      d.resumeAll();
      for (var i = 0; i < 100 && !d.isDownloaded('B1'); i++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
    });
    await tester.pump();
    expect(find.text('Downloaded · 1'), findsOneWidget);
    expect(find.text('3 pages · 0.0 MB'), findsOneWidget);
    expect(find.text('Silver Surfer #1'), findsNWidgets(2)); // finished this session + downloaded

    await tester.runAsync(() async {
      await d.remove('B1');
    });
    await tester.pump();
    expect(find.text('Downloaded · 0'), findsOneWidget);
    await quiet(tester);
  });

  testWidgets('a failed download says why and offers Retry', (tester) async {
    await tester.runAsync(() async {
      await d.attach(FakeKomga(), root: dir);
      await d.setCap(100); // smaller than any book
      await d.add([{'id': 'B2', 'seriesTitle': 'Silver Surfer', 'metadata': {'number': '2'}}]);
      for (var i = 0; i < 100 && d.jobFor('B2')?.state != JobState.failed; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
    });
    await tester.pumpWidget(const MaterialApp(home: DownloadsScreen()));
    expect(find.textContaining('Failed: not enough room'), findsOneWidget);
    expect(find.byTooltip('Retry'), findsOneWidget);
    expect(find.text('Retry 1'), findsOneWidget); // retry-all in the top bar
    // (no need to lift the limit: each test starts from fresh settings)
    await quiet(tester);
  });
}
