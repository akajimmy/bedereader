import 'dart:convert';
import 'dart:typed_data';

/// A RAR4 archive of [files] (name -> bytes, or a String for text), stored uncompressed - for tests that need a CBR
/// on disk (nothing in Dart writes RAR; the compressed ones are fixtures, test/fixtures/rar).
Uint8List rarOf(Map<String, Object> files) {
  final out = BytesBuilder()..add([0x52, 0x61, 0x72, 0x21, 0x1a, 0x07, 0x00]);
  void block(int type, int flags, List<int> rest, [List<int> data = const []]) {
    final body = BytesBuilder()
      ..addByte(type)
      ..add(_le16(flags))
      ..add(_le16(7 + rest.length))
      ..add(rest);
    final b = body.takeBytes();
    out
      ..add(_le16(_crc32(b) & 0xffff))
      ..add(b)
      ..add(data);
  }

  block(0x73, 0, [0, 0, 0, 0, 0, 0]); // the archive header
  for (final MapEntry(key: name, value: v) in files.entries) {
    final data = v is String ? utf8.encode(v) : v as List<int>;
    final nameBytes = utf8.encode(name);
    block(0x74, 0x8000, [ // a file, with its data after (0x8000); names in plain ASCII (no unicode name)
      ..._le32(data.length), ..._le32(data.length), 2, ..._le32(_crc32(data)), ..._le32(0x5a210000), // DOS date 2025
      29, 0x30, ..._le16(nameBytes.length), ..._le32(0x20), ...nameBytes,
    ], data);
  }
  block(0x7b, 0x4000, const []); // the end
  return out.takeBytes();
}

List<int> _le16(int v) => [v & 0xff, (v >> 8) & 0xff];
List<int> _le32(int v) => [v & 0xff, (v >> 8) & 0xff, (v >> 16) & 0xff, (v >> 24) & 0xff];

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
