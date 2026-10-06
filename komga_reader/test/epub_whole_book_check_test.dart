// Opt-in: EVERY chapter of one EPUB (BEDEREADER_EPUB_FILE), loaded (pictures decoded) and laid out in the reader's
// default font - Literata, loaded for real (tests otherwise lay text out in a test font) - a progress line per
// chapter to BEDEREADER_EPUB_PROGRESS. To find a chapter that crashes the engine (Mistborn on the PC, builds 66-67,
// crashed while the reader counted its chapters). Skipped unless the file is given.
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:komga_reader/epub/chapter.dart';
import 'package:komga_reader/epub/hyphenator.dart';
import 'package:komga_reader/epub/layout.dart';
import 'package:komga_reader/epub/source.dart';

void main() {
  final path = Platform.environment['BEDEREADER_EPUB_FILE'];
  final progress = Platform.environment['BEDEREADER_EPUB_PROGRESS'];
  testWidgets('every chapter of the book loads and lays out in Literata', (tester) async {
    await tester.runAsync(() async {
      Future<ByteData> bytes(String f) async => ByteData.sublistView(File(f).readAsBytesSync());
      await (FontLoader('Literata')
            ..addFont(bytes('assets/fonts/Literata.ttf'))
            ..addFont(bytes('assets/fonts/Literata-Italic.ttf')))
          .load();
      final hy = await Hyphenators.load((p) async => File(p).readAsStringSync());
      final s = FileEpubSource(File(path!));
      final info = await s.info();
      final loader = ChapterLoader(s);
      void note(String l) {
        if (progress != null) File(progress).writeAsStringSync('$l\n', mode: FileMode.append, flush: true);
      }
      note('${info.spine.length} chapters');
      for (var i = 0; i < info.spine.length; i++) {
        note('$i ${info.spine[i]} loading');
        final c = await loader.load(info.spine[i]);
        note('$i laying out (${c.blocks.length} blocks)');
        final p = Paginator(const EpubTheme(fontFamily: 'Literata', bookFormatting: false), const Size(646, 1000),
            hy.forLang(c.lang));
        final pages = p.run(c.blocks);
        note('$i ok ${pages.length} pages, starts ${pages.map((p) => p.start).join(',')}');
        p.dispose();
        c.dispose();
      }
      note('all done');
    });
  }, skip: path == null, timeout: const Timeout(Duration(minutes: 30)));
}
