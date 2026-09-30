import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:komga_reader/api.dart';
import 'package:komga_reader/licences.dart';
import 'package:komga_reader/screens/about.dart';
import 'package:komga_reader/widgets/drawer.dart';
import 'package:komga_reader/widgets/server_status.dart';

/// me() answers with whatever [next] says: 'ok', 'refused' or 'down'.
class FakeKomga extends Komga {
  FakeKomga() : super('http://192.168.1.10:25600', 'k');
  String next = 'ok';
  int calls = 0;
  @override
  Future<Map<String, dynamic>?> me() async {
    calls++;
    if (next == 'refused') throw KomgaError(401, '/api/v2/users/me');
    if (next == 'down') throw KomgaUnreachable(baseUrl);
    return {'email': 'reader@example.com'};
  }

  @override
  Future<List<dynamic>> libraries() async => [];
}

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
    // the server's address and status are in Settings > Server & connection now
    expect(find.text('http://192.168.1.10:25600'), findsNothing);
    expect(find.byType(ServerStatus), findsNothing);
    expect(api.calls, 0);
  });

  testWidgets('server status (Settings): connected, key refused, unreachable - Retry checks again', (tester) async {
    final api = FakeKomga();
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: ServerStatus(api: api))));
    await tester.pump();
    expect(find.text('Connected as reader@example.com'), findsOneWidget);

    api.next = 'refused';
    await tester.tap(find.text('Retry'));
    await tester.pump();
    expect(find.textContaining("Komga no longer accepts this device's API key."), findsOneWidget);

    api.next = 'down';
    await tester.tap(find.text('Retry'));
    await tester.pump();
    expect(find.textContaining("Can't reach Komga at 192.168.1.10:25600."), findsOneWidget); // no http://
    expect(api.calls, 3);
  });

  testWidgets('side menu: Settings, then About, last; no App settings / Info / Reader settings / Sign out', (tester) async {
    final scaffold = GlobalKey<ScaffoldState>();
    await tester.pumpWidget(MaterialApp(home: Scaffold(key: scaffold,
        drawer: AppDrawer(api: FakeKomga(), onSignOut: () {}), body: const SizedBox())));
    scaffold.currentState!.openDrawer();
    await tester.pumpAndSettle();
    double y(String t) => tester.getTopLeft(find.text(t)).dy;
    expect(y('Settings') < y('About'), isTrue);
    for (final gone in ['App settings', 'Info', 'Reader settings', 'Sign out']) {
      expect(find.text(gone), findsNothing, reason: gone);
    }
    await tester.tap(find.text('About'));
    await tester.pumpAndSettle();
    expect(find.byType(AboutScreen), findsOneWidget);
  });
}
