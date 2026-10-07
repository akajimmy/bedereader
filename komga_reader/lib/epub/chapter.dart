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
  LoadedChapter(this.path, this.blocks, this.lang, this.length);
  final String path;
  final List<Block> blocks;
  final String? lang;
  final int length; // characters: the chapter's positions run 0..length

  /// Frees the decoded pictures (the chapter is no longer kept).
  void dispose() {
    for (final b in blocks) {
      if (b is ImageBlock) b.image?.dispose();
      if (b is TextBlock) b.floatImage?.image?.dispose();
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
    await Future.wait(reader.images.map((img) async {
      try {
        final codec = await ui.instantiateImageCodec(await source.resource(img.src.split('#').first));
        final picture = (await codec.getNextFrame()).image;
        img.image = picture;
        codec.dispose();
        if (math.min(picture.width, picture.height) < 150) img.inkOnLight = await inkOnLight(picture);
      } catch (_) {
        // a missing or broken picture: left out
      }
    }));
    return LoadedChapter(path, blocks, reader.lang, reader.length);
  }
}

/// Whether a small picture is ink on a light ground - black and white (or near it), its edge light: a chapter number,
/// a drop cap or an ornament printed on white (The Dispossessed's "5" in a white box glared on the dark page -
/// Windows, build 79). Drawn in the page's own colours ([Paginator] - user, 2026-10-06: "drop clashing backgrounds").
/// Colour pictures and dark-edged ones are left as they are.
Future<bool> inkOnLight(ui.Image picture) async {
  final data = await picture.toByteData(format: ui.ImageByteFormat.rawRgba);
  if (data == null) return false;
  final w = picture.width, h = picture.height;
  var coloured = 0, all = 0, edge = 0, lightEdge = 0;
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      final i = (y * w + x) * 4;
      final r = data.getUint8(i), g = data.getUint8(i + 1), b = data.getUint8(i + 2), a = data.getUint8(i + 3);
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
