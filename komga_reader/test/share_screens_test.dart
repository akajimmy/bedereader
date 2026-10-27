// Network shares' screens (rebuild step 9): the folder browser on a server - its shares, a login asked for when one
// refuses - and a share reached before it's kept as a library (lib/local/share_access.dart).
import 'dart:io';
import 'dart:typed_data';

import 'package:dart_smb2/dart_smb2.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:komga_reader/local/folder_browser.dart';
import 'package:komga_reader/local/library_fs.dart';
import 'package:komga_reader/local/local_library.dart';
import 'package:komga_reader/local/local_settings.dart';
import 'package:komga_reader/local/local_source.dart';
import 'package:komga_reader/local/share_access.dart';
import 'package:komga_reader/local/smb_fs.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _refused = Smb2Exception('refused', type: Smb2ErrorType.accessDenied);

/// A server, nas: its shares, and the books share's folders - refused until [login] is given.
class _Network implements NetworkBrowseSource {
  _Network({this.known = const []});
  final List<String> known;
  final logins = <String, SmbLogin>{};
  final looked = <String>[];

  @override
  Future<List<Place>> places() async => [for (final k in known) Place(k, '\\\\$k')];
  @override
  Future<bool> openPlace(BuildContext context) async => true;
  @override
  Future<List<String>> shares(String host) async => ['books', 'media'];
  @override
  Future<FolderLook> look(String path) async {
    looked.add(path);
    if (logins[r'\\nas\books'] == null) throw _refused;
    return path == r'\\nas\books' ? const FolderLook(['Comics'], 0) : const FolderLook([], 3);
  }

  @override
  bool refused(Object error) => SmbFs.troubleOf(error) == FileTrouble.refused;
  @override
  Future<void> useLogin(String host, SmbLogin login) async {}
  @override
  Future<void> setLogin(String path, SmbLogin login) async => logins[r'\\nas\books'] = login;
}

/// A share as Shares connects to it: refusing a guest when [needsLogin], out of reach when [away].
class _Share implements SmbShare {
  _Share({this.needsLogin = false, this.away = false});
  final bool needsLogin, away;

  @override
  Future<bool> exists(String inShare) async => inShare == 'Comics';
  @override
  Future<List<SmbEntry>> list(String inShare) async => const [];
  @override
  Future<(Object, int)> open(String inShare) async => throw UnimplementedError();
  @override
  Future<Uint8List> read(Object handle, int offset, int length) async => throw UnimplementedError();
  @override
  Future<void> close(Object handle) async {}
  @override
  Future<void> disconnect() async {}
}

