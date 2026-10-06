/// An EPUB book as data: its chapters in reading order, its table of contents, its files. From Komga (online) or from
/// the downloaded .epub (offline). Paths are from the book's root ("OEBPS/Chapter1.xhtml") either way.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../api.dart';
import 'xhtml.dart';

class TocEntry {
  const TocEntry(this.title, this.href, this.depth);
  final String title;
  final String href; // a path in the book, #fragment kept
  final int depth; // 0 = top level

  String get path => href.split('#').first;
}

class EpubInfo {
  const EpubInfo({required this.spine, required this.toc, this.title});
  final List<String> spine; // the chapters (files) in reading order
  final List<TocEntry> toc;
  final String? title;
}

abstract class EpubSource {
  Future<EpubInfo> info();
  Future<Uint8List> resource(String path);
}

/// [href] (as written in the file at [base]) as a path from the book's root: ../, ./ and %20 resolved, #fragment
/// kept. An empty href (or only a #fragment) is [base] itself.
String resolvePath(String base, String href) {
  final hash = href.indexOf('#');
  final h = hash < 0 ? href : href.substring(0, hash);
  final frag = hash < 0 ? '' : href.substring(hash);
  if (h.isEmpty) return '$base$frag';
  final dir = h.startsWith('/') ? '' : (base.contains('/') ? base.substring(0, base.lastIndexOf('/') + 1) : '');
  final parts = <String>[];
  for (final p in (dir + h).split('/')) {
    if (p == '..') {
      if (parts.isNotEmpty) parts.removeLast();
    } else if (p != '.' && p.isNotEmpty) {
      parts.add(p);
    }
  }
  return '${Uri.decodeFull(parts.join('/'))}$frag';
}

// ---- Komga

/// The book through Komga's Readium manifest and resource API.
class KomgaEpubSource implements EpubSource {
  KomgaEpubSource(this.api, this.bookId);
  final Komga api;
  final String bookId;

  /// Komga writes hrefs as full URLs (`.../api/v1/books/ID/resource/OEBPS/x.xhtml`): the part after /resource/.
  static String _path(String href) {
    final i = href.indexOf('/resource/');
    return Uri.decodeFull(i < 0 ? href : href.substring(i + '/resource/'.length));
  }

  @override
  Future<EpubInfo> info() async {
    final m = await api.epubManifest(bookId);
    if (m == null) throw StateError('Komga has no contents for this book');
    final spine = [
      for (final l in (m['readingOrder'] as List? ?? const [])) _path((l as Map)['href'] as String),
    ];
    final toc = <TocEntry>[];
    void walk(List? items, int depth) {
      for (final t in items ?? const []) {
        final e = t as Map;
        final href = e['href'] as String?;
        if (href != null) toc.add(TocEntry(((e['title'] as String?) ?? '').trim(), _path(href), depth));
        walk(e['children'] as List?, depth + 1);
      }
    }
    walk(m['toc'] as List?, 0);
    return EpubInfo(spine: spine, toc: toc, title: (m['metadata'] as Map?)?['title'] as String?);
  }

  @override
  Future<Uint8List> resource(String path) => api.epubResource(bookId, path);
}

// ---- a downloaded file

/// The book from its .epub file (a zip): the container, the package (OPF), the EPUB 3 contents page or EPUB 2 NCX.
class FileEpubSource implements EpubSource {
  FileEpubSource(this.file);
  final File file;
  Zip? _zip;

  Future<Zip> get _open async => _zip ??= Zip(await file.readAsBytes());

  @override
  Future<Uint8List> resource(String path) async {
    final z = await _open;
    final b = z.read(path);
    if (b == null) throw FileSystemException('Not in the book', path);
    return b;
  }

  String _text(Zip z, String path) {
    final b = z.read(path);
    if (b == null) throw FileSystemException('Not in the book', path);
    return utf8.decode(b, allowMalformed: true);
  }

