import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'library_fs.dart';

/// A comic's archive, read in place: a zip ([FileZip] - a CBZ). Which kind is told by the file's first bytes, not its
/// name (a .cbr can be a zip renamed: one of the 2,219 on the NAS is). A RAR (a CBR) isn't read yet: it's damaged as
/// far as the app can tell ([UnreadableArchive]). The file is opened once, and held open until [close].
abstract class ComicArchive {
  static Future<ComicArchive> open(LibraryFs fs, String path) async {
    final file = await fs.open(path);
    try {
      final head = await file.readRange(0, 8);
      final rar = head.length >= 7 && head[0] == 0x52 && head[1] == 0x61 && head[2] == 0x72 && head[3] == 0x21 &&
          head[4] == 0x1a && head[5] == 0x07; // "Rar!\x1a\x07"
      if (rar) throw const UnreadableArchive('a RAR archive (CBR)');
      return await FileZip.open(file);
    } catch (_) {
      await file.close();
      rethrow;
    }
  }

  /// The media type Komga gives a book in this form.
  String get mediaType;

  /// The entries' names (the files in it - not its folders), in the archive's own order.
  Iterable<String> get names;

  /// The entry named so, ignoring case ("ComicInfo.xml" is written every which way); null if there's none.
  String? find(String name) {
    final lower = name.toLowerCase();
    for (final n in names) {
      if (n.toLowerCase() == lower) return n;
    }
    return null;
  }

  /// An entry's contents (null if there's none of that name).
  Future<Uint8List?> read(String name);

  /// The start of an entry - about [bytes] of it (a picture's size is in its first few KB).
  Future<Uint8List?> head(String name, int bytes);

  /// Done with it: its file let go.
  Future<void> close();
}

/// An archive of a kind this app doesn't read (yet): a book that can't be opened - damaged, as far as the scan and
/// the reader are concerned.
class UnreadableArchive extends FormatException {
  const UnreadableArchive(String what) : super('Not readable yet: $what');
}

/// A zip entry: how it's stored and where.
class _Entry {
  const _Entry(this.method, this.flags, this.compressed, this.size, this.local, this.nameLen);
  final int method, flags, compressed, size, local, nameLen;
  bool get encrypted => flags & 1 != 0;
}

/// A zip read in place (a CBZ can be 100 MB: not loaded whole, unlike the EPUB reader's Zip) - on this device or a
/// share ([LibraryFs]): its central directory once, then each entry's bytes as they're asked for, in one read each.
/// Stored or deflated entries; not zip64 or encrypted ones ([UnreadableArchive]).
class FileZip extends ComicArchive {
  FileZip._(this._file, this._entries);

  final LibraryFile _file;
  final Map<String, _Entry> _entries;

  @override
  String get mediaType => 'application/zip';

  @override
  Iterable<String> get names => _entries.keys;

  @override
  Future<void> close() => _file.close();

  static Future<FileZip> open(LibraryFile file) async {
    final length = await file.length();
    // the end-of-central-directory record: in the last 64 KB + 22 bytes - the one whose comment runs to the end of
    // the file (the same four bytes inside a comment aren't it)
    final tailLen = length < 65557 ? length : 65557;
    final tail = await file.readRange(length - tailLen, tailLen);
    final td = ByteData.sublistView(tail);
    var eocd = -1;
    for (var i = tail.length - 22; i >= 0; i--) {
      if (td.getUint32(i, Endian.little) == 0x06054b50 && i + 22 + td.getUint16(i + 20, Endian.little) == tail.length) {
        eocd = i;
        break;
      }
    }
    if (eocd < 0) throw const FormatException('Not a zip file');
    final count = td.getUint16(eocd + 10, Endian.little);
    final dirSize = td.getUint32(eocd + 12, Endian.little);
    final dirStart = td.getUint32(eocd + 16, Endian.little);
    if (count == 0xffff || dirStart == 0xffffffff || dirSize == 0xffffffff) {
      throw const UnreadableArchive('a zip64 archive');
    }
    if (dirStart + dirSize > length) throw const FormatException('Damaged zip directory');
    // (the directory already in the tail read, usually: no second read)
    final tailStart = length - tail.length;
    final dir = dirStart >= tailStart
        ? Uint8List.sublistView(tail, dirStart - tailStart, dirStart - tailStart + dirSize)
        : await file.readRange(dirStart, dirSize);
    final d = ByteData.sublistView(dir);
    final entries = <String, _Entry>{};
    var p = 0;
    for (var n = 0; n < count; n++) {
      if (p + 46 > dir.length || d.getUint32(p, Endian.little) != 0x02014b50) {
        throw const FormatException('Damaged zip directory');
      }
      final flags = d.getUint16(p + 8, Endian.little);
      final method = d.getUint16(p + 10, Endian.little);
      final compressed = d.getUint32(p + 20, Endian.little);
      final size = d.getUint32(p + 24, Endian.little);
      final nameLen = d.getUint16(p + 28, Endian.little);
      final extraLen = d.getUint16(p + 30, Endian.little);
      final commentLen = d.getUint16(p + 32, Endian.little);
      final local = d.getUint32(p + 42, Endian.little);
      if (p + 46 + nameLen > dir.length) throw const FormatException('Damaged zip directory');
      final raw = Uint8List.sublistView(dir, p + 46, p + 46 + nameLen);
      // flag 11: the name is UTF-8; without it, the old DOS code page (decoded as UTF-8, two names with accents could
      // come out the same - one page lost)
      final name = flags & 0x800 != 0 ? utf8.decode(raw, allowMalformed: true) : _cp437(raw);
      if (!name.endsWith('/')) entries[name] = _Entry(method, flags, compressed, size, local, nameLen); // (a folder)
      p += 46 + nameLen + extraLen + commentLen;
    }
    return FileZip._(file, entries);
  }