void main() {
  setUp(() => FlutterSecureStorage.setMockInitialValues({}));

  /// A button that runs [run] with a context under the app; its result is kept.
  Future<Object? Function()> host(WidgetTester tester, Future<Object?> Function(BuildContext) run) async {
    Object? result;
    await tester.pumpWidget(MaterialApp(home: Builder(builder: (context) => Scaffold(body: Center(child: TextButton(
        onPressed: () async => result = await run(context), child: const Text('go')))))));
    await tester.tap(find.text('go'));
    await tester.pumpAndSettle();
    return () => result;
  }

  testWidgets('a server: its shares; a share refusing a guest asks for a login, then shows its folders; Up from its '
      'top goes back to the server; Use this folder gives the share path', (tester) async {
    final net = _Network(known: ['nas']);
    final result = await host(tester, (c) => pickFolder(c, source: net));
    await tester.tap(find.text('nas'));
    await tester.pumpAndSettle();
    expect(find.text('media'), findsOneWidget);
    await tester.tap(find.text('books'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400)); // (the page's spinner turns behind the dialog: no settling)
    expect(find.byType(ShareLoginDialog), findsOneWidget);
    await tester.enterText(find.widgetWithText(TextField, 'User name'), 'nick');
    await tester.enterText(find.widgetWithText(TextField, 'Password'), 'p4ss');
    await tester.tap(find.widgetWithText(TextButton, 'Sign in'));
    await tester.pumpAndSettle();
    expect(net.logins[r'\\nas\books']?.user, 'nick');
    expect(find.text('Comics'), findsOneWidget, reason: 'tried again with the login');

    await tester.tap(find.byTooltip('Up'));
    await tester.pumpAndSettle();
    expect(find.text('media'), findsOneWidget, reason: "the server's shares");
    await tester.tap(find.text('books'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Comics'));
    await tester.pumpAndSettle();
    await tester.tap(find.byType(FilledButton));
    await tester.pumpAndSettle();
    expect(result(), r'\\nas\books\Comics');
  });

  testWidgets('Connect to a server: by its name (a path typed with it is cut to the name); its shares listed',
      (tester) async {
    await host(tester, (c) => pickFolder(c, source: _Network()));
    await tester.tap(find.byIcon(Icons.add_link));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), r'\\nas\books');
    await tester.tap(find.widgetWithText(TextButton, 'OK'));
    await tester.pumpAndSettle();
    expect(find.text('books'), findsOneWidget);
    expect(find.text(r'\\nas'), findsOneWidget, reason: 'where it is');
  });

  group('Settings > Libraries', () {
    late Directory data;
    late LocalSource local;
    // opened here, outside the widget test: it doesn't wait on the disk
    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      data = await Directory.systemTemp.createTemp('share_screens');
      local = await LocalSource.open(data, [LocalLibrary.at(data.path), LocalLibrary.at(r'\\nas\books\Manga')]);
    });
    tearDown(() async {
      await local.closeFiles();
      await data.delete(recursive: true);
    });

    testWidgets("the libraries on a share in the Network group, the others in Local; a share's has Sign in where the "
        'app signs in to it (not Windows)', (tester) async {
      Future<void> page(Shares shares) async {
        await tester.pumpWidget(MaterialApp(home: Scaffold(body: ListView(children: [
          LocalLibrariesGroup(local: local, shares: shares),
          LocalLibrariesGroup(local: local, network: true, shares: shares),
        ]))));
        await tester.pump();
      }

      await page(Shares(viaApp: true));
      final groups = find.byType(LocalLibrariesGroup);
      expect(find.descendant(of: groups.first, matching: find.text('Manga')), findsNothing);
      expect(find.descendant(of: groups.last, matching: find.text('Manga')), findsOneWidget);
      expect(find.descendant(of: groups.last, matching: find.text(LocalLibrary.at(data.path).name)), findsNothing);
      expect(find.descendant(of: groups.last, matching: find.byTooltip('Sign in')), findsOneWidget);
      expect(find.descendant(of: groups.first, matching: find.byTooltip('Sign in')), findsNothing);

      await page(Shares(viaApp: false));
      expect(find.byTooltip('Sign in'), findsNothing);
    });
  });

  group('a share reached before it is kept', () {
    testWidgets('open to guests: kept with no login asked for', (tester) async {
      final shares = Shares(viaApp: true, connect: (_, __, ___) async => _Share());
      final result = await host(tester, (c) => ensureShare(c, r'\\nas\books\Comics', shares: shares));
      expect(result(), isTrue);
      expect(shares.loginFor(r'\\nas\books'), isNull);
    });

    testWidgets("a guest refused: a login asked for (nothing said against it), tried, kept; Cancel - not kept",
        (tester) async {
      final shares = Shares(viaApp: true, connect: (_, __, login) async {
        if (login == null) throw _refused;
        return _Share();
      });
      final result = await host(tester, (c) => ensureShare(c, r'\\nas\books\Comics', shares: shares));
      final dialog = tester.widget<ShareLoginDialog>(find.byType(ShareLoginDialog));
      expect(dialog.problem, isNull);
      await tester.enterText(find.widgetWithText(TextField, 'User name'), 'nick');
      await tester.tap(find.widgetWithText(TextButton, 'Sign in'));
      await tester.pumpAndSettle();
      expect(result(), isTrue);
      expect(shares.loginFor(r'\\nas\books\Manga')?.user, 'nick');
    });

    testWidgets("out of reach: Retry or Cancel, no login asked for; Cancel isn't kept", (tester) async {
      final shares = Shares(viaApp: true,
          connect: (_, __, ___) async => throw const Smb2Exception('no route', type: Smb2ErrorType.connection));
      final result = await host(tester, (c) => ensureShare(c, r'\\nas\books\Comics', shares: shares));
      expect(find.byType(ShareLoginDialog), findsNothing);
      await tester.tap(find.widgetWithText(TextButton, 'Retry'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
      await tester.pumpAndSettle();
      expect(result(), isFalse);
    });

    testWidgets("the share answers, the folder isn't on it: said, not kept", (tester) async {
      final shares = Shares(viaApp: true, connect: (_, __, ___) async => _Share());
      final result = await host(tester, (c) => ensureShare(c, r'\\nas\books\Gone', shares: shares));
      expect(find.byType(AlertDialog), findsOneWidget);
      await tester.tap(find.widgetWithText(TextButton, 'OK'));
      await tester.pumpAndSettle();
      expect(result(), isFalse);
    });
  });
}
