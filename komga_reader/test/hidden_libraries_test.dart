import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:komga_reader/api.dart';
import 'package:komga_reader/combined_source.dart';
import 'package:komga_reader/hidden_libraries.dart';
import 'package:komga_reader/local/local_library.dart';
import 'package:komga_reader/local/local_source.dart';
import 'package:komga_reader/screens/app_settings.dart';
import 'package:komga_reader/widgets/setting_rows.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/helpers.dart';

/// Libraries hidden on this device: left out of every request that spans libraries, of the lists of libraries, and
/// switchable in Settings (the last one shown can't be).
void main() {
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await HiddenLibraries.instance.load();
  });

  const libs = [
    {'id': 'L1', 'name': 'Ongoing'},
    {'id': 'L2', 'name': 'Archive'},
    {'id': 'L3', 'name': 'Demo Library'},
  ];

  /// A Komga whose requests are recorded, answered with the three libraries or an empty page - only on the paths
  /// these tests use: anything else fails the test (test audit, 2026-10-07: every path was answered).
  (Komga, List<Uri>) recorded() {
    final asked = <Uri>[], unexpected = <String>[];
    addTearDown(() => expect(unexpected, isEmpty, reason: 'requests no test here expects'));
    final client = MockClient((r) async {
      asked.add(r.url);
      final path = r.url.path;
      if (path == '/api/v1/libraries') return http.Response(jsonEncode(libs), 200);
      if (const {'/api/v1/series', '/api/v1/books', '/api/v1/books/ondeck'}.contains(path)) {
        return http.Response(jsonEncode({'content': [], 'totalElements': 0, 'last': true}), 200);
      }
      unexpected.add('${r.method} ${r.url}');
      return http.Response('not in this test', 404);
    });
    return (http.runWithClient(() => Komga('http://test', 'k'), () => client), asked);
  }

  test('nothing hidden: no library filter; one hidden: only the shown ones are asked for', () async {
    final (api, asked) = recorded();
    await api.series();
    expect(asked.last.queryParametersAll['library_id'], isNull);

    await HiddenLibraries.instance.setHidden('L2', true);
    await api.series();
    expect(asked.last.queryParametersAll['library_id'], ['L1', 'L3']);
    await api.inProgress(); // Home's rows too
    expect(asked.last.queryParametersAll['library_id'], ['L1', 'L3']);
    await api.onDeck();
    expect(asked.last.queryParametersAll['library_id'], ['L1', 'L3']);
    await api.searchBooks('x');
    expect(asked.last.queryParametersAll['library_id'], ['L1', 'L3']);

    await api.series(libraryId: 'L1'); // one library asked for by name: just that one
    expect(asked.last.queryParametersAll['library_id'], ['L1']);

    expect([for (final l in await api.visibleLibraries()) l['id']], ['L1', 'L3']);
    expect((await api.libraries()).length, 3); // the full list stays (downloads name a book's library from it)
  });

  testWidgets('Settings > Libraries: a switch per Komga library; the last one shown stays', (tester) async {
    setView(tester, const Size(1000, 2400));
    final (api, _) = recorded();
    await tester.pumpWidget(MaterialApp(home: AppSettingsScreen(api: api, onSignOut: () {},
        initialPage: SettingsPage.libraries)));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(SwitchRow, 'Archive'));
    await tester.pumpAndSettle();
    expect(HiddenLibraries.instance.isHidden('L2'), isTrue);
    expect((await SharedPreferences.getInstance()).getStringList('libraries.hidden'), ['L2']); // kept on the device
    await tester.tap(find.widgetWithText(SwitchRow, 'Demo Library'));
    await tester.pumpAndSettle();
    final last = tester.widget<SwitchListTile>(
        find.descendant(of: find.widgetWithText(SwitchRow, 'Ongoing'), matching: find.byType(SwitchListTile)));
    expect(last.onChanged, isNull); // Ongoing is the last one shown
  }, tags: 'slow');

  testWidgets("Komga and a local library side by side: Settings > Libraries switches Komga's libraries only, Library "
      "& Home has none (user, 2026-10-27: all library management in Libraries); a local library isn't hidden - one "
      "that isn't wanted isn't added", (tester) async {
    setView(tester, const Size(1000, 3000));
    final (komga, _) = recorded();
    final (local, data) = (await tester.runAsync(() async {
      final data = await Directory.systemTemp.createTemp('hidden_local');
      final folder = await Directory('${data.path}${Platform.pathSeparator}Comics').create();
      return (await LocalSource.open(data, [LocalLibrary.at(folder.path)]), data);
    }))!;
    addTearDown(() => tester.runAsync(() async {
          await local.closeFiles();
          await local.store.written;
          await data.delete(recursive: true);
        }));
    final api = CombinedSource(komga, local: local);
    Future<void> page(SettingsPage p) async {
      await tester.pumpWidget(MaterialApp(home: AppSettingsScreen(key: UniqueKey(), api: api, onSignOut: () {},
          initialPage: p)));
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50))); // (the libraries asked for)
      await tester.pump();
    }

    await page(SettingsPage.libraries);
    expect([for (final s in tester.widgetList<SwitchRow>(find.byType(SwitchRow))) s.title],
        containsAll(['Ongoing', 'Archive', 'Demo Library']));
    expect(find.widgetWithText(SwitchRow, 'Comics'), findsNothing, reason: 'the local library has no switch');
    await page(SettingsPage.library);
    expect(find.widgetWithText(SwitchRow, 'Ongoing'), findsNothing, reason: 'not in Library & Home any more');

    // a local library's id among the hidden ones (hidden there before): shown all the same
    await HiddenLibraries.instance.setHidden(local.folders.single.id, true);
    expect([for (final l in (await tester.runAsync(local.visibleLibraries))!) l['name']], ['Comics']);
  });
}
