/// One chapter, ready to lay out: its blocks (pictures decoded), language and length. Stylesheets are fetched once per
/// book and shared by the chapters that link them.
library;

import 'dart:convert';
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
        img.image = (await codec.getNextFrame()).image;
        codec.dispose();
      } catch (_) {
        // a missing or broken picture: left out
      }
    }));
    return LoadedChapter(path, blocks, reader.lang, reader.length);
  }
}
