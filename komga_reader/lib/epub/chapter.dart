/// One chapter, ready to lay out: its blocks (pictures decoded), language and length. Stylesheets are fetched once per
/// book and shared by the chapters that link them.
library;

import 'dart:convert';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'css.dart';
import 'layout.dart';
import 'source.dart';
import 'xhtml.dart';

class LoadedChapter {
  LoadedChapter(this.path, this.blocks, this.lang, this.length, this.images, this.ids);
  final String path;
  final List<Block> blocks;
  final String? lang;
  final int length; // characters: the chapter's positions run 0..length
  final List<ImageBlock> images; // every picture decoded for it - used by a block or not
  final Map<String, int> ids; // element id -> chapter position (link targets)

  /// Frees the decoded pictures (the chapter is no longer kept) - all of them, from the reader's list: a picture no
  /// block kept (a float in an empty wrapper, a second float in a paragraph) was never freed (EPUB review E3).
  void dispose() {
    for (final img in images) {
      img.image?.dispose();
    }
  }
}

class ChapterLoader {
  ChapterLoader(this.source);
  final EpubSource source;
  final Map<String, Future<String>> _css = {};

  Future<String> _stylesheet(String path) => _css[path] ??= source
      .resource(path)
      .then((b) => utf8.decode(b, allowMalformed: true))
      .catchError((Object _) => ''); // a missing stylesheet: the chapter still reads

  Future<LoadedChapter> load(String path) async {
    final root = parseXhtml(utf8.decode(await source.resource(path), allowMalformed: true));
    final sheet = StyleSheet();
    final head = root.find('head');
    for (final e in head?.elements ?? const <XElement>[]) {
      if (e.name == 'link' && (e.attr('rel') ?? '').contains('stylesheet') && e.attr('href') != null) {
        sheet.add(await _stylesheet(resolvePath(path, e.attr('href')!).split('#').first));
      } else if (e.name == 'style') {
        sheet.add(e.children.whereType<XText>().map((t) => t.text).join());
      }
    }
    final reader = ChapterReader(sheet, (href) => resolvePath(path, href));
    final blocks = reader.read(root);
    // each picture file decoded and looked at once, however many times it's used (a scene-break ornament x40 was
    // decoded and scanned 40 times - EPUB review E14); every use gets its own handle to it
    final bySrc = <String, List<ImageBlock>>{};
    for (final img in reader.images) {
      bySrc.putIfAbsent(img.src.split('#').first, () => []).add(img);
    }
    await Future.wait(bySrc.entries.map((e) async {
      ui.Codec? codec;
      try {
        codec = await ui.instantiateImageCodec(await source.resource(e.key));
        final picture = (await codec.getNextFrame()).image;
        final ink = math.min(picture.width, picture.height) < 150 && await inkOnLight(picture);
        for (final img in e.value) {
          img
            ..image = picture.clone()
            ..inkOnLight = ink;
        }
        picture.dispose();
      } catch (_) {
        // a missing or broken picture: left out
      } finally {
        codec?.dispose(); // (also when a frame couldn't be had)
      }
    }));
    return LoadedChapter(path, blocks, reader.lang, reader.length, reader.images, reader.ids);
  }
}

/// Whether a small picture is ink on a light ground - black and white (or near it), its edge light: a chapter number,
/// a drop cap or an ornament printed on white (The Dispossessed's "5" in a white box glared on the dark page -
/// Windows, build 79). Drawn in the page's own colours ([Paginator] - user, 2026-10-06: "drop clashing backgrounds").
/// Colour pictures and dark-edged ones are left as they are.
Future<bool> inkOnLight(ui.Image picture) async {
  final data = await picture.toByteData(format: ui.ImageByteFormat.rawRgba);
  if (data == null) return false;
  final px = data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
  final w = picture.width, h = picture.height;
  var coloured = 0, all = 0, edge = 0, lightEdge = 0;
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      final i = (y * w + x) * 4;
      final r = px[i], g = px[i + 1], b = px[i + 2], a = px[i + 3];
      all++;
      if (math.max(r, math.max(g, b)) - math.min(r, math.min(g, b)) > 40) coloured++;
      if (x == 0 || y == 0 || x == w - 1 || y == h - 1) {
        edge++;
        if (a > 200 && 0.2126 * r + 0.7152 * g + 0.0722 * b > 200) lightEdge++;
      }
    }
  }
  return all > 0 && coloured / all < 0.05 && edge > 0 && lightEdge / edge > 0.8;
}
