// Network shares (rebuild step 9; lib/local/smb_fs.dart): a share read through the app's SMB client - listed several
// folders at once, its errors told apart, its files opened once - and the shares' logins, kept encrypted.
import 'dart:typed_data';

import 'package:dart_smb2/dart_smb2.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:komga_reader/local/library_fs.dart';
import 'package:komga_reader/local/smb_fs.dart';

/// A share: folders (by their path in the share) and their entries; a folder in [refused] can't be listed.
class _Share implements SmbShare {
  _Share(this.folders);
  final Map<String, List<SmbEntry>> folders;
  final refused = <String>{};
  final files = <String, Uint8List>{};
  final listed = <String>[];
  final writes = <String>[]; // write / delete / rename, in order
  @override
  Future<void> write(String inShare, Uint8List data) async {
    files[inShare] = data;
    writes.add('write $inShare');
  }

  @override
  Future<void> delete(String inShare) async {
    files.remove(inShare);
    writes.add('delete $inShare');
  }

  @override
  Future<Object> openWrite(String inShare) async {
    files[inShare] = Uint8List(0);
    return 'w:$inShare';
  }

  @override
  Future<void> writeAt(Object handle, Uint8List data, int offset) async {
    final at = (handle as String).substring(2);
    files[at] = Uint8List.fromList([...files[at]!.sublist(0, offset), ...data]);
  }

  @override
  Future<void> rename(String from, String to) async {
    files[to] = files.remove(from)!;
    writes.add('rename $from');
  }
  int running = 0, mostAtOnce = 0, closed = 0, disconnected = 0;

  @override
  Future<List<SmbEntry>> list(String inShare) async {
    listed.add(inShare);
    running++;
    if (running > mostAtOnce) mostAtOnce = running;
    await Future<void>.delayed(const Duration(milliseconds: 5));
    running--;
    if (refused.contains(inShare)) {
      throw const Smb2Exception('refused', type: Smb2ErrorType.accessDenied);
    }
    final f = folders[inShare];
    if (f == null) throw const Smb2Exception('not found', type: Smb2ErrorType.notFound);
    return f;
  }

  @override
  Future<bool> exists(String inShare) async => folders.containsKey(inShare) || files.containsKey(inShare);

  @override
  Future<(Object, int)> open(String inShare) async {
    final f = files[inShare];
    if (f == null) throw const Smb2Exception('not found', type: Smb2ErrorType.notFound);
    return (inShare, f.length);
  }

  @override
  Future<Uint8List> read(Object handle, int offset, int length) async {
    final f = files[handle as String]!;
    return Uint8List.sublistView(f, offset, (offset + length).clamp(0, f.length));
  }

  @override
  Future<void> close(Object handle) async => closed++;

  @override
  Future<void> disconnect() async => disconnected++;
}

final _t = DateTime.utc(2026, 10, 1);
SmbEntry _folder(String name, {bool hidden = false}) => SmbEntry(name, folder: true, modified: _t, hidden: hidden);
SmbEntry _file(String name, {int size = 10}) => SmbEntry(name, folder: false, size: size, modified: _t);

