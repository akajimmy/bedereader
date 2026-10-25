import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// A zip on disk read in place (a CBZ can be 100 MB: not loaded whole, unlike the EPUB reader's Zip): its central
/// directory once, then each entry's bytes as they're asked for. Stored or deflated entries; no zip64, no encryption.
class FileZip {
  FileZip._(this.file, this._entries);

  final File file;
  final Map<String, (int, int, int)> _entries; // name -> (method, compressed size, local header offset)

  /// The entries' names, in the zip's own order.
  Iterable<String> get names => _entries.keys;

  static Future<FileZip> open(File file) async {
    final raf = await file.open();
    try {
      final length = await raf.length();
      // the end-of-central-directory record: in the last 64 KB + 22 bytes
      final tailLen = length < 65557 ? length : 65557;
      await raf.setPosition(length - tailLen);
      final tail = await raf.read(tailLen);
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
      await raf.setPosition(dirStart);
      final dir = await raf.read(dirSize);
      final d = ByteData.sublistView(dir);
      final entries = <String, (int, int, int)>{};
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
        entries[name] = (method, compressed, local);
        p += 46 + nameLen + extraLen + commentLen;
      }
      return FileZip._(file, entries);
    } finally {
      await raf.close();
    }
  }

  /// An entry's contents (null if there's none of that name).
  Future<Uint8List?> read(String name) async {
    final e = _entries[name];
    if (e == null) return null;
    final (method, size, local) = e;
    final raf = await file.open();
    try {
      await raf.setPosition(local);
      final header = await raf.read(30);
      final h = ByteData.sublistView(header);
      if (header.length < 30 || h.getUint32(0, Endian.little) != 0x04034b50) {
        throw const FormatException('Damaged zip entry');
      }
      await raf.setPosition(local + 30 + h.getUint16(26, Endian.little) + h.getUint16(28, Endian.little));
      final data = await raf.read(size);
      return switch (method) {
        0 => data,
        8 => Uint8List.fromList(ZLibDecoder(raw: true).convert(data)),
        _ => throw FormatException('Unsupported zip compression ($method)'),
      };
    } finally {
      await raf.close();
    }
  }
}
