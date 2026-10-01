import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:komga_reader/api.dart';
import 'package:komga_reader/licences.dart';
import 'package:komga_reader/screens/about.dart';
import 'package:komga_reader/widgets/server_status.dart';

/// Counts me() calls: About mustn't check the server.
class FakeKomga extends Komga {
  FakeKomga() : super('http://192.168.1.10:25600', 'k');
  int calls = 0;
  @override
  Future<Map<String, dynamic>?> me() async {
    calls++;
    return {'email': 'reader@example.com'};
  }

  @override
  Future<List<dynamic>> libraries() async => [];
}

/// The About screen. The server status (now in Settings > Server) and the side menu's order are tested in
/// app_settings_test (test audit, 2026-09-30).
void main() {
  testWidgets('About: name, author, licence, documents, AI disclosure, Komga credits - no server section', (tester) async {
    tester.view.physicalSize = const Size(900, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final api = FakeKomga();
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
}
