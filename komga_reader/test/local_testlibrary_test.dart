// Local mode against the real test library (experimental/sources, EXPERIMENT.md): C:\Claude\BeDeReader-TestLibrary.
// Skipped where it isn't. Prints what the scan made of it.
@Tags(['slow'])
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:komga_reader/local/folder_komga.dart';
import 'package:komga_reader/local/folder_scan.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _root = r'C:\Claude\BeDeReader-TestLibrary';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final here = Directory(_root).existsSync();

  test('the test library, scanned: its libraries, series and books, pages out of the CBZs, posters made', () async {
    SharedPreferences.setMockInitialValues({});
    final data = await Directory.systemTemp.createTemp('local_testlib');
    addTearDown(() => data.delete(recursive: true));
    final libs = [for (final n in ['Ongoing', 'Golden Age', 'Spider-Man', 'Books']) LocalLibrary.at('$_root\\$n')];
    final watch = Stopwatch()..start();
    final api = await FolderKomga.open(libs, dataDir: data);
    // ignore: avoid_print
    print('scanned in ${watch.elapsedMilliseconds} ms');
    expect((await api.libraries()).map((l) => l['name']), ['Books', 'Golden Age', 'Ongoing', 'Spider-Man']);
    for (final l in await api.libraries()) {
      final series = (await api.series(libraryId: l['id'] as String, size: 100))['content'] as List;
      for (final s in series) {
        final books = (await api.seriesBooks(s['id'] as String))['content'] as List;
        // ignore: avoid_print
        print('${l['name']} / ${s['name']}: ${[
          for (final b in books)
            '#${b['metadata']['number']} "${b['metadata']['title']}" ${b['media']['pagesCount']}p ${b['metadata']['releaseDate'] ?? ''}'
        ].join(', ')}');
      }
    }
    expect((await api.books(size: 100))['totalElements'], 31);
    final batman = ((await api.searchBooks('Absolute Batman'))['content'] as List).first as Map;
    final page = await api.pageBytes(batman['id'] as String, 1);
    expect(page.length, greaterThan(10000), reason: 'a page out of the CBZ');
    final made = await Future.wait([
      for (final b in (await api.books(size: 100))['content'] as List) api.thumbAt(api.bookThumb(b['id'] as String)),
    ]);
    // ignore: avoid_print
    print('posters: ${made.where((m) => m).length} in ${watch.elapsedMilliseconds} ms from the start');
    expect(made.where((m) => m).length, 31);
  }, skip: here ? false : 'no test library here', timeout: const Timeout(Duration(minutes: 3)));
}
