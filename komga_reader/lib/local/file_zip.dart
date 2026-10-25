import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'storage.dart';

/// A zip read in place (a CBZ can be 100 MB: not loaded whole, unlike the EPUB reader's Zip) - on this device or an
/// SMB share ([LibraryFs]): its central directory once, then each entry's bytes as they're asked for, in one read
/// each. Stored or deflated entries; no zip64, no encryption.
class FileZip {
  FileZip._(this.fs, this.path, this._entries);

  final LibraryFs fs;
  final String path;
  // name -> (method, compressed size, local header offset, name length)
  final Map<String, (int, int, int, int)> _entries;

  /// The entries' names, in the zip's own order.
  Iterable<String> get names => _entries.keys;

  static Future<FileZip> open(LibraryFs fs, String path) async {
    {
      final length = await fs.length(path);
      // the end-of-central-directory record: in the last 64 KB + 22 bytes
      final tailLen = length < 65557 ? length : 65557;
      final tail = await fs.readRange(path, length - tailLen, tailLen);
      final td = ByteData.sublistView(tail);
      var eocd = -1;
      for (var i = tail.length - 22; i >= 0; i--) {
        if (td.getUint32(i, Endian.little) == 0x06054b50) {
          eocd = i;
          break;
        }
      }
      if (eocd < 0) throw const FormatException('Not a zip file');
      final count = td.getUint16(eocd + 10, Endian.little);
      final dirSize = td.getUint32(eocd + 12, Endian.little);
      final dirStart = td.getUint32(eocd + 16, Endian.little);
      // (the directory already in the tail read, usually: no second read)
      final tailStart = length - tail.length;
      final dir = dirStart >= tailStart && dirStart + dirSize <= length
          ? Uint8List.sublistView(tail, dirStart - tailStart, dirStart - tailStart + dirSize)
          : await fs.readRange(path, dirStart, dirSize);
      final d = ByteData.sublistView(dir);
      final entries = <String, (int, int, int, int)>{};
      var p = 0;
      for (var n = 0; n < count && p + 46 <= dir.length; n++) {
        if (d.getUint32(p, Endian.little) != 0x02014b50) throw const FormatException('Damaged zip directory');
        final method = d.getUint16(p + 10, Endian.little);
        final compressed = d.getUint32(p + 20, Endian.little);
        final nameLen = d.getUint16(p + 28, Endian.little);
        final extraLen = d.getUint16(p + 30, Endian.little);
        final commentLen = d.getUint16(p + 32, Endian.little);
        final local = d.getUint32(p + 42, Endian.little);
        final name = utf8.decode(dir.sublist(p + 46, p + 46 + nameLen), allowMalformed: true);
        entries[name] = (method, compressed, local, nameLen);
        p += 46 + nameLen + extraLen + commentLen;
      }
      return FileZip._(fs, path, entries);
    }
  }

  /// The entry named so, ignoring case ("ComicInfo.xml" is written every which way); null if there's none.
  String? find(String name) {
    final lower = name.toLowerCase();
    for (final n in _entries.keys) {
      if (n.toLowerCase() == lower) return n;
    }
    return null;
  }

  /// An entry's contents (null if there's none of that name).
  Future<Uint8List?> read(String name) => _read(name, null);

  /// The start of an entry - about [bytes] of it (a picture's size is in its first few KB).
  Future<Uint8List?> head(String name, int bytes) => _read(name, bytes);

  Future<Uint8List?> _read(String name, int? limit) async {
    final e = _entries[name];
    if (e == null) return null;
    final (method, size, local, nameLen) = e;
    final want = limit == null ? size : (limit < size ? limit : size);
    // the local header, its name and (usually) its extra field, and the data, in one read - a second only if the
    // extra field is longer than allowed for
    const slack = 256;
    final chunk = await fs.readRange(path, local, 30 + nameLen + slack + want);
    final h = ByteData.sublistView(chunk);
    if (chunk.length < 30 || h.getUint32(0, Endian.little) != 0x04034b50) {
      throw const FormatException('Damaged zip entry');
    }
    final start = 30 + h.getUint16(26, Endian.little) + h.getUint16(28, Endian.little);
    final data = start + want <= chunk.length
        ? Uint8List.sublistView(chunk, start, start + want)
        : await fs.readRange(path, local + start, want);
    return switch (method) {
      0 => data,
      8 when limit == null => Uint8List.fromList(ZLibDecoder(raw: true).convert(data)),
      8 => _inflatePart(data),
      _ => throw FormatException('Unsupported zip compression ($method)'),
    };
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
