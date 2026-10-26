import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:komga_reader/screens/about.dart';

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
}
