// Where a local library's files are read from (experimental/sources, lib/local/storage.dart): share paths, which
// storage reads them, and a zip read through any storage in one read a page.
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:komga_reader/local/file_zip.dart';
import 'package:komga_reader/local/storage.dart';

import 'support/zip_writer.dart';

/// Files held in memory, counting the reads (as a share would answer them, one round trip each).
class MemoryFs implements LibraryFs {
  MemoryFs(this.files);
  final Map<String, Uint8List> files;
  int reads = 0;

  @override
  Future<bool> exists(String folder) async => files.keys.any((k) => k.startsWith(folder));
  @override
  Future<bool> placeAnswers(String folder) async => true;
  @override
  Stream<FsEntry> list(String folder) async* {
    for (final e in files.entries) {
      if (e.key.startsWith(folder)) yield FsEntry(e.key, e.value.length, DateTime(2026));
    }
  }

  @override
  Future<FolderLook> look(String folder) async => const FolderLook([], 0);

  @override
  Future<int> length(String path) async => files[path]!.length;
  @override
  Future<Uint8List> readAll(String path) async {
    reads++;
    return files[path]!;
  }

  @override
  Future<Uint8List> readRange(String path, int offset, int length) async {
    reads++;
    final f = files[path]!;
    return Uint8List.sublistView(f, offset.clamp(0, f.length), (offset + length).clamp(0, f.length));
  }
}

void main() {
  test(r'share paths: \\host\share\folder (or smb://), split into the host, the share and the path in it', () {
    expect(splitUnc(r'\\nick-nas\nas-share\COMICS\Ongoing\'), ('nick-nas', 'nas-share', 'COMICS/Ongoing'));
    expect(splitUnc('smb://nas/comics'), ('nas', 'comics', ''));
    expect(splitUnc(r'C:\Comics'), isNull);
    expect(splitUnc('/storage/emulated/0/Comics'), isNull);
    expect(Storage.shareOf(r'\\Nick-NAS\Nas-Share\x'), r'nick-nas\nas-share', reason: 'one login per share, any case');
  });

  test(r'a share named without a dot (\\nick-nas) that DNS does not know is looked up as name.local - the NAS answers '
      'to that on the local network; a full name or an address is used as it is', () async {
    addTearDown(() => lookupHost = InternetAddress.lookup);
    final asked = <String>[];
    lookupHost = (name) async {
      asked.add(name);
      if (name == 'nick-nas.local') {
        return [InternetAddress('fdb9:2361:e9ba:1773:265e:beff:fe6d:25c0'), InternetAddress('10.0.0.226')];
      }
      throw const SocketException('Failed host lookup');
    };
    expect(await hostAddress('nick-nas'), '10.0.0.226', reason: 'the IPv4 address first');
    expect(asked, ['nick-nas', 'nick-nas.local']);
    expect(await hostAddress('nas.example.org'), 'nas.example.org');
    expect(await hostAddress('10.0.0.226'), '10.0.0.226');
    expect(await hostAddress('elsewhere'), 'elsewhere', reason: "not found: the name, for the SMB client's own error");
  });

  test("a share's path goes through the app's own SMB client where the system can't open it (Android, iOS); on "
      'Windows, and for a plain folder, the system reads it', () {
    addTearDown(() => Storage.smbEverywhere = null);
    Storage.smbEverywhere = true;
    expect(Storage.instance.of(r'\\nas\comics\Ongoing'), isA<SmbFs>());
    expect(Storage.instance.of('/storage/emulated/0/Comics'), isA<LocalFs>());
    Storage.smbEverywhere = false;
    expect(Storage.instance.of(r'\\nas\comics\Ongoing'), isA<LocalFs>());
  });

  test("a CBZ through any storage: its directory in one read, each page in one more - a share's round trips",
      () async {
    final pages = {for (var i = 1; i <= 5; i++) '$i.jpg': Uint8List.fromList(List.filled(5000 + i, i))};
    final fs = MemoryFs({'book.cbz': zipOf(pages)});
    final zip = await FileZip.open(fs, 'book.cbz');
    expect(fs.reads, 1, reason: 'the end of the file holds the directory');
    expect(zip.names, pages.keys);
    for (final MapEntry(key: name, value: bytes) in pages.entries) {
      expect(await zip.read(name), bytes);
    }
    expect(fs.reads, 1 + pages.length, reason: 'one read a page');
    expect((await zip.head('3.jpg', 100))!.length, 100);
  });
}
