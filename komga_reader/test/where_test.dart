import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:komga_reader/local/folder_scan.dart';
import 'package:komga_reader/local/where.dart';

// user, 2026-10-26: the iPad showed a library as /var/mobile/Containers/Data/Application/{GUID}/Documents/Spider-Man;
// they chose "On This Device" › "Documents/Spider-Man/" - the place, then the folders within it
void main() {
  const docs = '/var/mobile/Containers/Data/Application/AC3D1135-B7F2-4A3C-A311-EE511E0826EB/Documents';
  const moved = '/var/mobile/Containers/Data/Application/0F1E2D3C-4B5A-6978-8796-A5B4C3D2E1F0/Documents';

  String said(String path, TargetPlatform platform) =>
      '${whereIs(path, documents: docs, storage: '/storage/emulated/0', platform: platform)}';

  test("a folder is said as its place and the folders within it - the iPad's without the app folder's GUID", () {
    expect(said('$docs/Spider-Man', TargetPlatform.iOS), '$onThisDevice › Documents/Spider-Man/');
    expect(said('$moved/Spider-Man', TargetPlatform.iOS), '$onThisDevice › Documents/Spider-Man/',
        reason: 'a library kept from before the GUID changed');
    expect(whereIs(docs, documents: docs, platform: TargetPlatform.iOS).inside, 'Documents/');
    expect(said('/storage/emulated/0/BeDeReader-TestLibrary/Ongoing', TargetPlatform.android),
        '$onThisDevice › BeDeReader-TestLibrary/Ongoing/');
    expect(whereIs('/storage/emulated/0', platform: TargetPlatform.android).inside, '');
    expect(said('/storage/1A2B-3C4D/Comics', TargetPlatform.android), 'Card or drive 1A2B-3C4D › Comics/');
    expect(said(r'\\nick-nas\NAS-SHARE\COMICS\Archive', TargetPlatform.android), 'nick-nas › NAS-SHARE/COMICS/Archive/');
    expect(said(r'\\nick-nas\NAS-SHARE', TargetPlatform.iOS), 'nick-nas › NAS-SHARE/');
    expect(said(r'C:\Comics\Archive', TargetPlatform.windows), '$onThisDevice › ${r'C:\Comics\Archive\'}');
  });

  // user, 2026-10-26: the place's icon before it - a network folder, a card, this device
  test("each place's kind, for its icon", () {
    WhereKind kind(String path) =>
        whereIs(path, documents: docs, storage: '/storage/emulated/0', platform: TargetPlatform.android).kind;
    expect(kind(r'\\nick-nas\NAS-SHARE\COMICS'), WhereKind.server);
    expect(kind(r'\\nick-nas'), WhereKind.server);
    expect(kind('/storage/1A2B-3C4D/Comics'), WhereKind.card);
    expect(kind('/storage/emulated/0/Comics'), WhereKind.device);
  });

  test("an iPad library kept from before the app's folder moved is found where it is now, with the same ids", () {
    expect(reanchored('$docs/Spider-Man', moved), '$moved/Spider-Man');
    expect(reanchored(r'\\nick-nas\NAS-SHARE\Ongoing', moved), r'\\nick-nas\NAS-SHARE\Ongoing');
    expect(reanchored('$docs/Spider-Man', null), '$docs/Spider-Man');
    // the library's id (and its series' and books', made the same way) doesn't change with the GUID: progress kept
    expect(LocalLibrary.at('$docs/Spider-Man').id, LocalLibrary.at('$moved/Spider-Man').id);
    expect(LocalLibrary.at('$docs/Spider-Man').id, isNot(LocalLibrary.at('$docs/Batman').id));
  });

  test("iOS: a Comics folder in the app's folder while that's empty (the Files app hides an empty one - user, "
      "2026-10-26); not once the person's own things are there, so one they deleted isn't made again", () async {
    final tmp = await Directory.systemTemp.createTemp('docs');
    addTearDown(() => tmp.delete(recursive: true));
    await File('${tmp.path}/.DS_Store').writeAsString('');
    expect(await makeComicsFolder(documents: tmp.path), isNotNull, reason: 'a hidden file is still empty');
    expect(await Directory('${tmp.path}/Comics').exists(), isTrue);

    await Directory('${tmp.path}/Comics').delete();
    await Directory('${tmp.path}/Spider-Man').create();
    expect(await makeComicsFolder(documents: tmp.path), isNull);
    expect(await Directory('${tmp.path}/Comics').exists(), isFalse);
  });
}
