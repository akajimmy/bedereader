import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:komga_reader/update_check.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The version check (user, 2026-10-22: "links to github if a newer version than installed is available").
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late int asked;
  late http.Response Function() github;

  Map<String, dynamic> release(String tag, int? build) => {
        'tag_name': tag,
        'html_url': 'https://github.com/akajimmy/bedereader/releases/tag/$tag',
        'assets': [
          {'name': build == null ? 'BeDeReader-android.apk' : 'BeDeReader-${tag.substring(1)}-b$build-android.apk'},
          {'name': 'SHA256SUMS.txt'},
        ],
      };

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    asked = 0;
    github = () => http.Response(jsonEncode(release('v1.5.0', 150)), 200);
    UpdateCheck.client = () => MockClient((r) async {
          asked++;
          expect(r.url.toString(), UpdateCheck.latestUrl);
          return github();
        });
    UpdateCheck.installed = () async => ('1.4.0', 134);
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
  });
  tearDown(() => debugDefaultTargetPlatformOverride = null);

  final day0 = DateTime(2026, 10, 22, 9);

  test('a release with a higher build number: offered, with its page; the same or a lower one: not', () async {
    await UpdateCheck.instance.check(now: day0);
    expect(UpdateCheck.instance.available?.version, '1.5.0');
    expect(UpdateCheck.instance.available?.url, 'https://github.com/akajimmy/bedereader/releases/tag/v1.5.0');
    for (final b in [134, 120]) {
      SharedPreferences.setMockInitialValues({});
      github = () => http.Response(jsonEncode(release('v1.4.0', b)), 200);
      await UpdateCheck.instance.check(now: day0);
      expect(UpdateCheck.instance.available, isNull, reason: 'build $b against 134');
    }
  });

  test("a release whose files carry no build number: its version decides ('1.10.0' after '1.9.2')", () async {
    UpdateCheck.installed = () async => ('1.9.2', 99);
    github = () => http.Response(jsonEncode(release('v1.10.0', null)), 200);
    await UpdateCheck.instance.check(now: day0);
    expect(UpdateCheck.instance.available?.version, '1.10.0');
    expect(compareVersions('1.10.0', '1.9.2'), 1);
    expect(compareVersions('1.4.0', '1.4'), 0);
  });

  test('at most once a day: the answer kept meanwhile; a day on, asked again', () async {
    await UpdateCheck.instance.check(now: day0);
    await UpdateCheck.instance.check(now: day0.add(const Duration(hours: 5)));
    expect(asked, 1);
    expect(UpdateCheck.instance.available?.version, '1.5.0', reason: 'the kept answer');
    await UpdateCheck.instance.check(now: day0.add(const Duration(days: 1, minutes: 1)));
    expect(asked, 2);
  });

  test('installed since (the kept answer is no newer than this build): not offered', () async {
    await UpdateCheck.instance.check(now: day0);
    UpdateCheck.installed = () async => ('1.5.0', 150);
    await UpdateCheck.instance.check(now: day0.add(const Duration(hours: 1)));
    expect(UpdateCheck.instance.available, isNull);
  });

  test('iOS (TestFlight) is never asked; GitHub failing shows nothing and is asked again next start', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    await UpdateCheck.instance.check(now: day0);
    expect(asked, 0);
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    github = () => http.Response('rate limited', 403);
    await UpdateCheck.instance.check(now: day0);
    expect(UpdateCheck.instance.available, isNull);
    github = () => http.Response(jsonEncode(release('v1.5.0', 150)), 200);
    await UpdateCheck.instance.check(now: day0.add(const Duration(minutes: 1)));
    expect(asked, 2, reason: 'a failure is not a check: asked again');
    expect(UpdateCheck.instance.available?.version, '1.5.0');
  });

  testWidgets("Home's line: 'Get it' opens the release page; x puts it away for that version, not the next",
      (tester) async {
    final opened = <Object?>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(const MethodChannel('komga_reader/screen'),
        (c) async {
      if (c.method == 'openUrl') opened.add(c.arguments);
      return true;
    });
    addTearDown(() => tester.binding.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('komga_reader/screen'), null));
    await tester.runAsync(() => UpdateCheck.instance.check(now: day0));
    await tester.pumpWidget(const MaterialApp(home: Scaffold(body: UpdateNotice())));
    expect(find.text('BeDeReader 1.5.0 is available'), findsOneWidget);
    await tester.tap(find.text('Get it'));
    await tester.pump();
    expect(opened, ['https://github.com/akajimmy/bedereader/releases/tag/v1.5.0']);
    await tester.tap(find.byTooltip('Not now'));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
    await tester.pump();
    expect(find.byKey(const ValueKey('update-notice')), findsNothing);
    // the next release: back
    github = () => http.Response(jsonEncode(release('v1.6.0', 160)), 200);
    await tester.runAsync(() => UpdateCheck.instance.check(now: day0.add(const Duration(days: 2))));
    await tester.pump();
    expect(find.text('BeDeReader 1.6.0 is available'), findsOneWidget);
    debugDefaultTargetPlatformOverride = null; // (a widget test must leave it unset itself)
  });
}
