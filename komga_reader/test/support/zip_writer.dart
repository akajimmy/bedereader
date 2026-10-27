import 'dart:convert';
import 'dart:io' show ZLibEncoder;
import 'dart:typed_data';

/// A zip of [files] (name -> bytes, or a String for text) - for tests that need a CBZ or an EPUB on disk. Stored
/// uncompressed, or [deflate]d as most CBZs are.
Uint8List zipOf(Map<String, Object> files, {bool deflate = false}) {
  final out = BytesBuilder();
  final dir = BytesBuilder();
  var count = 0;
  for (final MapEntry(key: name, value: v) in files.entries) {
    final data = v is String ? utf8.encode(v) : v as List<int>;
    final stored = deflate ? ZLibEncoder(raw: true).convert(data) : data;
    final method = deflate ? 8 : 0;
    final nameBytes = utf8.encode(name);
    final crc = _crc32(data);
    final offset = out.length;
    out.add(_le32(0x04034b50));
    out.add(_le16(20));
    out.add(_le16(0)); // flags
    out.add(_le16(method));
    out.add(_le32(0)); // time, date
    out.add(_le32(crc));
    out.add(_le32(stored.length));
    out.add(_le32(data.length));
    out.add(_le16(nameBytes.length));
    out.add(_le16(0));
    out.add(nameBytes);
    out.add(stored);
    dir.add(_le32(0x02014b50));
    dir.add(_le16(20));
    dir.add(_le16(20));
    dir.add(_le16(0));
    dir.add(_le16(method));
    dir.add(_le32(0));
    dir.add(_le32(crc));
    dir.add(_le32(stored.length));
    dir.add(_le32(data.length));
    dir.add(_le16(nameBytes.length));
    dir.add(_le16(0));
    dir.add(_le16(0));
    dir.add(_le16(0));
    dir.add(_le16(0));
    dir.add(_le32(0));
    dir.add(_le32(offset));
    dir.add(nameBytes);
    count++;
  }
  final dirStart = out.length, dirBytes = dir.takeBytes();
  out.add(dirBytes);
  out.add(_le32(0x06054b50));
  out.add(_le16(0));
  out.add(_le16(0));
  out.add(_le16(count));
  out.add(_le16(count));
  out.add(_le32(dirBytes.length));
  out.add(_le32(dirStart));
  out.add(_le16(0));
  return out.takeBytes();
}

/// A PNG's start, as far as its size: the signature and the IHDR chunk for [width] x [height] (enough for
/// imageSizeOf; not a picture that decodes).
Uint8List pngHead(int width, int height) => Uint8List.fromList([
      0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 0, 0, 0, 13, 0x49, 0x48, 0x44, 0x52,
      ..._be32(width), ..._be32(height), 8, 6, 0, 0, 0,
    ]);

List<int> _le16(int v) => [v & 0xff, (v >> 8) & 0xff];
List<int> _le32(int v) => [v & 0xff, (v >> 8) & 0xff, (v >> 16) & 0xff, (v >> 24) & 0xff];
List<int> _be32(int v) => [(v >> 24) & 0xff, (v >> 16) & 0xff, (v >> 8) & 0xff, v & 0xff];

int _crc32(List<int> data) {
  var c = 0xffffffff;
  for (final b in data) {
    c ^= b;
    for (var k = 0; k < 8; k++) {
      c = (c & 1) != 0 ? (c >> 1) ^ 0xedb88320 : c >> 1;
    }
  }
  return c ^ 0xffffffff;
}
