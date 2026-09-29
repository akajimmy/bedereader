import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:komga_reader/api.dart';
import 'package:komga_reader/licences.dart';
import 'package:komga_reader/screens/info.dart';
import 'package:komga_reader/widgets/drawer.dart';

/// me() answers with whatever [next] says: 'ok', 'refused' or 'down'.
class FakeKomga extends Komga {
  FakeKomga() : super('http://10.0.0.23:25600', 'k');
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
  testWidgets('info: name, author, licence placeholder, server address, status, Komga credits', (tester) async {
    tester.view.physicalSize = const Size(900, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final api = FakeKomga();
    await tester.pumpWidget(MaterialApp(home: InfoScreen(api: api)));
    await tester.pump();
    expect(find.text(appName), findsOneWidget);
    expect(find.text(appAuthor), findsOneWidget);
    expect(find.text(appLicense), findsOneWidget);
    expect(find.text(aiDisclosure), findsOneWidget); // AI usage disclosure
    expect(find.text('Third-party software'), findsOneWidget);
    expect(find.text('http://10.0.0.23:25600'), findsOneWidget);
    expect(find.text('Connected as reader@example.com'), findsOneWidget);
    expect(find.text('komga.org'), findsOneWidget);

    api.next = 'refused';
    await tester.tap(find.text('Retry'));
    await tester.pump();
    expect(find.text('Reachable, but the API key was refused'), findsOneWidget);

    api.next = 'down';
    await tester.tap(find.text('Retry'));
    await tester.pump();
    expect(find.text("Can't reach Komga at http://10.0.0.23:25600"), findsOneWidget);
    expect(api.calls, 3);
  });

  testWidgets('side menu: Info comes last, after App settings (Reader settings and Sign out moved to App settings)',
      (tester) async {
    final scaffold = GlobalKey<ScaffoldState>();
    await tester.pumpWidget(MaterialApp(home: Scaffold(key: scaffold,
        drawer: AppDrawer(api: FakeKomga(), onSignOut: () {}), body: const SizedBox())));
    scaffold.currentState!.openDrawer();
    await tester.pumpAndSettle();
    double y(String t) => tester.getTopLeft(find.textContaining(t)).dy;
    expect(y('App settings') < y('Info'), isTrue);
    expect(find.text('Reader settings'), findsNothing);
    expect(find.text('Sign out'), findsNothing);
    await tester.tap(find.text('Info'));
    await tester.pumpAndSettle();
    expect(find.byType(InfoScreen), findsOneWidget);
  });
}
