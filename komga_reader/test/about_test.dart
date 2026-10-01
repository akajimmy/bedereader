import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:komga_reader/licences.dart';
import 'package:komga_reader/screens/about.dart';
import 'package:komga_reader/widgets/server_status.dart';

import 'support/helpers.dart';
import 'support/no_network.dart';
import 'support/status_server.dart';

/// The About screen. The server status (now in Settings > Server) and the side menu's order are tested in
/// app_settings_test (test audit, 2026-09-30).
void main() {
  testWidgets('About: name, author, licence, documents, AI disclosure, Komga credits - no server section', (tester) async {
    setView(tester, const Size(900, 1400));
    final api = noNetwork(StatusServer.new); // counts me() calls: About mustn't check the server
    await tester.pumpWidget(MaterialApp(home: AboutScreen(api: api)));
    await tester.pump();
    expect(find.text('About'), findsOneWidget); // the title
    expect(find.text(appName), findsOneWidget);
    expect(find.text(appAuthor), findsOneWidget);
    expect(find.text(appLicense), findsOneWidget);
    expect(find.text(aiDisclosure), findsOneWidget); // AI usage disclosure
    expect(find.text('Third-party software'), findsOneWidget);
    expect(find.text('komga.org'), findsOneWidget);
    // the server's address and status are in Settings > Server now
    expect(find.text('http://192.168.1.10:25600'), findsNothing);
    expect(find.byType(ServerStatus), findsNothing);
    expect(api.calls, 0);
  });

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
    await tester.pumpWidget(MaterialApp(home: AboutScreen(api: noNetwork(StatusServer.new))));
    await tester.pump();
    expect(asked, 1);
    expect(find.text('Version 1.2.0 (build 57)'), findsOneWidget);

    messenger.setMockMethodCallHandler(channel, (call) async => throw PlatformException(code: 'none'));
    await tester.pumpWidget(MaterialApp(home: AboutScreen(key: UniqueKey(), api: noNetwork(StatusServer.new))));
    await tester.pump();
    expect(find.text('Version unknown'), findsOneWidget);
  });
}
