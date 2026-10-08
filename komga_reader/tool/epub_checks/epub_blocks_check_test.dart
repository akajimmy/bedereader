// Opt-in: the blocks the engine makes of one chapter (BEDEREADER_EPUB_FILE, BEDEREADER_EPUB_CHAPTER - a file name in
// the book), one line each - alignment, indent, margins, float, border, the start of the text - to
// BEDEREADER_EPUB_PROGRESS. To see why a page lays out as it does. Skipped unless the file is given.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:komga_reader/epub/chapter.dart';
import 'package:komga_reader/epub/layout.dart';
import 'package:komga_reader/epub/source.dart';

void main() {
  final path = Platform.environment['BEDEREADER_EPUB_FILE'];
  final chapter = Platform.environment['BEDEREADER_EPUB_CHAPTER'];
  final progress = Platform.environment['BEDEREADER_EPUB_PROGRESS'];
  testWidgets("a chapter's blocks", (tester) async {
    await tester.runAsync(() async {
      void note(String l) => File(progress!).writeAsStringSync('$l\n', mode: FileMode.append, flush: true);
      final s = FileEpubSource(File(path!));
      final info = await s.info();
      final c = await ChapterLoader(s).load(info.spine.firstWhere((p) => p.endsWith(chapter!)));
      for (final b in c.blocks.take(12)) {
        switch (b) {
          case TextBlock():
            final text = b.runs.map((r) => r.text).join();
            note('text align=${b.align.name} indent=${b.indent} left=${b.left} right=${b.right} '
                'top=${b.marginTop} bottom=${b.marginBottom} para=${b.paragraph} drop=${b.drop?.text} '
                'float=${b.floatImage != null} box=${b.box != null} sizes=${b.runs.map((r) => r.style.size).toSet()} '
                'bold=${b.runs.map((r) => r.style.bold).toSet()} | ${text.substring(0, text.length.clamp(0, 50))}');
          case ImageBlock():
            note('image ${b.src}');
          case TableBlock():
            note('table');
        }
      }
    });
  }, skip: path == null || chapter == null || progress == null);
}
