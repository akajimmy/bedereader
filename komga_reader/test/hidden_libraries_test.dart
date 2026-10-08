import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:komga_reader/api.dart';
import 'package:komga_reader/hidden_libraries.dart';
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

  testWidgets('Settings: a switch per library; the last one shown stays', (tester) async {
    setView(tester, const Size(1000, 2400));
    final (api, _) = recorded();
    await tester.pumpWidget(MaterialApp(home: AppSettingsScreen(api: api, onSignOut: () {},
        initialPage: SettingsPage.library)));
    await tester.pumpAndSettle();
    expect(find.text('Libraries on this device'), findsOneWidget);
    await tester.tap(find.widgetWithText(SwitchRow, 'Archive'));
    await tester.pumpAndSettle();
    expect(HiddenLibraries.instance.isHidden('L2'), isTrue);
    expect((await SharedPreferences.getInstance()).getStringList('libraries.hidden'), ['L2']); // kept on the device
    await tester.tap(find.widgetWithText(SwitchRow, 'Demo Library'));
    await tester.pumpAndSettle();
    final last = tester.widget<SwitchListTile>(
        find.descendant(of: find.widgetWithText(SwitchRow, 'Ongoing'), matching: find.byType(SwitchListTile)));
    expect(last.onChanged, isNull); // Ongoing is the last one shown
  });
}