  @override
  Future<EpubInfo> info() async {
    final z = await _open;
    final container = parseXhtml(_text(z, 'META-INF/container.xml'));
    final opfPath = container.find('rootfile')?.attr('full-path');
    if (opfPath == null) throw const FormatException('No package in the book');
    final opf = parseXhtml(_text(z, opfPath));
    final items = <String, XElement>{
      for (final i in opf.find('manifest')?.elements.where((e) => e.name == 'item') ?? const <XElement>[])
        if (i.id != null) i.id!: i,
    };
    String pathOf(XElement item) => resolvePath(opfPath, item.attr('href') ?? '');
    final spineEl = opf.find('spine');
    final spine = [
      for (final r in spineEl?.elements.where((e) => e.name == 'itemref') ?? const <XElement>[])
        if (items[r.attr('idref')] != null && r.attr('linear') != 'no') pathOf(items[r.attr('idref')]!),
    ];
    final title = _all(opf, 'title').map(_textIn).firstOrNull?.trim();

    // EPUB 3: the item with properties="nav"; else EPUB 2: the NCX the spine names (or any NCX item)
    final toc = <TocEntry>[];
    final nav = items.values.where((i) => (i.attr('properties') ?? '').split(' ').contains('nav')).firstOrNull;
    if (nav != null) {
      final path = pathOf(nav);
      final doc = parseXhtml(_text(z, path));
      final navs = _all(doc, 'nav');
      final tocNav = navs.where((n) => n.attr('type') == 'toc').firstOrNull ?? navs.firstOrNull;
      void walk(XElement ol, int depth) {
        for (final li in ol.elements.where((e) => e.name == 'li')) {
          final a = li.elements.where((e) => e.name == 'a' || e.name == 'span').firstOrNull;
          final href = a?.attr('href');
          if (a != null && href != null) toc.add(TocEntry(_textIn(a).trim(), resolvePath(path, href), depth));
          final sub = li.elements.where((e) => e.name == 'ol').firstOrNull;
          if (sub != null) walk(sub, depth + 1);
        }
      }
      final ol = tocNav?.find('ol');
      if (ol != null) walk(ol, 0);
    }
    if (toc.isEmpty) {
      final ncx = items[spineEl?.attr('toc')] ??
          items.values.where((i) => i.attr('media-type') == 'application/x-dtbncx+xml').firstOrNull;
      if (ncx != null) {
        final path = pathOf(ncx);
        final doc = parseXhtml(_text(z, path));
        void walk(XElement parent, int depth) {
          for (final p in parent.elements.where((e) => e.name == 'navpoint')) {
            final label = p.find('navlabel');
            final src = p.elements.where((e) => e.name == 'content').firstOrNull?.attr('src');
            if (src != null) toc.add(TocEntry(label == null ? '' : _textIn(label).trim(), resolvePath(path, src), depth));
            walk(p, depth + 1);
          }
        }
        final map = doc.find('navmap');
        if (map != null) walk(map, 0);
      }
    }
    return EpubInfo(spine: spine, toc: toc, title: title);
  }

  static Iterable<XElement> _all(XElement e, String name) sync* {
    for (final c in e.elements) {
      if (c.name == name) yield c;
      yield* _all(c, name);
    }
  }

  static String _textIn(XElement e) =>
      e.children.map((n) => n is XText ? n.text : _textIn(n as XElement)).join().replaceAll(RegExp(r'\s+'), ' ');
}

/// Reads files out of a zip held in memory (EPUBs are a few MB): the central directory, then each entry stored or
/// deflated. Enough for EPUBs - no encryption, no zip64.
class Zip {
  Zip(this.bytes) {
    final d = ByteData.sublistView(bytes);
    // the end-of-central-directory record: in the last 64 KB + 22 bytes
    var eocd = -1;
    for (var i = bytes.length - 22; i >= 0 && i >= bytes.length - 65557; i--) {
      if (d.getUint32(i, Endian.little) == 0x06054b50) {
        eocd = i;
        break;
      }
    }
    if (eocd < 0) throw const FormatException('Not a zip file');
    final count = d.getUint16(eocd + 10, Endian.little);
    var p = d.getUint32(eocd + 16, Endian.little);
    for (var n = 0; n < count; n++) {
      if (d.getUint32(p, Endian.little) != 0x02014b50) throw const FormatException('Damaged zip directory');
      final method = d.getUint16(p + 10, Endian.little);
      final compressed = d.getUint32(p + 20, Endian.little);
      final nameLen = d.getUint16(p + 28, Endian.little);
      final extraLen = d.getUint16(p + 30, Endian.little);
      final commentLen = d.getUint16(p + 32, Endian.little);
      final local = d.getUint32(p + 42, Endian.little);
      final name = utf8.decode(bytes.sublist(p + 46, p + 46 + nameLen), allowMalformed: true);
      _entries[name] = (method, compressed, local);
      p += 46 + nameLen + extraLen + commentLen;
    }
  }

  final Uint8List bytes;
  final Map<String, (int, int, int)> _entries = {}; // name -> (method, compressed size, local header offset)

  Iterable<String> get names => _entries.keys;

  /// A file's contents, or null if the zip doesn't have it. Paths are matched exactly, then ignoring case.
  Uint8List? read(String name) {
    var e = _entries[name];
    if (e == null) {
      final lower = name.toLowerCase();
      for (final k in _entries.keys) {
        if (k.toLowerCase() == lower) {
          e = _entries[k];
          break;
        }
      }
    }
    if (e == null) return null;
    final (method, size, local) = e;
    final d = ByteData.sublistView(bytes);
    final start = local + 30 + d.getUint16(local + 26, Endian.little) + d.getUint16(local + 28, Endian.little);
    final data = Uint8List.sublistView(bytes, start, start + size);
    return switch (method) {
      0 => Uint8List.fromList(data),
      8 => Uint8List.fromList(ZLibDecoder(raw: true).convert(data)),
      _ => throw FormatException('Unsupported zip compression ($method)'),
    };
  }
}
