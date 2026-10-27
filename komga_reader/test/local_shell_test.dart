// The local libraries through the real app shell (main.dart): opened once at the start and kept, whatever account is
// signed in or left - the experiment's review (10-26) found a sign-in opening a second copy that scanned over the
// first, and No server mode from the sign-in screen rebuilding a renamed library from its folder's name.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:komga_reader/api.dart' show Komga;
import 'package:komga_reader/combined_source.dart';
import 'package:komga_reader/local/local_source.dart';
import 'package:komga_reader/screens/home.dart';
import 'package:komga_reader/screens/login.dart';
import 'package:komga_reader/widgets/drawer.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/app_shell.dart';
import 'support/helpers.dart';

void main() {
  const url = 'http://komga.test:25600';

  /// The local libraries Home is showing beside (or instead of) Komga.
  LocalSource? localOf(WidgetTester tester) => shows(find.byType(HomeScreen))
      ? (tester.widget<HomeScreen>(find.byType(HomeScreen)).api as CombinedSource).local
      : null;

  testWidgets('signing out and in again: the same local libraries, not a second copy opened (it scanned over the '
      "first's index)", (tester) async {
    final dir = appStorage(tester);
    final folder = Directory('${dir.path}${Platform.pathSeparator}Comics')..createSync();
    SharedPreferences.setMockInitialValues({
      'server': url,
      'local.libraries': jsonEncode([{'name': 'Comics', 'path': folder.path}]),
    });
    FlutterSecureStorage.setMockInitialValues({'apiKey': 'k'});
    final komga = ShellKomga();
    await komga.pumpApp(tester);
    await waitUntil(() => localOf(tester) != null, tester: tester, timeout: const Duration(seconds: 5),
        reason: 'Home, with the local libraries open');
    final first = localOf(tester);

    AppDrawer.appSignOut();
    await waitUntil(() => shows(find.byType(LoginScreen)), tester: tester, reason: 'signed out');
    final login = tester.widget<LoginScreen>(find.byType(LoginScreen));
    final api = http.runWithClient(() => Komga(url, 'k'), komga.client);
    await tester.runAsync(() => login.onSignedIn(api));
    await waitUntil(() => localOf(tester) != null, tester: tester, timeout: const Duration(seconds: 5),
        reason: 'signed in again: Home');
    expect(identical(localOf(tester), first), isTrue, reason: 'the one opened at the start');
  }, tags: 'slow');

  testWidgets("No server mode from the sign-in screen: a renamed library keeps its name (it was rebuilt from its "
      "folder's)", (tester) async {
    final dir = appStorage(tester);
    final folder = Directory('${dir.path}${Platform.pathSeparator}Comics')..createSync();
    SharedPreferences.setMockInitialValues({
      'local.libraries': jsonEncode([{'name': 'My comics', 'path': folder.path}]),
    });
    FlutterSecureStorage.setMockInitialValues({});
    await ShellKomga().pumpApp(tester);
    await waitUntil(() => shows(find.byKey(LoginScreen.noServerKey)), tester: tester, reason: 'the sign-in screen');
    await tester.tap(find.byKey(LoginScreen.noServerKey));
    await waitUntil(() => localOf(tester) != null, tester: tester, timeout: const Duration(seconds: 5),
        reason: 'No server mode: Home');
    final local = localOf(tester)!;
    expect([for (final l in local.folders) l.name], ['My comics']);
    final libraries = await tester.runAsync(local.libraries);
    expect([for (final l in libraries!) l['name']], ['My comics']);
  });
}
