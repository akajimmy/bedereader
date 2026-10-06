// Opt-in: the footnote markers of one EPUB (BEDEREADER_EPUB_FILE) - for every link that looks like a note marker in
// the chapters, the text the engine made around it, to BEDEREADER_EPUB_PROGRESS. Skipped unless the file is given.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:komga_reader/epub/chapter.dart';
import 'package:komga_reader/epub/layout.dart';
import 'package:komga_reader/epub/source.dart';

void main() {
  final path = Platform.environment['BEDEREADER_EPUB_FILE'];
  final progress = Platform.environment['BEDEREADER_EPUB_PROGRESS'];
  testWidgets('note markers: the text around each one', (tester) async {
    await tester.runAsync(() async {
      void note(String l) {
        if (progress != null) File(progress).writeAsStringSync('$l\n', mode: FileMode.append, flush: true);
      }

      final s = FileEpubSource(File(path!));
      final info = await s.info();
      final loader = ChapterLoader(s);
      var shown = 0, links = 0;
      for (var i = 0; i < info.spine.length && shown < 12; i++) {
        final c = await loader.load(info.spine[i]);
        for (final b in c.blocks.whereType<TextBlock>()) {
          for (var k = 0; k < b.runs.length; k++) {
            final r = b.runs[k];
            if (r.style.link == null || r.text.trim().length > 6) continue;
            links++;
            if (shown >= 12) continue;
            shown++;
            final before = b.runs.take(k).map((x) => x.text).join();
            final after = b.runs.skip(k + 1).map((x) => x.text).join();
            note('$i ...${before.substring(before.length < 40 ? 0 : before.length - 40)}'
                '[[${r.text}]]${after.substring(0, after.length < 25 ? after.length : 25)}... -> ${r.style.link} '
                '(sup ${r.style.sup}, size ${r.style.size.toStringAsFixed(2)})');
          }
        }
        c.dispose();
      }
      note('marker links seen: $links');
    });
  }, skip: path == null, timeout: const Timeout(Duration(minutes: 10)));
}
