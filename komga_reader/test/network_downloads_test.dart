// Network books downloaded (user, 2026-10-27: "I want download to work for network books" - with Komga's downloads:
// the same queue, limits and cache): the file copied whole into a store of its own, read from the copy - while the
// share is out of reach too; a share that stops answering makes the book wait, not fail. A book in a folder on the
// device isn't downloaded: it's here.
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:komga_reader/local/library_fs.dart';
import 'package:komga_reader/local/local_library.dart';
import 'package:komga_reader/local/local_source.dart';
import 'package:komga_reader/offline/catalogue_source.dart' show NotAvailableOffline;
import 'package:komga_reader/offline/connection.dart';
import 'package:komga_reader/offline/downloads.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/zip_writer.dart';

/// A share, \\nas\books, kept in a folder here: out of reach while [away] (the error a share's own is - no answer).
class _Share implements LibraryFs {
  _Share(this.dir);
  final Directory dir;
  bool away = false;
  final _real = LocalFs();
  int opened = 0;

  String _here(String path) => path.replaceFirst(RegExp(r'^\\\\nas\\books'), dir.path);
  void _check() {
    if (away) throw const _Away();
  }

  @override
  Future<bool> exists(String folder) async {
    _check();
    return _real.exists(_here(folder));
  }

  @override
  Future<bool> placeAnswers(String folder) async => !away;
  @override
  Stream<FsEntry> list(String folder, {void Function(String folder, Object error)? onUnreadable}) async* {
    _check();
    await for (final e in _real.list(_here(folder), onUnreadable: onUnreadable)) {
      yield FsEntry(e.path.replaceFirst(dir.path, r'\\nas\books'), e.size, e.modified);
    }
  }

  @override
  Future<LibraryFile> open(String path) async {
    _check();
    opened++;
    return _AwayFile(this, await _real.open(_here(path)));
  }

  @override
  Future<FolderLook> look(String folder) => _real.look(_here(folder));
  @override
  FileTrouble classify(Object error) => error is _Away ? FileTrouble.noAnswer : _real.classify(error);
}

class _AwayFile implements LibraryFile {
  _AwayFile(this.share, this.inner);
  final _Share share;
  final LibraryFile inner;
  @override
  Future<int> length() => inner.length();
  @override
  Future<Uint8List> readRange(int offset, int length) async {
    share._check();
    return inner.readRange(offset, length);
  }

  @override
  Future<void> close() => inner.close();
}

class _Away implements Exception {
  const _Away();
}

