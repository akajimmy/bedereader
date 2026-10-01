import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:komga_reader/offline/connection.dart';
import 'package:komga_reader/offline/downloads.dart';
import 'package:komga_reader/screens/home.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/app_shell.dart';
import 'support/helpers.dart';
import 'support/offline_store.dart';

/// Starting the app with offline mode on (by hand, remembered): it runs on the downloaded books, and nothing talks to
/// the server - the download queue waits, the connection doesn't check (code review, 2026-09-30: the queue used to
/// start before offline mode was applied).
void main() {
  const url = 'http://komga.test:25600';

  /// The app as last left: signed in, offline by hand, books downloaded and one still in the queue.
  Future<ShellKomga> start(WidgetTester tester) async {
    final dir = appStorage(tester);
    SharedPreferences.setMockInitialValues({'server': url, 'apiKey': 'k', 'offline.forced': true});
    await tester.runAsync(() async {
      final downloads = Directory('${dir.path}${Platform.pathSeparator}downloads');
      await buildStore(downloads);
      await File('${downloads.path}${Platform.pathSeparator}server.json').writeAsString(jsonEncode({'url': url}));
      await File('${downloads.path}${Platform.pathSeparator}queue.json')
          .writeAsString(jsonEncode([{'bookId': 'B9', 'title': 'Waiting #1', 'state': 'queued'}]));
    });
    final komga = ShellKomga();
    await komga.pumpApp(tester);
    await waitUntil(() => Connection.instance.online != null && Downloads.instance.ready, tester: tester,
        timeout: const Duration(seconds: 5), reason: 'the app to start');
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 200))); // anything it would send
    await tester.pump();
    return komga;
  }

  testWidgets('the download queue and the connection contact nothing: the queued book waits, offline Home shows',
      (tester) async {
    final requests = (await start(tester)).requests;
    expect(Connection.instance.offline, isTrue);
    await waitUntil(() => shows(find.text('Offline mode - showing downloaded books')), tester: tester,
        timeout: const Duration(seconds: 5), reason: 'offline Home');
    expect(find.byType(HomeScreen), findsOneWidget);
    expect(Downloads.instance.jobFor('B9')?.state, JobState.queued, reason: 'still waiting');
    expect(Downloads.instance.hold, isTrue);
    // the queue would ask for the book first (then its pages); the connection's check is "me"
    expect(requests.where((r) => r.contains('/books/B9') || r.contains('/pages/') || r.contains('/users/me')), isEmpty,
        reason: '$requests');
  });

  // Bug found 2026-09-30 (missing-tests audit): _restore loaded AppSettings, Pins and On deck hidden with the online
  // client (3 x GET client-settings) before offline mode was applied, and the first Home was built on the online
  // client (GET libraries, books, books/ondeck). Fixed in main.dart _restore.
  testWidgets('forced-offline start: nothing at all is sent to Komga', (tester) async {
    final komga = await start(tester);
    expect(komga.requests, isEmpty);
  });

  // an offline start loads the account's things from this device only; going online fetches them (user, 2026-09-30)
  testWidgets('then going online: the reader settings, pins and On deck hidden are fetched from Komga',
      (tester) async {
    final komga = await start(tester);
    await tester.runAsync(Connection.instance.goOnline);
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 200)));
    await tester.pump();
    expect(Connection.instance.offline, isFalse);
    expect(komga.requests.where((r) => r == 'GET /api/v1/client-settings/user/list').length, 3,
        reason: 'one each: reader settings, pins, On deck hidden - ${komga.requests}');
  });
}
