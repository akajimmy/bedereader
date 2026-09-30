import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:komga_reader/screens/login.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Sign-in: no server address filled in for a new user (just an example hint); the last address when signing in
/// again after Sign out.
void main() {
  TextField field(WidgetTester tester, String label) => tester.widget<TextField>(
      find.byWidgetPredicate((w) => w is TextField && w.decoration?.labelText == label));

  testWidgets('first sign-in: the server field is empty, with an example hint', (tester) async {
    SharedPreferences.setMockInitialValues({});
    await tester.pumpWidget(MaterialApp(home: LoginScreen(onSignedIn: (_) async {})));
    await tester.pump();
    expect(field(tester, 'Server').controller!.text, isEmpty);
    expect(field(tester, 'Server').decoration!.hintText, 'http://192.168.1.10:25600');
  });

  testWidgets('signing in again: the last server address is filled in', (tester) async {
    SharedPreferences.setMockInitialValues({'server': 'http://nas.local:25600'});
    await tester.pumpWidget(MaterialApp(home: LoginScreen(onSignedIn: (_) async {})));
    await tester.pump();
    expect(field(tester, 'Server').controller!.text, 'http://nas.local:25600');
    expect(field(tester, 'API key').controller!.text, isEmpty); // never kept
  });

  test('the server address is tidied up: spaces out, http:// added, trailing slashes off', () {
    String? s(String typed) => serverAddress(typed);
    expect(s('192.168.1.10: 25600'), 'http://192.168.1.10:25600'); // as typed on the tablet (user's screenshot)
    expect(s(' http://nas.local:25600/ '), 'http://nas.local:25600');
    expect(s('https://komga.example.org'), 'https://komga.example.org');
    expect(s('HTTP://192.168.1.10:25600'), 'HTTP://192.168.1.10:25600');
    expect(s(''), isNull);
    expect(s('ftp://192.168.1.10'), isNull);
    expect(s('http://'), isNull);
  });

  testWidgets("not an address: a plain message with Details, not the raw FormatException", (tester) async {
    SharedPreferences.setMockInitialValues({});
    await tester.pumpWidget(MaterialApp(home: LoginScreen(onSignedIn: (_) async {})));
    await tester.pump();
    await tester.enterText(find.byWidgetPredicate((w) => w is TextField && w.decoration?.labelText == 'Server'),
        'ftp://nas');
    await tester.tap(find.text('Connect'));
    await tester.pump();
    expect(find.text("That isn't a server address. It should look like 192.168.1.10:25600."), findsOneWidget);
    expect(find.text('Details'), findsOneWidget);
    expect(find.textContaining('FormatException'), findsNothing);
  });

  testWidgets('an address typed without http:// connects, and the field shows what was used', (tester) async {
    SharedPreferences.setMockInitialValues({});
    await tester.pumpWidget(MaterialApp(home: LoginScreen(onSignedIn: (_) async {})));
    await tester.pump();
    await tester.enterText(find.byWidgetPredicate((w) => w is TextField && w.decoration?.labelText == 'Server'),
        '192.168.1.10: 25600');
    await tester.tap(find.text('Connect'));
    await tester.pump();
    expect(field(tester, 'Server').controller!.text, 'http://192.168.1.10:25600');
    expect(find.textContaining('FormatException'), findsNothing);
  });
}
