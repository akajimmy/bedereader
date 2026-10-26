import 'package:dart_smb2/dart_smb2.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:komga_reader/local/access.dart';
import 'package:komga_reader/local/storage.dart';

/// Getting at a share's folder (FolderAccess.ensure): a login asked for only when the share refuses one.
void main() {
  late _Share share;
  const path = r'\\10.0.0.254\x\Lib';

  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
    Storage.smbEverywhere = true; // (as on Android and iOS: the share through the app's SMB client)
    share = _Share();
    Storage.fsFor = (_) => share;
  });
  tearDown(() {
    Storage.smbEverywhere = null;
    Storage.fsFor = null;
  });

  /// A screen whose button adds [path]; the answer lands in the returned list.
  Future<List<bool>> open(WidgetTester tester) async {
    final result = <bool>[];
    await tester.pumpWidget(MaterialApp(home: Builder(builder: (context) => TextButton(
        onPressed: () async => result.add(await FolderAccess.ensure(context, path)), child: const Text('add')))));
    return result;
  }

  testWidgets("a share that doesn't answer: no login asked for (it can't help) - Retry, and once it answers, in "
      '(tablet, 2026-10-25: \\\\10.0.0.254 asked for a user name and password)', (tester) async {
    final result = await open(tester);
    await tester.pump();
    share.next = () => throw const Smb2Exception('Socket connect failed with 113', type: Smb2ErrorType.connection);
    await tester.tap(find.text('add'));
    await tester.pumpAndSettle();
    expect(find.byType(TextField), findsNothing, reason: 'no user name or password');
    expect(find.byType(AlertDialog), findsOneWidget);

    share.next = () => true; // back
    await tester.tap(find.text('Retry'));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing);
    expect(result, [true]);
    expect(share.asked, 2);
  });

  testWidgets('a share that refuses a guest: a login asked for, and with it, in', (tester) async {
    final result = await open(tester);
    await tester.pump();
    share.next = () => throw const Smb2Exception('refused', type: Smb2ErrorType.auth);
    await tester.tap(find.text('add'));
    await tester.pumpAndSettle();
    expect(find.byType(TextField), findsNWidgets(3), reason: 'user name, password, domain');
    share.next = () => true;
    await tester.enterText(find.byType(TextField).first, 'nick');
    await tester.tap(find.text('Sign in'));
    await tester.pumpAndSettle();
    expect(result, [true]);
  });

  testWidgets("the share answers but the folder isn't there: said, no login asked for, not added", (tester) async {
    final result = await open(tester);
    await tester.pump();
    share.next = () => false;
    await tester.tap(find.text('add'));
    await tester.pumpAndSettle();
    expect(find.byType(TextField), findsNothing);
    expect(find.byType(AlertDialog), findsOneWidget);
    await tester.tap(find.text('OK'));
    await tester.pumpAndSettle();
    expect(result, [false]);
  });
}

/// A share whose folder check answers at once with [next] (true / false, or a throw).
class _Share implements LibraryFs {
  late bool Function() next;
  int asked = 0;
  @override
  Future<bool> exists(String folder) async {
    asked++;
    return next();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError();
}
