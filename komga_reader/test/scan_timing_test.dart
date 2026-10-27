// The local libraries' scans and the library list changing while one runs (the review of 1.6, 2026-10-26): a library
// added doesn't wait for the scan; one removed during a scan isn't asked about afterwards.
import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:komga_reader/local/local_library.dart';
import 'package:komga_reader/local/local_source.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/memory_fs.dart';
import 'support/zip_writer.dart';

/// Files in memory whose scans wait at [gate] (asked whether a library's folder is there).
class _Held extends MemoryFs {
  _Held() : super({});
  var gate = Completer<void>();

  @override
  Future<bool> exists(String folder) async {
    await gate.future;
    return super.exists(folder);
  }
}

void main() {
  late Directory data;
  late LocalSource local;
  late _Held fs;
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    data = await Directory.systemTemp.createTemp('scan_timing');
    fs = _Held();
    local = await LocalSource.open(data, const [], fsFor: (_) => fs);
  });
  tearDown(() async {
    if (!fs.gate.isCompleted) fs.gate.complete();
    await local.rescan();
    await local.closeFiles();
    await data.delete(recursive: true);
  });

  test("a library added is kept and listed at once - the scan isn't waited for (the first scan of a big library kept "
      'the sign-in screen waiting, with nothing said)', () async {
    await local.setLibraries([const LocalLibrary('Comics', 'Comics')]).timeout(const Duration(seconds: 2));
    expect(local.folders.single.name, 'Comics');
    await pumpEventQueue(); // (the scan's first step)
    expect(local.scanning.value, isNotNull, reason: 'its scan running, told as it goes');
    fs.gate.complete();
    await local.rescan();
    expect(local.scanning.value, isNull);
  });

  test('a library removed while it was being scanned (its folder looking deleted) is not asked about afterwards',
      () async {
    await local.setLibraries([const LocalLibrary('Gone', 'gone')]).timeout(const Duration(seconds: 2));
    final asked = <List<LocalLibrary>>[];
    local.missing.addListener(() => asked.add(local.missing.value));
    final removed = local.setLibraries(const []); // while its scan waits
    fs.gate.complete();
    await removed;
    await local.rescan();
    expect(asked.where((l) => l.isNotEmpty), isEmpty);
  });

  test("a library removed while it's being scanned stays removed - its books don't come back when the scan ends (the "
      "experiment's review: they did, until the next scan)", () async {
    fs.files['Comics/Saga/Saga 1.cbz'] = zipOf({'p1.png': pngHead(800, 1200)});
    await local.setLibraries([const LocalLibrary('Comics', 'Comics')]).timeout(const Duration(seconds: 2));
    final removed = local.setLibraries(const []); // while its scan waits
    fs.gate.complete();
    await removed;
    await local.rescan();
    expect(local.store.libraries, isEmpty);
    expect((await local.books())['content'], isEmpty);
  });

  test("a library renamed while it's being scanned keeps its new name when the scan ends", () async {
    fs.files['Comics/Saga/Saga 1.cbz'] = zipOf({'p1.png': pngHead(800, 1200)});
    await local.setLibraries([const LocalLibrary('Comics', 'Comics')]).timeout(const Duration(seconds: 2));
    final renamed = local.setLibraries([const LocalLibrary('My comics', 'Comics')]); // while its scan waits
    fs.gate.complete();
    await renamed;
    await local.rescan();
    expect([for (final l in await local.libraries()) l['name']], ['My comics']);
    expect((await local.books())['content'], hasLength(1));
  });
}
