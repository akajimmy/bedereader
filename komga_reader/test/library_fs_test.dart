// Where a local library's files are read from (lib/local/library_fs.dart): share paths, a folder's look, this
// device's files, and each kind of read error told apart - as each system numbers them.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:komga_reader/local/library_fs.dart';

void main() {
  test(r'share paths: \\host\share\folder (or smb://, or Windows long form), split into the host, the share and the '
      'path in it; a drive path is none, in either form', () {
    expect(splitUnc(r'\\nick-nas\nas-share\COMICS\Ongoing\'), ('nick-nas', 'nas-share', 'COMICS/Ongoing'));
    expect(splitUnc('smb://nas/comics'), ('nas', 'comics', ''));
    expect(splitUnc(r'\\?\UNC\nick-nas\nas-share\COMICS'), ('nick-nas', 'nas-share', 'COMICS'));
    expect(splitUnc(r'\\?\C:\Comics'), isNull, reason: "not a share whose host is '?'");
    expect(splitUnc(r'C:\Comics'), isNull);
    expect(splitUnc('/storage/emulated/0/Comics'), isNull);
  });

  test("a folder's look: the system's own folders left out (hidden, a NAS's @Recycle and #recycle, Windows's "
      r'$RECYCLE.BIN), sorted; its books counted (CBZ, CBR, EPUB - not a Mac''s ._ copies)', () {
    final l = FolderLook.of([
      ('Ongoing', true), ('@Recycle', true), ('.thumbs', true), ('#recycle', true), (r'$RECYCLE.BIN', true),
      ('System Volume Information', true), ('golden Age', true), ('a.cbz', false), ('B.EPUB', false),
      ('notes.txt', false), ('c.CBR', false), ('._a.cbz', false),
    ]);
    expect(l.folders, ['golden Age', 'Ongoing']);
    expect(l.books, 3);
  });

  group("this device's files", () {
    late Directory dir;
    Future<void> put(String rel, List<int> bytes) async {
      final f = File('${dir.path}/$rel');
      await f.parent.create(recursive: true);
      await f.writeAsBytes(bytes);
    }

    setUp(() async {
      dir = await Directory.systemTemp.createTemp('library_fs');
      await put('Batman/001.cbz', List.generate(100, (i) => i));
      await put('Batman/Annuals/A1.cbz', [1, 2, 3]);
    });
    tearDown(() => dir.delete(recursive: true));

    test('the book files at any depth, with their sizes - not in a NAS\'s #recycle or @eaDir, a hidden folder, a '
        "Mac's ._ copies or files that aren't books (review, 2026-10-26)", () async {
      await put('Batman/#recycle/002.cbz', [1]);
      await put('Batman/@eaDir/001.cbz/SYNOFILE_THUMB_M.jpg', [1]);
      await put('Batman/.hidden/003.cbz', [1]);
      await put('Batman/._001.cbz', [1]);
      await put('Batman/notes.txt', [1]);
      final found = {
        await for (final e in LocalFs().list(dir.path)) e.path.replaceAll('\\', '/').split('/Batman/').last: e.size,
      };
      expect(found, {'001.cbz': 100, 'Annuals/A1.cbz': 3});
    });

    test('a file opened once, read in parts: from the middle, and short at the end', () async {
      final f = await LocalFs().open('${dir.path}/Batman/001.cbz');
      expect(await f.length(), 100);
      expect(await f.readRange(10, 3), [10, 11, 12]);
      expect(await f.readRange(98, 10), [98, 99]);
      await f.close();
      expect(await readWhole(LocalFs(), '${dir.path}/Batman/Annuals/A1.cbz'), [1, 2, 3]);
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
        await fs.open('${dir.path}/Batman/missing.cbz');
      } catch (e) {
        error = e;
      }
      expect(fs.classify(error!), FileTrouble.gone);
    });
  });

  // user, 2026-10-28: on Windows a share (\\host\share) is read through the system - one folder at a time, every
  // file's size a round trip of its own - so a big share's first scan was the slow one; the share client on Android and
  // iOS lists four at once
  test("this device's files (a share by \\\\host\\share on Windows) are listed several folders at once, no more than "
      'the share client does; every book found', () async {
    final real = await Directory.systemTemp.createTemp('library_fs_at_once');
    final book = File('${real.path}/x.cbz')..writeAsBytesSync([1, 2, 3]);
    final tree = _Tree(book.path, {
      'S': ['A', 'B', 'C', 'D', 'E', 'top.cbz'],
      'S/A': ['a1.cbz', 'a2.cbz'], 'S/B': ['b.cbz'], 'S/C': ['c.cbz'], 'S/D': ['Inner'], 'S/D/Inner': ['i.cbz'],
      'S/E': [],
    });
    try {
      final found = await IOOverrides.runZoned(() => LocalFs().list('S').map((e) => e.path).toList(),
          createDirectory: (p) => _Dir(p, tree));
      expect(found.toSet(), {'S/top.cbz', 'S/A/a1.cbz', 'S/A/a2.cbz', 'S/B/b.cbz', 'S/C/c.cbz', 'S/D/Inner/i.cbz'});
      expect(tree.mostAtOnce, greaterThan(1), reason: 'folders listed at once');
      expect(tree.mostAtOnce, lessThanOrEqualTo(listedAtOnce));
    } finally {
      await real.delete(recursive: true);
    }
  });

  // review, 2026-10-26: walking up, / was always there - a card taken out looked deleted, and the user was asked
  test("a card or USB drive taken out (Android: /storage/1234-ABCD) is out of reach, not deleted: the system's own "
      'top folders (/, /storage) are no place of its own', () async {
    expect(await LocalFs().placeAnswers('/storage/1234-ABCD/Comics'), isFalse);
    expect(await LocalFs().placeAnswers('/no-such-top/Comics'), isFalse);
  });

  test('read errors told apart as each system numbers them (the same number means different things: 5 is "access '
      'denied" on Windows, an I/O error elsewhere; a timeout is 110 on Android, 60 on the iPad)', () {
    FileSystemException os(int code) => FileSystemException('x', 'p', OSError('m', code));
    final win = LocalFs(platform: FsPlatform.windows);
    final apple = LocalFs(platform: FsPlatform.apple);
    final linux = LocalFs(platform: FsPlatform.linux);
    expect([for (final c in [2, 3]) win.classify(os(c))], everyElement(FileTrouble.gone));
    expect([for (final c in [5, 65, 86, 1244, 1326]) win.classify(os(c))], everyElement(FileTrouble.refused),
        reason: 'access denied, a share login refused');
    expect([for (final c in [15, 21, 53, 64, 67, 1222, 1231, 1232, 2250]) win.classify(os(c))],
        everyElement(FileTrouble.noAnswer), reason: 'a USB drive taken out, a share not answering');
    expect([for (final c in [2, 20]) linux.classify(os(c))], everyElement(FileTrouble.gone));
    expect([for (final c in [1, 13]) linux.classify(os(c))], everyElement(FileTrouble.refused));
    expect([for (final c in [100, 101, 104, 110, 111, 113, 116, 123]) linux.classify(os(c))],
        everyElement(FileTrouble.noAnswer), reason: 'ENOMEDIUM 123: a card taken out');
    expect(linux.classify(os(5)), FileTrouble.damaged, reason: 'an I/O error');
    expect([for (final c in [50, 51, 54, 60, 61, 64, 65]) apple.classify(os(c))], everyElement(FileTrouble.noAnswer));
    expect(apple.classify(os(110)), FileTrouble.damaged, reason: "not a number Apple's systems use for a timeout");
    expect(apple.classify(os(2)), FileTrouble.gone);
  });

  test("an error that isn't one of the known kinds is said as damaged - not taken for a share that's away (every "
      "unknown error counted as \"no answer\" in the experiment, and kept a broken book)", () {
    final fs = LocalFs();
    expect(fs.classify(const FormatException('not a zip')), FileTrouble.damaged);
    expect(fs.classify(StateError('a bug')), FileTrouble.damaged);
    expect(fs.classify(const FileSystemException('no OS error')), FileTrouble.damaged);
  });
}

/// Folders (by path) and their entries - a name ending .cbz a file, others folders; each listing takes a while, and
/// how many run at once is counted. Every file's size is [book]'s (a real file).
class _Tree {
  _Tree(this.book, this.folders);
  final String book;
  final Map<String, List<String>> folders;
  int running = 0, mostAtOnce = 0;
}

class _Dir implements Directory {
  _Dir(this.path, this.tree);
  @override
  final String path;
  final _Tree tree;

  @override
  Stream<FileSystemEntity> list({bool recursive = false, bool followLinks = true}) async* {
    tree.running++;
    if (tree.running > tree.mostAtOnce) tree.mostAtOnce = tree.running;
    await Future<void>.delayed(const Duration(milliseconds: 5));
    tree.running--;
    for (final n in tree.folders[path]!) {
      yield n.endsWith('.cbz') ? _File('$path/$n', tree) : _Dir('$path/$n', tree);
    }
  }

  @override
  dynamic noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

class _File implements File {
  _File(this.path, this.tree);
  @override
  final String path;
  final _Tree tree;

  @override
  Future<FileStat> stat() => FileStat.stat(tree.book);

  @override
  dynamic noSuchMethod(Invocation i) => super.noSuchMethod(i);
}