void main() {
  test('a library on a share: its book files, folder by folder, several folders at once - system and hidden '
      "folders and files that aren't books left out; paths written as the library's own", () async {
    final share = _Share({
      'Comics': [_folder('Saga'), _folder('Batman'), _folder('@eaDir'), _folder('Old', hidden: true),
        _folder('X-Men'), _folder('Hulk'), _folder('Akira'), _file('notes.txt'), _file('Loose.cbz')],
      'Comics/Saga': [_file('Saga 1.cbz', size: 100), _file('Saga 2.cbr')],
      'Comics/Batman': [_file('Batman 1.cbz')],
      'Comics/X-Men': [_file('X-Men 1.epub')],
      'Comics/Hulk': [], 'Comics/Akira': [_file('Akira 1.cbz')],
    });
    final fs = SmbFs('nas', 'books', null, connect: (_, __, ___) async => share);
    final found = await fs.list(r'\\nas\books\Comics').toList();
    expect({for (final e in found) e.path}, {
      r'\\nas\books\Comics\Loose.cbz', r'\\nas\books\Comics\Saga\Saga 1.cbz', r'\\nas\books\Comics\Saga\Saga 2.cbr',
      r'\\nas\books\Comics\Batman\Batman 1.cbz', r'\\nas\books\Comics\X-Men\X-Men 1.epub',
      r'\\nas\books\Comics\Akira\Akira 1.cbz',
    });
    expect(found.firstWhere((e) => e.path.endsWith('Saga 1.cbz')).size, 100);
    expect(share.listed, isNot(contains('Comics/@eaDir')));
    expect(share.listed, isNot(contains('Comics/Old')));
    expect(share.mostAtOnce, greaterThan(1), reason: 'folders listed at once');
    expect(share.mostAtOnce, lessThanOrEqualTo(SmbFs.parallel));

    final again = await SmbFs('nas', 'books', null, connect: (_, __, ___) async => share)
        .list('smb://nas/books/Comics/').toList();
    expect(again.map((e) => e.path), contains('smb://nas/books/Comics/Saga/Saga 1.cbz'));
  });

  test("a folder in it that can't be listed is told, and the rest goes on; the library's own folder not listed "
      'throws, unless told', () async {
    final share = _Share({
      'Comics': [_folder('Saga'), _folder('Locked')],
      'Comics/Saga': [_file('Saga 1.cbz')],
    })..refused.add('Comics/Locked');
    final fs = SmbFs('nas', 'books', null, connect: (_, __, ___) async => share);
    final unreadable = <String>[];
    final found = await fs.list(r'\\nas\books\Comics', onUnreadable: (f, _) => unreadable.add(f)).toList();
    expect(found.map((e) => e.path), [r'\\nas\books\Comics\Saga\Saga 1.cbz']);
    expect(unreadable, [r'\\nas\books\Comics\Locked']);

    share.refused.add('Comics');
    await expectLater(fs.list(r'\\nas\books\Comics').toList(), throwsA(isA<Smb2Exception>()));
  });

  test("the share's errors told apart: not there = gone; login or rights refused = refused; out of reach, too slow, "
      'busy = no answer (the book kept); anything else = damaged', () {
    final fs = SmbFs('nas', 'books', null, connect: (_, __, ___) async => _Share({}));
    FileTrouble of(Smb2ErrorType t) => fs.classify(Smb2Exception('x', type: t));
    expect(of(Smb2ErrorType.notFound), FileTrouble.gone);
    expect(of(Smb2ErrorType.auth), FileTrouble.refused);
    expect(of(Smb2ErrorType.accessDenied), FileTrouble.refused);
    expect(of(Smb2ErrorType.connection), FileTrouble.noAnswer);
    expect(of(Smb2ErrorType.timeout), FileTrouble.noAnswer);
    expect(of(Smb2ErrorType.inUse), FileTrouble.noAnswer);
    expect(of(Smb2ErrorType.unknown), FileTrouble.damaged);
    expect(fs.classify(const FormatException('bad zip')), FileTrouble.damaged);
  });

  test('a file opened once, read in parts, closed; the share out of reach is tried again next time', () async {
    final share = _Share({'': []})..files['Comics/Saga 1.cbz'] = Uint8List.fromList(List.generate(100, (i) => i));
    var tries = 0;
    final fs = SmbFs('nas', 'books', null, connect: (_, __, ___) async {
      if (++tries == 1) throw const Smb2Exception('no route', type: Smb2ErrorType.connection);
      return share;
    });
    expect(await fs.placeAnswers(r'\\nas\books\Comics'), isFalse);
    expect(await fs.placeAnswers(r'\\nas\books\Comics'), isTrue, reason: 'connected again');
    final f = await fs.open(r'\\nas\books\Comics\Saga 1.cbz');
    expect(await f.length(), 100);
    expect(await f.readRange(10, 3), [10, 11, 12]);
    expect(await f.readRange(98, 10), [98, 99], reason: 'fewer only at the end, as a file on the device');
    await f.close();
    expect(share.closed, 1);
    expect(await readWhole(fs, r'\\nas\books\Comics\Saga 1.cbz'), hasLength(100));
  });

  group('the shares', () {
    setUp(() => FlutterSecureStorage.setMockInitialValues({}));

    test("Windows reads a share itself (its own login); elsewhere through the app's SMB client - one connection per "
        'share, whatever the case it is written in', () {
      final windows = Shares(viaApp: false);
      expect(windows.fsFor(r'\\nas\books\Comics'), isA<LocalFs>());
      final tablet = Shares(viaApp: true, connect: (_, __, ___) async => _Share({}));
      expect(tablet.fsFor('/storage/emulated/0/Comics'), isA<LocalFs>());
      final a = tablet.fsFor(r'\\nas\books\Comics'), b = tablet.fsFor('smb://NAS/Books/Manga');
      expect(a, isA<SmbFs>());
      expect(b, same(a));
      expect(tablet.fsFor(r'\\nas\other'), isNot(same(a)));
    });

    test('a login kept for its share, encrypted; read back at the next start; the connection made again with it',
        () async {
      final logins = <SmbLogin?>[];
      final share = _Share({'': []});
      final shares = Shares(viaApp: true, connect: (_, __, login) async {
        logins.add(login);
        return share;
      });
      await shares.fsFor(r'\\nas\books').exists(r'\\nas\books');
      await shares.setLogin(r'\\NAS\books\Comics', const SmbLogin('nick', 'p4ss'));
      expect(share.disconnected, 1, reason: 'the old connection let go');
      await shares.fsFor(r'\\nas\books').exists(r'\\nas\books');
      expect([for (final l in logins) l?.user], [null, 'nick']);

      final next = Shares(viaApp: true);
      await next.load();
      expect(next.loginFor(r'\\nas\books\Manga')?.password, 'p4ss');
      expect(next.loginForHost('NAS')?.user, 'nick');
      expect(next.loginForHost('other'), isNull);
      await next.setLogin(r'\\nas\books', null);
      final after = Shares(viaApp: true);
      await after.load();
      expect(after.loginFor(r'\\nas\books'), isNull);
    });
  });

  test("a share's new login: what holds files open through it lets them go first, then the old connection closes (a "
      'book open on it lost its pages - the review, 2026-10-26)', () async {
    FlutterSecureStorage.setMockInitialValues({});
    final order = <String>[];
    final share = _Share({'': []});
    final shares = Shares(viaApp: true, connect: (_, __, ___) async => share)
      ..beforeReconnect = () async => order.add('files let go');
    await shares.fsFor(r'\\nas\books').exists(r'\\nas\books');
    await shares.setLogin(r'\\nas\books', const SmbLogin('nick', 'p'));
    order.add('disconnected ${share.disconnected}');
    expect(order, ['files let go', 'disconnected 1']);
    await shares.setLogin(r'\\nas\other', const SmbLogin('nick', 'p'));
    expect(order, hasLength(2), reason: 'nothing open on that share: nothing to let go');
  });

  test("a file replaced whole on a share (it can't rename over one): the new one written beside it, the old one "
      'deleted, the new one renamed into its place; a file not there yet is just made', () async {
    final share = _Share({'': const []})..files['Saga/.bedereader.json'] = Uint8List.fromList([1]);
    final fs = SmbFs('nas', 'books', null, connect: (_, __, ___) async => share);
    await fs.writeWhole(r'\\nas\books\Saga\.bedereader.json', Uint8List.fromList([2]));
    expect(share.writes, ['write Saga/.bedereader.json.bedereader-new', 'delete Saga/.bedereader.json',
        'rename Saga/.bedereader.json.bedereader-new']);
    expect(share.files['Saga/.bedereader.json'], [2]);
    share.writes.clear();
    await fs.writeWhole(r'\\nas\books\Saga\series.json', Uint8List.fromList([3]));
    expect(share.writes, ['write Saga/series.json.bedereader-new', 'rename Saga/series.json.bedereader-new']);
  });

  test("Windows's net view: the folder shares under the dashed line, hidden ones left out", () {
    const out = 'Shared resources at \\\\NAS\r\n\r\nShare name  Type  Used as  Comment\r\n'
        '-------------------------------------------------\r\n'
        'Comics      Disk           Books\r\nIPC\$        IPC\r\nadmin\$      Disk\r\nPrinter     Print\r\n'
        'Media Files Disk\r\nThe command completed successfully.\r\n';
    expect(netViewShares(out), ['Comics', 'Media Files']);
  });
}
