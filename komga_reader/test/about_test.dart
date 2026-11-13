import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:komga_reader/remote_log.dart';
import 'package:komga_reader/screens/about.dart';
import 'package:komga_reader/screens/app_log_screen.dart';
import 'package:komga_reader/widgets/setting_rows.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/helpers.dart';

/// The About screen: the version it shows. (What it lists is not tested - no wording tests; test audit, 2026-10-23.)
void main() {
  testWidgets("the version: as the app's platform side reports it (name and build); unknown if it can't say",
      (tester) async {
    // test audit, 2026-09-30: no test checked the version shown
    setView(tester, const Size(900, 1400));
    const channel = MethodChannel('komga_reader/screen'); // lib/screen.dart: getAppVersion
    final messenger = tester.binding.defaultBinaryMessenger;
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    var asked = 0;
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method != 'appVersion') return null;
      asked++;
      return {'name': '1.2.0', 'code': 57};
    });
    await tester.pumpWidget(MaterialApp(home: const AboutScreen()));
    await tester.pump();
    expect(asked, 1);
    expect(find.text('Version 1.2.0 (build 57)'), findsOneWidget);

    messenger.setMockMethodCallHandler(channel, (call) async => throw PlatformException(code: 'none'));
    await tester.pumpWidget(MaterialApp(home: AboutScreen(key: UniqueKey())));
    await tester.pump();
    expect(find.text('Version unknown'), findsOneWidget);
  });

  group('the remote log, hidden until asked for (user, 2026-11-12: for the App Store)', () {
    final r = RemoteLog.instance;
    setUp(() {
      SharedPreferences.setMockInitialValues({});
      r.reset();
    });
    tearDown(r.reset);

    Finder group() => find.byKey(RemoteLogGroup.groupKey);
    Future<void> settings(WidgetTester tester) async {
      setView(tester, const Size(900, 1400));
      await tester.pumpWidget(const MaterialApp(home: Scaffold(body: SingleChildScrollView(child: RemoteLogGroup()))));
    }

    testWidgets('its settings are nowhere until shown; shown, or on, they are there', (tester) async {
      await settings(tester);
      expect(group(), findsNothing, reason: 'a fresh install: nothing');
      await tester.runAsync(() => r.setShown(true));
      await tester.pump();
      expect(group(), findsOneWidget);
      await tester.runAsync(() => r.setShown(false));
      r.on = true; // (set up on a device before: it can always be turned off)
      r.notifyListeners();
      await tester.pump();
      expect(group(), findsOneWidget);
    });

    testWidgets('seven taps on the version in About show it, kept on the device; six do nothing', (tester) async {
      setView(tester, const Size(900, 1400));
      await tester.pumpWidget(const MaterialApp(home: AboutScreen()));
      await tester.pump();
      for (var i = 0; i < RemoteLog.tapsToShow - 1; i++) {
        await tester.tap(find.byKey(AboutScreen.versionKey));
        await tester.pump();
      }
      expect(r.shown, isFalse);
      await tester.tap(find.byKey(AboutScreen.versionKey));
      await tester.pump();
      expect(r.shown, isTrue);
      expect((await tester.runAsync(SharedPreferences.getInstance))!.getBool('remoteLog.shown'), isTrue);
      await tester.runAsync(() async {
        r.reset();
        await r.load();
      });
      expect(r.visible, isTrue, reason: 'kept across a restart');
    });

    testWidgets('off, it can be hidden again from its own settings', (tester) async {
      await tester.runAsync(() => r.setShown(true));
      await settings(tester);
      await tester.tap(find.descendant(of: group(), matching: find.byType(ActionRow)).last);
      await tester.pump();
      expect(r.shown, isFalse);
      expect(group(), findsNothing);
    });
  });
}
