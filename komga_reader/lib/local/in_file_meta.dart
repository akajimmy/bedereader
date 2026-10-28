// A book's edits written into the book itself (Settings > Libraries > Metadata edits: In the book files - user,
// 2026-10-27; reports\10-27-metadata-plan.md): a CBZ's ComicInfo.xml, an EPUB's package file. Only the fields asked
// for change; everything else in the text stays as it was.

import 'local_meta.dart';

/// ComicInfo's credit fields, by Komga's role.
const comicInfoRoles = {
  'writer': 'Writer', 'penciller': 'Penciller', 'inker': 'Inker', 'colorist': 'Colorist', 'letterer': 'Letterer',
  'cover': 'CoverArtist', 'editor': 'Editor',
};

/// [xml] (a CBZ's ComicInfo.xml; null: it has none) with [e]'s title, series, number, date (Year, Month, Day), summary,
/// credits (a field each role, names separated by commas) and tags.
String comicInfoWith(String? xml, BookEdits e) {
  var x = xml ??
      '<?xml version="1.0" encoding="utf-8"?>\n'
          '<ComicInfo xmlns:xsd="http://www.w3.org/2001/XMLSchema" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">\n'
          '</ComicInfo>\n';
  if (e.title != null) x = _setElement(x, 'Title', e.title, close: 'ComicInfo');
  if (e.series != null) x = _setElement(x, 'Series', e.series, close: 'ComicInfo');
  if (e.number != null) x = _setElement(x, 'Number', e.number!.isEmpty ? null : e.number, close: 'ComicInfo');
  if (e.dateSet) {
    final d = e.releaseDate == null ? null : DateTime.tryParse(e.releaseDate!);
    x = _setElement(x, 'Year', d?.year.toString(), close: 'ComicInfo');
    x = _setElement(x, 'Month', d?.month.toString(), close: 'ComicInfo');
    x = _setElement(x, 'Day', d?.day.toString(), close: 'ComicInfo');
  }
  if (e.summary != null) x = _setElement(x, 'Summary', e.summary!.isEmpty ? null : e.summary, close: 'ComicInfo');
  if (e.authors != null) {
    for (final MapEntry(key: role, value: tag) in comicInfoRoles.entries) {
      final names = [for (final (n, r) in e.authors!) if (r == role) n];
      x = _setElement(x, tag, names.isEmpty ? null : names.join(', '), close: 'ComicInfo');
    }
  }
  if (e.tags != null) x = _setElement(x, 'Tags', e.tags!.isEmpty ? null : e.tags!.join(', '), close: 'ComicInfo');
  return x;
}

/// [opf] (an EPUB's package file) with [e]'s title (dc:title), date (dc:date), series and number (calibre's),
/// summary (dc:description), credits (dc:creator for writers, dc:contributor for the others) and tags (dc:subject).
String opfWith(String opf, BookEdits e) {
  var x = opf;
  if (e.title != null) {
    final m = RegExp(r'<dc:title\b([^>]*)>.*?</dc:title>', dotAll: true).firstMatch(x);
    final el = '<dc:title${m?[1] ?? ''}>${xmlEscape(e.title!)}</dc:title>';
    x = m == null ? _beforeClose(x, el) : x.replaceRange(m.start, m.end, el);
  }
  if (e.dateSet) {
    final m = RegExp(r'\s*<dc:date\b[^>]*>.*?</dc:date>', dotAll: true).firstMatch(x);
    final d = e.releaseDate;
    if (d == null) {
      if (m != null) x = x.replaceRange(m.start, m.end, '');
    } else {
      final el = '<dc:date>${xmlEscape(d)}</dc:date>';
      x = m == null ? _beforeClose(x, el) : x.replaceRange(m.start, m.end, '\n    $el');
    }
  }
  if (e.number != null) {
    final m = RegExp(r'\s*<meta\b[^>]*name="calibre:series_index"[^>]*>(?:\s*</meta>)?').firstMatch(x);
    if (m != null) x = x.replaceRange(m.start, m.end, '');
    if (e.number!.isNotEmpty) {
      x = _beforeClose(x, '<meta name="calibre:series_index" content="${xmlEscape(e.number!)}"/>');
    }
  }
  if (e.series != null) {
    final m = RegExp(r'\s*<meta\b[^>]*name="calibre:series"[^>]*>(?:\s*</meta>)?').firstMatch(x);
    if (m != null) x = x.replaceRange(m.start, m.end, '');
    x = _beforeClose(x, '<meta name="calibre:series" content="${xmlEscape(e.series!)}"/>');
  }
  if (e.summary != null) {
    x = _without(x, 'dc:description');
    if (e.summary!.isNotEmpty) x = _beforeClose(x, '<dc:description>${xmlEscape(e.summary!)}</dc:description>');
  }
  if (e.authors != null) {
    x = _without(_without(x, 'dc:creator'), 'dc:contributor');
    for (final (n, r) in e.authors!) {
      final tag = r == 'writer' ? 'dc:creator' : 'dc:contributor';
      x = _beforeClose(x, '<$tag>${xmlEscape(n)}</$tag>');
    }
  }
  if (e.tags != null) {
    x = _without(x, 'dc:subject');
    for (final t in e.tags!) {
      x = _beforeClose(x, '<dc:subject>${xmlEscape(t)}</dc:subject>');
    }
  }
  return x;
}

/// [x] without its <[tag]> elements.
String _without(String x, String tag) => x.replaceAll(RegExp('\\s*<$tag\\b[^>]*?(?:/>|>.*?</$tag>)', dotAll: true), '');

/// [x] with <[tag]>[value]</[tag]> in place of the one there (null: taken out), or added before </[close]>.
String _setElement(String x, String tag, String? value, {required String close}) {
  final m = RegExp('\\s*<$tag\\b[^>]*?(?:/>|>.*?</$tag>)', dotAll: true).firstMatch(x);
  if (value == null) return m == null ? x : x.replaceRange(m.start, m.end, '');
  final el = '<$tag>${xmlEscape(value)}</$tag>';
  if (m != null) return x.replaceRange(m.start, m.end, '\n  $el');
  final end = x.lastIndexOf('</$close>');
  if (end < 0) throw FormatException('No </$close> in the file');
  return '${x.substring(0, end).trimRight()}\n  $el\n${x.substring(end)}';
}

/// [x] with [el] added at the end of its metadata.
String _beforeClose(String x, String el) {
  final m = RegExp(r'</(?:\w+:)?metadata>').firstMatch(x);
  if (m == null) throw const FormatException('No metadata in the package file');
  return '${x.substring(0, m.start).trimRight()}\n    $el\n  ${x.substring(m.start)}';
}

String xmlEscape(String s) =>
    s.replaceAll('&', '&amp;').replaceAll('<', '&lt;').replaceAll('>', '&gt;').replaceAll('"', '&quot;');
