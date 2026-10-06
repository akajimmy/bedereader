// Opt-in: the page of one EPUB (BEDEREADER_EPUB_FILE) holding its first note link, drawn as the reader draws it in
// Literata, saved as a PNG (BEDEREADER_EPUB_PNG) - to see what's on screen without the app. Skipped unless given.
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/painting.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:komga_reader/epub/book.dart';
import 'package:komga_reader/epub/chapter.dart';
import 'package:komga_reader/epub/hyphenator.dart';
import 'package:komga_reader/epub/layout.dart';
import 'package:komga_reader/epub/source.dart';

void main() {
  final path = Platform.environment['BEDEREADER_EPUB_FILE'];
  final png = Platform.environment['BEDEREADER_EPUB_PNG'];
  testWidgets('the page with the first note link, as a picture', (tester) async {
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
      const size = Size(646, 1000);
      for (var i = 0; i < info.spine.length; i++) {
        final c = await loader.load(info.spine[i]);
        if (Platform.environment['BEDEREADER_EPUB_CHAPTER'] case final w? when !info.spine[i].endsWith(w)) continue;
        // the book's own text size and weight, as the reader measures them
        final book = EpubBook(s, info, hy);
        await book.measureTextSize();
        final pages = Paginator(const EpubTheme(fontFamily: 'Literata', bookFormatting: false), size,
            hy.forLang(c.lang), baseSize: book.textSize, baseBold: book.textBold).run(c.blocks);
        // BEDEREADER_EPUB_CHAPTER (a file name in the book): that chapter's first page; else the first note link's
        final wanted = Platform.environment['BEDEREADER_EPUB_CHAPTER'];
        if (wanted != null && !info.spine[i].endsWith(wanted)) continue;
        final page = wanted != null ? pages.first : pages.where((p) => p.links.any((l) => l.text.length <= 6)).firstOrNull;
        if (page == null) continue;
        final rec = ui.PictureRecorder();
        final canvas = Canvas(rec)..drawRect(Offset.zero & size, Paint()..color = const EpubTheme().background);
        for (final p in page.pieces) {
          p.paint(canvas);
        }
        for (final l in page.links) {
          canvas.drawRect(l.rect, Paint()
            ..color = const Color(0xFFFF0000)
            ..style = PaintingStyle.stroke);
        }
        final img = await rec.endRecording().toImage(size.width.toInt(), size.height.toInt());
        final data = await img.toByteData(format: ui.ImageByteFormat.png);
        File(png!).writeAsBytesSync(data!.buffer.asUint8List());
        return;
      }
    });
  }, skip: path == null, timeout: const Timeout(Duration(minutes: 10)));
}