void main() {
  final d = Downloads.instance;
  late Directory shareDir, deviceDir, data, root;
  late _Share share;
  late LocalSource local;
  final page = Uint8List.fromList([...pngHead(20, 30), ...List.generate(3000, (i) => i & 0xff)]);

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    d.reset();
    Downloads.serverRecheck = const Duration(milliseconds: 50);
    shareDir = await Directory.systemTemp.createTemp('net_share');
    deviceDir = await Directory.systemTemp.createTemp('net_device');
    data = await Directory.systemTemp.createTemp('net_data');
    root = await Directory.systemTemp.createTemp('net_downloads');
    for (final dir in [shareDir, deviceDir]) {
      final f = File('${dir.path}${Platform.pathSeparator}Saga${Platform.pathSeparator}Saga 1.cbz');
      await f.parent.create();
      await f.writeAsBytes(zipOf({'1.png': page, '2.png': page}));
    }
    share = _Share(shareDir);
    local = await LocalSource.open(data, [LocalLibrary.at(r'\\nas\books'), LocalLibrary.at(deviceDir.path)],
        fsFor: (p) => p.startsWith(r'\\') ? share : LocalFs());
    await local.rescan();
    await d.attachLocal(local, root: root);
  });
  tearDown(() async {
    await d.localStore?.written; // (a save still on its way, before the folder goes)
    d.reset();
    Downloads.serverRecheck = const Duration(seconds: 30);
    await local.closeFiles();
    await local.store.written; // (the pages' sizes being saved)
    for (final dir in [shareDir, deviceDir, data, root]) {
      await dir.delete(recursive: true);
    }
  });

  Future<Map> book({required bool onShare}) async {
    final all = (await local.books(size: 10))['content'] as List;
    return all.firstWhere((b) => ('${b['url']}'.startsWith(r'\\')) == onShare) as Map;
  }

  Future<void> settled() async {
    for (var i = 0; i < 200 && (d.busy || d.queue.any((j) => j.state.name != 'failed')); i++) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
  }

  test("a network book downloaded: its file copied whole, listed as downloaded - and read from the copy while the "
      'share is out of reach', () async {
    final b = await book(onShare: true);
    final id = b['id'] as String;
    expect(d.canDownload(id), isTrue);
    expect(await d.add([b]), 1);
    await settled();
    expect(d.isDownloaded(id), isTrue);
    final copy = d.localCopyOf(id)!;
    expect(await File(copy).length(), b['sizeBytes']);
    expect(d.usedBytes, b['sizeBytes'], reason: 'counted in the downloads limit with Komga\'s');

    await local.closeFiles();
    share.away = true;
    expect(await local.pages(id), hasLength(2));
    expect(await local.pageBytes(id, 2), page);
  });

  test("a book in a folder on the device isn't downloaded: it's here already", () async {
    final b = await book(onShare: false);
    expect(d.canDownload(b['id'] as String), isFalse);
    expect(await d.add([b]), 0);
  });

  test("the share stops answering: the book waits in the queue (not failed), and goes on once it's back", () async {
    final b = await book(onShare: true);
    final id = b['id'] as String;
    share.away = true;
    await d.add([b]);
    for (var i = 0; i < 50 && !d.waitingForShare; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    expect(d.waitingForShare, isTrue);
    expect(d.jobFor(id)?.state, JobState.queued);
    share.away = false;
    await Future<void>.delayed(const Duration(milliseconds: 120)); // (looked at again)
    await settled();
    expect(d.isDownloaded(id), isTrue);
  });

  test('opened, a network book is cached like a Komga book; finished, its cached copy goes', () async {
    final b = await book(onShare: true);
    final id = b['id'] as String;
    await d.cacheBook(b);
    await settled();
    expect(d.isCached(id), isTrue);
    expect(d.isDownloaded(id), isFalse, reason: 'not a download');
    await local.markRead(id);
    for (var i = 0; i < 100 && d.isCached(id); i++) {
      await Future<void>.delayed(const Duration(milliseconds: 20)); // (it goes in the background)
    }
    expect(d.isCached(id), isFalse);
    await d.localStore!.written;
  });

  group('offline mode is the network libraries\' too (user, 2026-10-27)', () {
    tearDown(Connection.instance.reset);

    test("offline: a network library shows only its books with a copy here, isn't scanned, and a book without a "
        "copy doesn't open; a folder on the device is as always; online again, all of it is back", () async {
      final f = File('${shareDir.path}${Platform.pathSeparator}Saga${Platform.pathSeparator}Saga 2.cbz');
      await f.writeAsBytes(zipOf({'1.png': page}));
      await local.rescan();
      final onShare = [
        for (final b in (await local.books(size: 10))['content'] as List)
          if ('${b['url']}'.startsWith(r'\\')) b as Map,
      ]..sort((a, b) => '${a['name']}'.compareTo('${b['name']}'));
      final (one, two) = (onShare[0]['id'] as String, onShare[1]['id'] as String);
      await d.add([onShare[0]]);
      await settled();
      expect(d.isDownloaded(one), isTrue);
      final deviceBook = (await book(onShare: false))['id'] as String;
      // every book's poster there (the scans offline mustn't take the hidden ones')
      final posters = [for (final id in [one, two, deviceBook]) File(local.bookThumb(id))];
      for (final p in posters) {
        await p.parent.create(recursive: true);
        await p.writeAsBytes([1]);
      }

      local.offline = true;
      final ids = {for (final b in (await local.books(size: 10))['content'] as List) b['id']};
      expect(ids, {one, deviceBook}, reason: 'the copied one and the device\'s; not the share\'s other');
      await expectLater(local.pages(two), throwsA(isA<NotAvailableOffline>()));
      share.away = true;
      await local.rescan();
      expect(local.lastScan.keys, isNot(contains(LocalLibrary.at(r'\\nas\books').id)), reason: 'its share not asked');
      expect([for (final p in posters) p.existsSync()], everyElement(isTrue), reason: 'hidden, not gone');

      share.away = false;
      local.offline = false;
      expect({for (final b in (await local.books(size: 10))['content'] as List) b['id']}, {one, two, deviceBook});
    });

    test("offline: a network book's download waits in the queue (nothing read from the share), and goes on once "
        "online", () async {
      final b = await book(onShare: true);
      final id = b['id'] as String;
      d.hold = true;
      final opened = share.opened;
      await d.add([b]);
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(d.jobFor(id)?.state, JobState.queued);
      expect(share.opened, opened);
      d.hold = false;
      await settled();
      expect(d.isDownloaded(id), isTrue);
    });

    test('the Offline mode switch is there for Komga or a network library - not for the folders on this device alone '
        '(it stayed after signing out, in No server mode)', () async {
      final c = Connection.instance;
      expect(c.online, isNull);
      expect(c.available, isFalse, reason: 'no Komga, no share known');
      c.hasShares = () => local.hasShares;
      expect(c.available, isTrue, reason: 'a network library');
      final deviceOnly = await LocalSource.open(await data.createTemp('only'), [LocalLibrary.at(deviceDir.path)]);
      addTearDown(deviceOnly.closeFiles);
      c.hasShares = () => deviceOnly.hasShares;
      expect(c.available, isFalse, reason: 'folders on this device only');
    });
  });

  group('Storage & Downloads (user, 2026-10-27): a cache limit, Clear cache, and either limit Off', () {
    tearDown(() => Downloads.cacheCap = Downloads.defaultCacheCap);

    test("the cache limit Off: nothing is cached, the book is read from its source; the limit is kept on the device",
        () async {
      await d.setCacheCap(0);
      final b = await book(onShare: true);
      await d.cacheBook(b);
      await settled();
      expect(d.isCached(b['id'] as String), isFalse);
      expect(d.queue, isEmpty);
      Downloads.cacheCap = Downloads.defaultCacheCap;
      await d.attachLocal(local, root: root); // (the settings read again, as at a start)
      expect(Downloads.cacheCap, 0);
    });

    test('Clear cache: the cached copies go, the downloaded ones stay; a lower limit trims the cache at once',
        () async {
      final f = File('${shareDir.path}${Platform.pathSeparator}Saga${Platform.pathSeparator}Saga 2.cbz');
      await f.writeAsBytes(zipOf({'1.png': page, '2.png': page}));
      await local.rescan();
      final onShare = [
        for (final b in (await local.books(size: 10))['content'] as List)
          if ('${b['url']}'.startsWith(r'\\')) b as Map,
      ];
      final (cached, downloaded) = (onShare[0], onShare[1]);
      await d.cacheBook(cached);
      await d.add([downloaded]);
      await settled();
      expect((d.isCached(cached['id'] as String), d.isDownloaded(downloaded['id'] as String)), (true, true));
      await d.clearCache();
      expect(d.isCached(cached['id'] as String), isFalse);
      expect(d.isDownloaded(downloaded['id'] as String), isTrue);
      expect(d.cacheBytes, 0);

      await d.cacheBook(cached);
      await settled();
      expect(d.isCached(cached['id'] as String), isTrue);
      await d.setCacheCap(1); // (smaller than any book)
      expect(d.isCached(cached['id'] as String), isFalse, reason: 'trimmed to the new limit');
    });

    test('the downloads limit Off: nothing downloads - the book stops for lack of room, nothing breaks', () async {
      await d.setCap(0);
      final b = await book(onShare: true);
      await d.add([b]);
      await settled();
      expect(d.isDownloaded(b['id'] as String), isFalse);
      expect(d.jobFor(b['id'] as String)?.state, JobState.failed);
      await d.setCap(Downloads.defaultCap);
    });
  });

  test("the queue's network books are kept for the next start, in their own store", () async {
    final b = await book(onShare: true);
    d.pauseAll();
    await d.add([b]);
    await settled();
    d.queue.clear();
    await d.attachLocal(local, root: root);
    expect([for (final j in d.queue) j.bookId], [b['id']]);
    d.resumeAll();
    await settled();
  });
}
