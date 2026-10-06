// Opt-in: sample pages of many books, drawn as the reader draws them on the tablet (800 x 1230 page area at 1.5 screen
// pixels a point, the tablet's settings, the reader's own formatting, dark), saved as PNGs for looking through - to find what
// the engine gets wrong across a real library. BEDEREADER_EPUB_LIST: a text file with one EPUB path a line;
// BEDEREADER_EPUB_OUT: the folder for the pictures (book number - which page .png). Skipped unless both are given.
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
  final out = Platform.environment['BEDEREADER_EPUB_OUT'];
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
      final paths = File(list!).readAsLinesSync().where((l) => l.trim().isNotEmpty).toList();
      for (final (n, path) in paths.indexed) {
        final log = File('$out${Platform.pathSeparator}log.txt');
        try {
          final s = FileEpubSource(File(path.trim()));
          final info = await s.info();
          final book = EpubBook(s, info, hy)..setLayout(theme, size);
          await book.measureTextSize();
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
            final p = pages[page.clamp(0, pages.length - 1)];
            final rec = ui.PictureRecorder();
            final canvas = Canvas(rec)..drawRect(Offset.zero & size, Paint()..color = theme.background);
            for (final piece in p.pieces) {
              piece.paint(canvas);
            }
            final img = await rec.endRecording().toImage(size.width.toInt(), size.height.toInt());
            final data = await img.toByteData(format: ui.ImageByteFormat.png);
            final file = '${n.toString().padLeft(2, '0')}-$name.png';
            File('$out${Platform.pathSeparator}$file').writeAsBytesSync(data!.buffer.asUint8List());
          }
          log.writeAsStringSync('$n ok size ${book.textSize} bold ${book.textBold} '
              'front $front first $first mid $mid | ${path.split(RegExp(r'[\\/]')).last}\n', mode: FileMode.append);
          book.dispose();
        } catch (e) {
          log.writeAsStringSync('$n FAILED $e | $path\n', mode: FileMode.append);
        }
      }
    });
  }, skip: list == null || out == null, timeout: const Timeout(Duration(minutes: 30)));
}
