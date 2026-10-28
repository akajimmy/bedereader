// No server mode (rebuild step 7): the app on the local libraries alone. The sign-in screen's Use without a server,
// Settings > Server and sync in that mode (Add a Komga server - its one place - and Leave), the sign-in opened to add
// a server. (The combined source's side, and the setting itself: combined_source_test.dart.)
import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:komga_reader/api.dart' show Komga;
import 'package:komga_reader/combined_source.dart';
import 'package:komga_reader/home_sections.dart';
import 'package:komga_reader/local/local_source.dart';
import 'package:komga_reader/screens/app_settings.dart';
import 'package:komga_reader/screens/login.dart';
import 'package:komga_reader/widgets/error_text.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/no_network.dart';
import 'support/status_server.dart';

void main() {
  late Directory data;
  late LocalSource local;

  // opened here, outside the widget tests: they don't wait on the disk
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await HomeSections.instance.load();
    data = await Directory.systemTemp.createTemp('no_server');
    local = await LocalSource.open(data, const []);
  });
  tearDown(() async {
    await local.closeFiles();
    await data.delete(recursive: true);
  });

  group('the sign-in screen', () {
    testWidgets('Use without a server: asked once, however often it is pressed while it works', (tester) async {
      final asked = Completer<void>();
      var calls = 0;
      await tester.pumpWidget(MaterialApp(home: LoginScreen(onSignedIn: (_) async {}, onNoServer: (_) {
        calls++;
        return asked.future;
      })));
      await tester.pump();
      await tester.tap(find.byKey(LoginScreen.noServerKey));
      await tester.pump();
      await tester.tap(find.byKey(LoginScreen.noServerKey), warnIfMissed: false);
      await tester.pump();
      expect(calls, 1);
      asked.complete();
      await tester.pump();
    });

    testWidgets("Use without a server failing (the local libraries can't be kept here): said, still signed out",
        (tester) async {
      await tester.pumpWidget(MaterialApp(home: LoginScreen(onSignedIn: (_) async {},
          onNoServer: (_) async => throw StateError("can't be opened"))));
      await tester.pump();
      await tester.tap(find.byKey(LoginScreen.noServerKey));
      await tester.pump();
      expect(find.byType(ErrorText), findsOneWidget);
      expect(find.byType(LoginScreen), findsOneWidget);
    });

    testWidgets('not offered without a way to start it, nor on the screen that adds a server to No server mode',
        (tester) async {
      await tester.pumpWidget(MaterialApp(home: LoginScreen(onSignedIn: (_) async {})));
      await tester.pump();
      expect(find.byKey(LoginScreen.noServerKey), findsNothing);
      await tester.pumpWidget(MaterialApp(home: LoginScreen(onSignedIn: (_) async {}, onNoServer: (_) async {},
          adding: true)));
      await tester.pump();
      expect(find.byKey(LoginScreen.noServerKey), findsNothing);
    });
  });

  group('Settings > Server and sync in No server mode', () {
    Future<void> open(WidgetTester tester, {VoidCallback? onSignOut}) async {
      await tester.pumpWidget(MaterialApp(home: AppSettingsScreen(api: CombinedSource(local, local: local),
          onSignOut: onSignOut ?? () {}, initialPage: SettingsPage.server)));
      await tester.pump();
    }

    testWidgets("Add a Komga server: the sign-in, over Settings, made to add one - its sign-in goes to the app's "
        'switch to Komga', (tester) async {
      final before = AppSettingsScreen.appAddKomga;
      addTearDown(() => AppSettingsScreen.appAddKomga = before);
      Future<void> added(Komga _) async {}
      AppSettingsScreen.appAddKomga = added;
      await open(tester);
      expect(find.byKey(AppSettingsScreen.addKomgaKey), findsOneWidget);
      await tester.tap(find.byKey(AppSettingsScreen.addKomgaKey));
      await tester.pumpAndSettle();
      final login = tester.widget<LoginScreen>(find.byType(LoginScreen));
      expect(login.adding, isTrue);
      expect(login.onSignedIn, same(added));
      expect(Navigator.of(tester.element(find.byType(LoginScreen))).canPop(), isTrue, reason: 'a way back');
    });

    testWidgets('Leave No server mode: asked first; Cancel stays, Leave goes to the sign-in', (tester) async {
      var left = 0;
      await open(tester, onSignOut: () => left++);
      await tester.tap(find.byKey(AppSettingsScreen.leaveNoServerKey));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
      await tester.pumpAndSettle();
      expect(left, 0);
      await tester.tap(find.byKey(AppSettingsScreen.leaveNoServerKey));
      await tester.pumpAndSettle();
      await tester.tap(find.byType(TextButton).last);
      await tester.pumpAndSettle();
      expect(left, 1);
    });

    testWidgets("with Komga, neither row: the server's own page", (tester) async {
      await tester.pumpWidget(MaterialApp(home: AppSettingsScreen(api: CombinedSource(noNetwork(StatusServer.new), local: local),
          onSignOut: () {}, initialPage: SettingsPage.server)));
      await tester.pump();
      expect(find.byKey(AppSettingsScreen.addKomgaKey), findsNothing);
      expect(find.byKey(AppSettingsScreen.leaveNoServerKey), findsNothing);
    });
  });
}
