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
    expect(said(r'C:\Comics\Archive', TargetPlatform.windows), r'On This Device › C:\Comics\Archive\');
  });

  test("an iPad library kept from before the app's folder moved is found where it is now, with the same ids", () {
    expect(reanchored('$docs/Spider-Man', moved), '$moved/Spider-Man');
    expect(reanchored(r'\\nick-nas\NAS-SHARE\Ongoing', moved), r'\\nick-nas\NAS-SHARE\Ongoing');
    expect(reanchored('$docs/Spider-Man', null), '$docs/Spider-Man');
    // the library's id (and its series' and books', made the same way) doesn't change with the GUID: progress kept
    expect(LocalLibrary.at('$docs/Spider-Man').id, LocalLibrary.at('$moved/Spider-Man').id);
    expect(LocalLibrary.at('$docs/Spider-Man').id, isNot(LocalLibrary.at('$docs/Batman').id));
  });
}
