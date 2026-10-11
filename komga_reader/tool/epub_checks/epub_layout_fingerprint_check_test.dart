// Opt-in: a fingerprint of every page of every EPUB under BEDEREADER_EPUB_DIR (read-only), laid out as on the tablet
// (Literata 24, Large paragraph spacing, Wide margins, the reader's own alignment and paragraphs) - one line per
// chapter to BEDEREADER_EPUB_OUT: "book|chapter|pages|hash of each page's line positions". Run it with the old and
// the new layout code and diff the two files: the chapters a layout change moved anything in (2026-10-11: checking
// the Foundation paragraph fix against the whole library). BEDEREADER_EPUB_RENDER (a file of "book|chapter|page"
// lines) instead saves those pages as PNGs next to BEDEREADER_EPUB_OUT. From komga_reader\ (PowerShell):
//   $env:BEDEREADER_EPUB_DIR = '\\nick-nas\nas-share\comics\E-Books'; $env:BEDEREADER_EPUB_OUT = 'C:\Temp\new.txt'
//   flutter test tool\epub_checks\epub_layout_fingerprint_check_test.dart
// ignore_for_file: invalid_use_of_visible_for_testing_member
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/painting.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:komga_reader/epub/chapter.dart';
import 'package:komga_reader/epub/hyphenator.dart';
import 'package:komga_reader/epub/layout.dart';
import 'package:komga_reader/epub/source.dart';

void main() {
  final dir = Platform.environment['BEDEREADER_EPUB_DIR'];
  final out = Platform.environment['BEDEREADER_EPUB_OUT'];
  final render = Platform.environment['BEDEREADER_EPUB_RENDER'];
  testWidgets('a fingerprint of every page of every EPUB', (tester) async {
    await tester.runAsync(() async {
      Future<ByteData> bytes(String f) async => ByteData.sublistView(File(f).readAsBytesSync());
      await (FontLoader('Literata')
            ..addFont(bytes('assets/fonts/Literata.ttf'))
            ..addFont(bytes('assets/fonts/Literata-Italic.ttf')))
          .load();
      final hy = await Hyphenators.load((p) async => File(p).readAsStringSync());
      const size = Size(800, 1230);
      const theme = EpubTheme(fontFamily: 'Literata', fontSize: 24, bookFormatting: false, pixelRatio: 1.5,
          paragraphGap: 1, margins: EdgeInsets.fromLTRB(64, 56, 64, 56));
      final outFile = File(out!);

      Future<void> save(EpubPage p, String file) async {
        final rec = ui.PictureRecorder();
        final canvas = Canvas(rec)..drawRect(Offset.zero & size, Paint()..color = theme.background);
        for (final piece in p.pieces) {
          piece.paint(canvas);
        }
        final img = await rec.endRecording().toImage(size.width.toInt(), size.height.toInt());
        final data = await img.toByteData(format: ui.ImageByteFormat.png);
        File(file).writeAsBytesSync(data!.buffer.asUint8List());
      }

      // which pages to draw: book -> chapter -> pages
      final wanted = <String, Map<String, Set<int>>>{};
      if (render != null) {
        for (final l in File(render).readAsLinesSync().where((l) => l.trim().isNotEmpty)) {
          final f = l.split('|');
          wanted.putIfAbsent(f[0], () => {}).putIfAbsent(f[1], () => {}).add(int.parse(f[2]));
        }
      }
      final books = render != null
          ? wanted.keys.toList()
          : (Directory(dir!).listSync(recursive: true).whereType<File>()
              .where((f) => f.path.toLowerCase().endsWith('.epub')).map((f) => f.path).toList()..sort());
      if (render == null) outFile.writeAsStringSync('');
      for (final (n, path) in books.indexed) {
        try {
          final s = FileEpubSource(File(path));
          final info = await s.info();
          final loader = ChapterLoader(s);
          final lines = StringBuffer();
          for (final ch in info.spine) {
            if (render != null && !(wanted[path]!.containsKey(ch))) continue;
            final c = await loader.load(ch);
            final p = Paginator(theme, size, hy.forLang(c.lang));
            final pages = p.run(c.blocks);
            if (render != null) {
              for (final i in wanted[path]![ch]!) {
                if (i < pages.length) await save(pages[i], '$out-$n-${ch.split('/').last}-$i.png');
              }
            } else {
              // FNV-1a over the values: the same in every run (Object.hashAll is seeded per process - two runs'
              // hashes never matched)
              String fnv(Iterable<int> values) {
                var h = 0x811c9dc5;
                for (final v in values) {
                  h = ((h ^ (v & 0xffffffff)) * 0x01000193) & 0xffffffff;
                }
                return h.toRadixString(36);
              }

              final hashes = [
                for (final pg in pages)
                  fnv([pg.start, for (final o in pg.textOrigins) o.dy.round(), ...pg.textIndents.map((x) => x.round())]),
              ];
              lines.writeln('$path|$ch|${pages.length}|${hashes.join(',')}');
            }
            p.dispose();
            c.dispose();
          }
          if (render == null) outFile.writeAsStringSync(lines.toString(), mode: FileMode.append, flush: true);
          stdout.writeln('${n + 1}/${books.length} ${path.split(RegExp(r'[\\/]')).last}');
        } catch (e) {
          if (render == null) outFile.writeAsStringSync('$path|ERROR|$e\n', mode: FileMode.append, flush: true);
          stdout.writeln('${n + 1}/${books.length} ERROR $path: $e');
        }
      }
    });
  }, skip: (dir == null && render == null) || out == null, timeout: const Timeout(Duration(hours: 2)));
}
