// The local libraries' screens (lib/local/folder_browser.dart, local_settings.dart, device_folders.dart): a folder
// browsed to, where it is said plainly, the iPad's folder.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:komga_reader/local/device_folders.dart';
import 'package:komga_reader/screens/folder_browser.dart';
import 'package:komga_reader/local/library_fs.dart';

/// A device with the places given, and its folders.
class _Fake implements BrowseSource {
  _Fake(this.placeList);
  final List<Place> placeList;
  final looked = <String>[];
  static const _folders = {
    '/storage/emulated/0': FolderLook(['Comics', 'Download'], 0),
    '/storage/emulated/0/Comics': FolderLook(['Batman'], 2),
  };

  @override
  Future<List<Place>> places() async => placeList;
  @override
  Future<bool> openPlace(BuildContext context) async => true;
  @override
  Future<FolderLook> look(String path) async {
    looked.add(path);
    return _folders[path] ?? const FolderLook([], 0);
  }
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
    await tester.tap(find.text('browse'));
    await tester.pumpAndSettle();
    return () async {
      expect(done, isTrue, reason: 'the browser closed');
      return picked;
    };
  }

  testWidgets("one place to start from (a tablet's storage): opened straight away; folder by folder; Use this folder "
      'gives its path; Up from the top shows the places', (tester) async {
    final source = _Fake(const [Place('This device', '/storage/emulated/0')]);
    final result = await open(tester, source);
    expect(source.looked, ['/storage/emulated/0'], reason: 'no list of one to tap through');
    await tester.tap(find.text('Comics'));
    await tester.pumpAndSettle();
    expect(source.looked.last, '/storage/emulated/0/Comics');
    await tester.tap(find.byIcon(Icons.arrow_upward));
    await tester.pumpAndSettle();
    expect(source.looked.last, '/storage/emulated/0');
    await tester.tap(find.byIcon(Icons.arrow_upward));
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.edit_outlined), findsOneWidget, reason: 'the places, with Type a folder');
    await tester.tap(find.text('This device'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Comics'));
    await tester.pumpAndSettle();
    await tester.tap(find.byType(FilledButton));
    await tester.pumpAndSettle();
    expect(await result(), '/storage/emulated/0/Comics');
  });

  testWidgets('several places (a card too): listed; a folder typed in is taken as it is', (tester) async {
    final source = _Fake(const [Place('This device', '/storage/emulated/0'), Place('Card', '/storage/1234-ABCD')]);
    final result = await open(tester, source);
    expect(source.looked, isEmpty, reason: 'nothing opened by itself');
    await tester.tap(find.byIcon(Icons.edit_outlined));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '  /sdcard/Comics  ');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    expect(await result(), '/sdcard/Comics');
  });

  test("where a folder is, said plainly: this device's storage, the iPad's folder (its GUID left out), a card", () {
    expect(wherePlainly('/storage/emulated/0/Comics/Saga', storage: '/storage/emulated/0'),
        'This Device › Comics/Saga/');
    expect(wherePlainly('/var/mobile/Containers/Data/Application/AC3D-11/Documents/Comics'),
        'This Device › Documents/Comics/');
    expect(wherePlainly('/storage/1234-ABCD/Comics'), 'Card 1234-ABCD › Comics/');
    expect(wherePlainly(r'C:\Comics'), r'C:\Comics');
  });

  test("iPad: a Comics folder in the app's folder while that's empty (the Files app hides an empty one); not once "
      "the person's own things are there, so one they deleted isn't made again", () async {
    final tmp = await Directory.systemTemp.createTemp('docs');
    addTearDown(() => tmp.delete(recursive: true));
    await File('${tmp.path}/.DS_Store').writeAsString('');
    expect(await DeviceFolders.makeComicsFolder(documents: tmp.path), isNotNull);
    await Directory('${tmp.path}/Comics').delete();
    await Directory('${tmp.path}/Saga').create();
    expect(await DeviceFolders.makeComicsFolder(documents: tmp.path), isNull);
    expect(await Directory('${tmp.path}/Comics').exists(), isFalse);
  });
}
