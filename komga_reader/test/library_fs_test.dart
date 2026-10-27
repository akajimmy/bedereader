// Where a local library's files are read from (lib/local/library_fs.dart): share paths, a folder's look, this
// device's files, and each kind of read error told apart.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:komga_reader/local/library_fs.dart';

void main() {
  test(r'share paths: \\host\share\folder (or smb://), split into the host, the share and the path in it', () {
    expect(splitUnc(r'\\nick-nas\nas-share\COMICS\Ongoing\'), ('nick-nas', 'nas-share', 'COMICS/Ongoing'));
    expect(splitUnc('smb://nas/comics'), ('nas', 'comics', ''));
    expect(splitUnc(r'C:\Comics'), isNull);
    expect(splitUnc('/storage/emulated/0/Comics'), isNull);
  });

  test("a folder's look: the system's own folders left out (hidden, a NAS's @Recycle and #recycle, Windows's "
      r'$RECYCLE.BIN), sorted; its books counted (CBZ, CBR, EPUB)', () {
    final l = FolderLook.of([
      ('Ongoing', true), ('@Recycle', true), ('.thumbs', true), ('#recycle', true), (r'$RECYCLE.BIN', true),
      ('System Volume Information', true), ('golden Age', true), ('a.cbz', false), ('B.EPUB', false),
      ('notes.txt', false), ('c.CBR', false),
    ]);
    expect(l.folders, ['golden Age', 'Ongoing']);
    expect(l.books, 3);
  });

  group("this device's files", () {
    late Directory dir;
    setUp(() async {
      dir = await Directory.systemTemp.createTemp('library_fs');
      await Directory('${dir.path}/Batman/Annuals').create(recursive: true);
      await File('${dir.path}/Batman/001.cbz').writeAsBytes(List.generate(100, (i) => i));
      await File('${dir.path}/Batman/Annuals/A1.cbz').writeAsBytes([1, 2, 3]);
    });
    tearDown(() => dir.delete(recursive: true));

    test('every file at any depth, with its size; a range read from the middle, and short at the end', () async {
      final fs = LocalFs();
      final found = {
        await for (final e in fs.list(dir.path)) e.path.replaceAll('\\', '/').split('/Batman/').last: e.size,
      };
      expect(found, {'001.cbz': 100, 'Annuals/A1.cbz': 3});
      expect(await fs.readRange('${dir.path}/Batman/001.cbz', 10, 3), [10, 11, 12]);
      expect(await fs.readRange('${dir.path}/Batman/001.cbz', 98, 10), [98, 99]);
    });

    test('a folder deleted from a place that is still there looks deleted (not out of reach)', () async {
      final fs = LocalFs();
      expect(await fs.exists('${dir.path}/Superman'), isFalse);
      expect(await fs.placeAnswers('${dir.path}/Superman'), isTrue);
    });

    test("a file that isn't there is told apart as gone - as this system numbers it", () async {
      final fs = LocalFs();
      Object? error;
      try {
        await fs.readRange('${dir.path}/Batman/missing.cbz', 0, 4);
      } catch (e) {
        error = e;
      }
      expect(fs.classify(error!), FileTrouble.gone);
    });
  });

  test('read errors told apart as Windows numbers them and as the others do (the same number can mean different '
      'things: 5 is "access denied" on Windows, an I/O error elsewhere)', () {
    FileSystemException os(int code) => FileSystemException('x', 'p', OSError('m', code));
    final win = LocalFs(windows: true), other = LocalFs(windows: false);
    expect(win.classify(os(2)), FileTrouble.gone);
    expect(win.classify(os(3)), FileTrouble.gone);
    expect(win.classify(os(5)), FileTrouble.refused);
    expect(win.classify(os(53)), FileTrouble.noAnswer, reason: 'a share by its \\\\host path, not found on the network');
    expect(win.classify(os(64)), FileTrouble.noAnswer);
    expect(other.classify(os(2)), FileTrouble.gone);
    expect(other.classify(os(13)), FileTrouble.refused, reason: "Android's file access taken back");
    expect(other.classify(os(110)), FileTrouble.noAnswer);
    expect(other.classify(os(5)), FileTrouble.damaged, reason: 'an I/O error: not "access denied" here');
  });

  test("an error that isn't one of the known kinds is said as damaged - not taken for a share that's away (every "
      "unknown error counted as \"no answer\" in the experiment, and kept a broken book)", () {
    final fs = LocalFs();
    expect(fs.classify(const FormatException('not a zip')), FileTrouble.damaged);
    expect(fs.classify(StateError('a bug')), FileTrouble.damaged);
    expect(fs.classify(const FileSystemException('no OS error')), FileTrouble.damaged);
  });
}