  @override
  Future<Uint8List?> read(String name) => _read(name, null);

  @override
  Future<Uint8List?> head(String name, int bytes) => _read(name, bytes);

  Future<Uint8List?> _read(String name, int? limit) async {
    final e = _entries[name];
    if (e == null) return null;
    if (e.encrypted) throw const UnreadableArchive('an encrypted page');
    if (e.compressed == 0xffffffff || e.local == 0xffffffff) throw const UnreadableArchive('a zip64 archive');
    final want = limit == null ? e.compressed : (limit < e.compressed ? limit : e.compressed);
    // the local header, its name and (usually) its extra field, and the data, in one read - a second only if the
    // extra field is longer than allowed for
    const slack = 256;
    final chunk = await _file.readRange(e.local, 30 + e.nameLen + slack + want);
    final h = ByteData.sublistView(chunk);
    if (chunk.length < 30 || h.getUint32(0, Endian.little) != 0x04034b50) {
      throw const FormatException('Damaged zip entry');
    }
    final start = 30 + h.getUint16(26, Endian.little) + h.getUint16(28, Endian.little);
    final data = start + want <= chunk.length
        ? Uint8List.sublistView(chunk, start, start + want)
        : await _file.readRange(e.local + start, want);
    if (data.length < want) throw const FormatException('Zip entry cut short');
    final out = switch (e.method) {
      0 => data,
      8 when limit == null => Uint8List.fromList(ZLibDecoder(raw: true).convert(data)),
      8 => _inflatePart(data),
      _ => throw UnreadableArchive('zip compression ${e.method}'),
    };
    if (limit == null && out.length != e.size) throw const FormatException('Zip entry cut short');
    return out;
  }

  /// As much of a deflated stream as [data] (its start) holds.
  static Uint8List _inflatePart(Uint8List data) {
    final f = RawZLibFilter.inflateFilter(raw: true)..process(data, 0, data.length);
    final out = BytesBuilder(copy: false);
    try {
      for (List<int>? chunk; (chunk = f.processed(flush: false)) != null;) {
        out.add(chunk!);
      }
    } catch (_) {
      // the stream cut short: what came out so far
    }
    return out.takeBytes();
  }
}

/// A picture's width and height from the start of its file (JPEG, PNG, GIF, WebP); null if it can't tell.
(int, int)? imageSizeOf(Uint8List b) {
  final d = ByteData.sublistView(b);
  if (b.length >= 24 && b[0] == 0x89 && b[1] == 0x50 && b[2] == 0x4e && b[3] == 0x47) {
    return (d.getUint32(16), d.getUint32(20)); // PNG: IHDR
  }
  if (b.length >= 10 && b[0] == 0x47 && b[1] == 0x49 && b[2] == 0x46) {
    return (d.getUint16(6, Endian.little), d.getUint16(8, Endian.little)); // GIF
  }
  if (b.length >= 30 && b[0] == 0x52 && b[1] == 0x49 && b[2] == 0x46 && b[3] == 0x46 && b[8] == 0x57 && b[9] == 0x45) {
    final kind = String.fromCharCodes(b.sublist(12, 16)); // WebP
    if (kind == 'VP8 ') return (d.getUint16(26, Endian.little) & 0x3fff, d.getUint16(28, Endian.little) & 0x3fff);
    if (kind == 'VP8L') {
      final v = d.getUint32(21, Endian.little);
      return ((v & 0x3fff) + 1, ((v >> 14) & 0x3fff) + 1);
    }
    if (kind == 'VP8X') {
      int u24(int at) => b[at] | (b[at + 1] << 8) | (b[at + 2] << 16);
      return (u24(24) + 1, u24(27) + 1);
    }
    return null;
  }
  if (b.length >= 4 && b[0] == 0xff && b[1] == 0xd8) {
    // JPEG: the frame header (SOF0-15, not DHT/JPG/DAC)
    var p = 2;
    while (p + 9 < b.length) {
      if (b[p] != 0xff) {
        p++;
        continue;
      }
      final m = b[p + 1];
      if (m == 0xff) {
        p++;
        continue;
      }
      if (m == 0xd8 || m == 0x01 || (m >= 0xd0 && m <= 0xd7)) {
        p += 2;
        continue;
      }
      if (m >= 0xc0 && m <= 0xcf && m != 0xc4 && m != 0xc8 && m != 0xcc) {
        return (d.getUint16(p + 7), d.getUint16(p + 5));
      }
      p += 2 + d.getUint16(p + 2);
    }
  }
  return null;
}

/// A name in the old DOS code page (437) - a zip's names when its UTF-8 flag isn't set.
String _cp437(List<int> bytes) =>
    String.fromCharCodes([for (final b in bytes) b < 0x80 ? b : _cp437High.codeUnitAt(b - 0x80)]);

const _cp437High = 'ÇüéâäàåçêëèïîìÄÅÉæÆôöòûùÿÖÜ¢£¥₧ƒáíóúñÑªº¿⌐¬½¼¡«»░▒▓│┤╡╢╖╕╣║╗╝╜╛┐└┴┬├─┼╞╟╚╔╩╦╠═╬╧╨╤╥╙╘╒╓╫╪┘┌█▄▌▐▀αßΓπΣσµτΦΘΩδ∞φε∩≡±≥≤⌠⌡÷≈°∙·√ⁿ²■ ';
