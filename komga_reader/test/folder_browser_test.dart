// Choosing a library folder by browsing (experimental/sources, lib/local/folder_browser.dart): this device's folders
// and a server's shares, folder by folder, on the No server screen and in Settings' Add a library.
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:komga_reader/local/folder_browser.dart';
import 'package:komga_reader/local/storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _Refused implements Exception {}

/// A device with one storage and a NAS whose shares need a login.
class _Fake implements BrowseSource {
  final logins = <String, SmbLogin>{};
  final looked = <String>[];
  var deviceOpened = 0;
  static const _folders = {
    '/storage/emulated/0': FolderLook(['Comics', 'Download'], 0),
    '/storage/emulated/0/Comics': FolderLook(['Batman'], 0),
    r'\\nick-nas\NAS-SHARE': FolderLook(['COMICS'], 0),
    r'\\nick-nas\NAS-SHARE\COMICS': FolderLook(['Golden Age', 'Ongoing'], 0),
    r'\\nick-nas\NAS-SHARE\COMICS\Ongoing': FolderLook(['Absolute Batman'], 2),
  };

  @override
  Future<List<Place>> places() async =>
      const [Place('This device', '/storage/emulated/0'), Place('nick-nas', r'\\nick-nas', server: true)];

  @override
  Future<bool> openDevice(BuildContext context) async {
    deviceOpened++;
    return true;
  }

  @override
  Future<List<String>> shares(String host) async {
    if (logins[host] == null) throw _Refused();
    return ['NAS-SHARE', 'Public'];
  }

  @override
  Future<FolderLook> look(String path) async {
    looked.add(path);
    return _folders[path] ?? const FolderLook([], 0);
  }

  @override
  bool refused(Object error) => error is _Refused;

  @override
  Future<void> useLogin(String host, SmbLogin login) async => logins[host] = login;
}

void main() {
  Future<Future<String?> Function()> open(WidgetTester tester, _Fake source) async {
    String? picked;
    var done = false;
    await tester.pumpWidget(MaterialApp(home: Builder(builder: (context) => Scaffold(body: Center(child: TextButton(
        onPressed: () async {
          picked = await pickFolder(context, source: source);
          done = true;
        },
        child: const Text('browse')))))));
    return () async {
      expect(done, isTrue, reason: 'the browser closed');
      return picked;
    };
  }

  testWidgets("a share's folder: the server's shares listed (its login asked for when it refuses a guest), then "
      r'folder by folder - the path given back is \\host\share\folder', (tester) async {
    final source = _Fake();
    final result = await open(tester, source);
    await tester.pumpAndSettle();
    await tester.tap(find.text('browse'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('nick-nas'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500)); // (the spinner behind the dialog never settles)
    // refused as a guest: a login asked for, then the shares listed with it
    final fields = find.descendant(of: find.byType(AlertDialog), matching: find.byType(TextField));
    await tester.enterText(fields.at(0), 'nickperusse');
    await tester.enterText(fields.at(1), 'secret');
    await tester.tap(find.descendant(of: find.byType(AlertDialog), matching: find.byType(TextButton)).last);
    await tester.pumpAndSettle();
    expect(source.logins['nick-nas']?.user, 'nickperusse');
    expect(find.text('Public'), findsOneWidget);

    await tester.tap(find.text('NAS-SHARE'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('COMICS'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Ongoing'));
    await tester.pumpAndSettle();
    expect(source.looked.last, r'\\nick-nas\NAS-SHARE\COMICS\Ongoing');
    await tester.tap(find.byType(FilledButton));
    await tester.pumpAndSettle();
    expect(await result(), r'\\nick-nas\NAS-SHARE\COMICS\Ongoing');
  });

  testWidgets("this device's folders (after Android's file access is checked): Up goes to the parent, and from the "
      "place's own top back to the places - never above it; a share's top goes up to its server's shares",
      (tester) async {
    final source = _Fake()..logins['nick-nas'] = const SmbLogin('u', 'p');
    final result = await open(tester, source);
    await tester.pumpAndSettle();
    await tester.tap(find.text('browse'));
    await tester.pumpAndSettle();
    final up = find.byIcon(Icons.arrow_upward);

    await tester.tap(find.text('This device'));
    await tester.pumpAndSettle();
    expect(source.deviceOpened, 1);
    String title() => (tester.widget<AppBar>(find.byType(AppBar)).title! as Text).data!;
    expect(title(), 'This device', reason: "the place's name at its top, not the path's last part (\"0\")");
    await tester.tap(find.text('Comics'));
    await tester.pumpAndSettle();
    expect(source.looked.last, '/storage/emulated/0/Comics');
    expect(title(), 'Comics');
    await tester.tap(up);
    await tester.pumpAndSettle();
    expect(source.looked.last, '/storage/emulated/0');
    await tester.tap(up);
    await tester.pumpAndSettle();
    expect(find.text('nick-nas'), findsOneWidget, reason: 'the places again');
    expect(up, findsNothing);

    await tester.tap(find.text('nick-nas'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('NAS-SHARE'));
    await tester.pumpAndSettle();
    await tester.tap(up);
    await tester.pumpAndSettle();
    expect(find.text('Public'), findsOneWidget, reason: "the server's shares");

    await tester.tap(find.text('Public'));
    await tester.pumpAndSettle();
    await tester.tap(find.byType(FilledButton));
    await tester.pumpAndSettle();
    expect(await result(), r'\\nick-nas\Public');
  });

  test("a folder's look: the system's own folders left out (hidden, a NAS's @Recycle and #recycle, Windows's "
      r'$RECYCLE.BIN), sorted; its books counted (CBZ, EPUB)', () {
    final l = FolderLook.of([
      ('Ongoing', true), ('@Recycle', true), ('.thumbs', true), ('#recycle', true), (r'$RECYCLE.BIN', true),
      ('System Volume Information', true), ('golden Age', true), ('a.cbz', false), ('B.EPUB', false),
      ('notes.txt', false), ('c.CBZ', false),
    ]);
    expect(l.folders, ['golden Age', 'Ongoing']);
    expect(l.books, 3);
  });

  test("Windows's shares, from what net view prints: the folder shares, not IPC\$ or a hidden one", () {
    const out = 'Shared resources at \\\\nick-nas\r\n\r\nNAS Server\r\n\r\n'
        'Share name  Type  Used as  Comment                   \r\n\r\n'
        '-------------------------------------------------------------------------------\r\n'
        'Container   Disk           Container Station         \r\n'
        'home        Disk           Home                      \r\n'
        'IPC\$        IPC            IPC Service (NAS Server)  \r\n'
        'NAS-SHARE   Disk  Z:                                 \r\n'
        'Old Stuff   Disk\r\n'
        'admin\$      Disk           Hidden\r\n'
        'The command completed successfully.\r\n';
    expect(netViewShares(out), ['Container', 'home', 'NAS-SHARE', 'Old Stuff']);
  });

  testWidgets("iPhone / iPad: this device's place is the app's own folder, as iOS gives it - the one the Files app and "
      'Apple Devices put books in (user, 2026-10-26: only "Connect to a server" was offered)', (tester) async {
    SharedPreferences.setMockInitialValues({});
    const docs = '/private/var/mobile/Containers/Data/Application/ABC/Documents';
    const screen = MethodChannel('komga_reader/screen');
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(screen, (c) async => c.method == 'documentsDir' ? docs : null);
    addTearDown(() => messenger.setMockMethodCallHandler(screen, null));
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    try {
      final places = await DeviceBrowse().places();
      expect([for (final p in places) if (!p.server) p.path], [docs]);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });
}
