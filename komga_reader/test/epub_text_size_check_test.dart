// Opt-in: every EPUB under BEDEREADER_EPUB_DIR - the book's own text size as the reader finds it (bookTextSize over
// its sampled chapters), a line per book to BEDEREADER_EPUB_PROGRESS. Shows which books the rule changes (any size
// but 1). Skipped unless the folder is given.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:komga_reader/epub/book.dart';
import 'package:komga_reader/epub/hyphenator.dart';
import 'package:komga_reader/epub/source.dart';

void main() {
  final dir = Platform.environment['BEDEREADER_EPUB_DIR'];
  final progress = Platform.environment['BEDEREADER_EPUB_PROGRESS'];
  testWidgets("each book's own text size", (tester) async {
    await tester.runAsync(() async {
      void note(String l) {
        if (progress != null) File(progress).writeAsStringSync('$l\n', mode: FileMode.append, flush: true);
      }

      final hy = await Hyphenators.load((p) async => File(p).readAsStringSync());
      final files = Directory(dir!).listSync(recursive: true).whereType<File>()
          .where((f) => f.path.toLowerCase().endsWith('.epub')).toList()
        ..sort((a, b) => a.path.compareTo(b.path));
      note('${files.length} books');
      var i = 0, changed = 0;
      for (final f in files) {
        i++;
        final name = f.uri.pathSegments.last.replaceAll('.epub', '');
        try {
          final s = FileEpubSource(f);
          final book = EpubBook(s, await s.info(), hy);
          await book.measureTextSize();
          if (book.textSize != 1) changed++;
          note('$i/${files.length} ${book.textSize == 1 ? '  ' : '* '}${book.textSize.toStringAsFixed(2)} $name');
          book.dispose();
        } catch (e) {
          note('$i/${files.length} ?? $name: $e');
        }
      }
      note('done: $changed of ${files.length} books have their own text size');
    });
  }, skip: dir == null, timeout: const Timeout(Duration(minutes: 40)));
}
