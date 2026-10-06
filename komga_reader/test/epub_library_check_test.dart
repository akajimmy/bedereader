// Opt-in: every .epub under the folder in BEDEREADER_EPUB_DIR, read from its file (read-only) - contents, the first
// chapters loaded and laid out. Skipped unless the variable is set; e.g. (PowerShell)
//   $env:BEDEREADER_EPUB_DIR = '\\nick-nas\nas-share\comics\E-Books'; flutter test test/epub_library_check_test.dart
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:komga_reader/epub/chapter.dart';
import 'package:komga_reader/epub/hyphenator.dart';
import 'package:komga_reader/epub/layout.dart';
import 'package:komga_reader/epub/source.dart';

void main() {
  final dir = Platform.environment['BEDEREADER_EPUB_DIR'];
  testWidgets('every EPUB in the library opens, has contents, and its first chapters lay out', (tester) async {
    await tester.runAsync(() async {
      final hy = await Hyphenators.load((p) async => File(p).readAsStringSync());
      final files = Directory(dir!).listSync(recursive: true).whereType<File>()
          .where((f) => f.path.toLowerCase().endsWith('.epub')).toList();
      final problems = <String>[];
      var noToc = 0, chapters = 0, pages = 0;
      final sw = Stopwatch()..start();
      // progress, readable while it runs: BEDEREADER_EPUB_PROGRESS (a file), a line every 25 books
      final progress = Platform.environment['BEDEREADER_EPUB_PROGRESS'];
      var done = 0;
      for (final f in files) {
        if (progress != null && done++ % 25 == 0) {
          File(progress).writeAsStringSync('${DateTime.now()} $done/${files.length} books, ${problems.length} '
              'problems\n', mode: FileMode.append, flush: true);
        }
        final name = f.path.split(RegExp(r'[\\/]')).last;
        try {
          final s = FileEpubSource(f);
          final info = await s.info();
          if (info.spine.isEmpty) {
            problems.add('$name: no chapters');
            continue;
          }
          if (info.toc.isEmpty) noToc++;
          final loader = ChapterLoader(s);
          for (final path in info.spine.take(3)) {
            final c = await loader.load(path);
            chapters++;
            pages += Paginator(const EpubTheme(), const Size(800, 1200), hy.forLang(c.lang)).run(c.blocks).length;
            c.dispose();
          }
        } catch (e) {
          problems.add('$name: $e');
        }
      }
      // ignore: avoid_print
      print('${files.length} books, $chapters chapters laid out ($pages pages) in ${sw.elapsed.inSeconds} s; '
          '$noToc without a table of contents; ${problems.length} problems${problems.isEmpty ? '' : ':\n  '}'
          '${problems.join('\n  ')}');
      expect(problems, isEmpty);
    });
  }, skip: dir == null, // set BEDEREADER_EPUB_DIR to a folder of EPUBs
      timeout: const Timeout(Duration(minutes: 20)));
}
