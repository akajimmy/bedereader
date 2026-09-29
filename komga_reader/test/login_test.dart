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
}
