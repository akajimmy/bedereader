// Opt-in: sample pages of EPUBs, drawn as the reader draws them on the tablet (800 x 1230 page area at 1.5 screen
// pixels a point, the tablet's settings, the reader's own formatting, dark), saved as PNGs for looking through - to
// find what the engine gets wrong across a real library, or to see one book's page without the app.
//   BEDEREADER_EPUB_LIST: a text file with one EPUB path a line - or BEDEREADER_EPUB_FILE: one EPUB;
//   BEDEREADER_EPUB_OUT: the folder for the pictures ("book number-which page.png") and log.txt.
// Each book: front matter, the first real chapter (two pages), one from the middle; with BEDEREADER_EPUB_FILE also the
// first page holding a note link, its links outlined in red. BEDEREADER_EPUB_CHAPTER (a file name in the book): only
// that chapter's first page. Skipped unless a book and the folder are given. From komga_reader\ (PowerShell):
//   $env:BEDEREADER_EPUB_FILE = 'D:\Books\Hogfather.epub'; $env:BEDEREADER_EPUB_OUT = 'C:\Temp\pages'
//   flutter test tool\epub_checks\epub_sample_pages_check_test.dart
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/painting.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:komga_reader/epub/book.dart';
import 'package:komga_reader/epub/hyphenator.dart';
import 'package:komga_reader/epub/layout.dart';
import 'package:komga_reader/epub/source.dart';

void main() {
  final list = Platform.environment['BEDEREADER_EPUB_LIST'];
  final one = Platform.environment['BEDEREADER_EPUB_FILE'];
  final out = Platform.environment['BEDEREADER_EPUB_OUT'];
  final wanted = Platform.environment['BEDEREADER_EPUB_CHAPTER'];
  testWidgets('sample pages of each book', (tester) async {
    await tester.runAsync(() async {
      Future<ByteData> bytes(String f) async => ByteData.sublistView(File(f).readAsBytesSync());
      await (FontLoader('Literata')
            ..addFont(bytes('assets/fonts/Literata.ttf'))
            ..addFont(bytes('assets/fonts/Literata-Italic.ttf')))
          .load();
      final hy = await Hyphenators.load((p) async => File(p).readAsStringSync());
      const size = Size(800, 1230);
      // the tablet's settings (2026-10-06): Literata 24, Large paragraph spacing, Wide margins
      const theme = EpubTheme(fontFamily: 'Literata', fontSize: 24, bookFormatting: false, pixelRatio: 1.5,
          paragraphGap: 1, margins: EdgeInsets.fromLTRB(64, 56, 64, 56), accent: Color(0xFF26A69A));
      final paths = one != null ? [one] : File(list!).readAsLinesSync().where((l) => l.trim().isNotEmpty).toList();
      final log = File('$out${Platform.pathSeparator}log.txt');

      Future<void> save(EpubPage p, String file, {bool outlineLinks = false}) async {
        final rec = ui.PictureRecorder();
        final canvas = Canvas(rec)..drawRect(Offset.zero & size, Paint()..color = theme.background);
        for (final piece in p.pieces) {
          piece.paint(canvas);
        }
        if (outlineLinks) {
          for (final l in p.links) {
            canvas.drawRect(l.rect, Paint()
              ..color = const Color(0xFFFF0000)
              ..style = PaintingStyle.stroke);
          }
        }
        final img = await rec.endRecording().toImage(size.width.toInt(), size.height.toInt());
        final data = await img.toByteData(format: ui.ImageByteFormat.png);
        File('$out${Platform.pathSeparator}$file').writeAsBytesSync(data!.buffer.asUint8List());
      }

      for (final (n, path) in paths.indexed) {
        final number = n.toString().padLeft(2, '0');
        try {
          final s = FileEpubSource(File(path.trim()));
          final info = await s.info();
          // the book's own text size and weight, as the reader measures them - once, before laying out
          final book = EpubBook(s, info, hy)..setLayout(theme, size);
          await book.measureTextSize();
          if (wanted != null) {
            final ch = info.spine.indexWhere((p) => p.endsWith(wanted));
            final pages = ch < 0 ? null : await book.pages(ch);
            if (pages != null && pages.isNotEmpty) await save(pages.first, '$number-chapter.png');
            log.writeAsStringSync('$number ${ch < 0 ? 'no chapter $wanted' : 'chapter $ch'} | $path\n',
                mode: FileMode.append);
            book.dispose();
            continue;
          }
          // the chapters to look at: front matter, the first real chapter (twice), one from the middle
          final lengths = <int>[];
          for (var i = 0; i < info.spine.length; i++) {
            final c = await book.loader.load(info.spine[i]);
            lengths.add(c.length);
            c.dispose();
          }
          final front = lengths.indexWhere((l) => l > 200);
          final first = lengths.indexWhere((l) => l > 8000);
          final mid = first < 0 ? -1 : lengths.indexWhere((l) => l > 8000, (first + info.spine.length) ~/ 2);
          final shots = <(String, int, int)>[('a-front', front, 0), ('b-chapter', first, 0), ('c-next', first, 1),
            ('d-middle', mid < 0 ? first : mid, 0)];
          for (final (name, ch, page) in shots) {
            if (ch < 0) continue;
            final pages = await book.pages(ch);
            if (pages == null || pages.isEmpty) continue;
            await save(pages[page.clamp(0, pages.length - 1)], '$number-$name.png');
          }
          // one book: the first page holding a note link (a short link text), its links outlined
          var note = -1;
          for (var i = 0; one != null && note < 0 && i < info.spine.length; i++) {
            final pages = await book.pages(i);
            final p = pages?.where((p) => p.links.any((l) => l.text.length <= 6)).firstOrNull;
            if (p != null) {
              await save(p, '$number-e-note.png', outlineLinks: true);
              note = i;
            }
          }
          log.writeAsStringSync('$number ok size ${book.textSize} bold ${book.textBold} '
              'front $front first $first mid $mid${one != null ? ' note $note' : ''} | '
              '${path.split(RegExp(r'[\\/]')).last}\n', mode: FileMode.append);
          book.dispose();
        } catch (e) {
          log.writeAsStringSync('$number FAILED $e | $path\n', mode: FileMode.append);
        }
      }
    });
  }, skip: (list == null && one == null) || out == null, timeout: const Timeout(Duration(minutes: 30)));
}
