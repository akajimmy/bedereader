// The page strip's pictures held in memory (code review 2026-10-05, #40): offline they are the pages themselves, and
// 64 of them held 130-320 MB. Capped by size too (user: ~128 MB); the least recently used go first.
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:komga_reader/screens/reader.dart';

void main() {
  const mb = 1024 * 1024;

  test('whole pages (offline, 4 MB each): no more than 128 MB held, the most recently used kept', () {
    final held = <int, Uint8List?>{for (var i = 0; i < 64; i++) i: Uint8List(4 * mb)}; // 256 MB, most recent last
    trimPictures(held, count: 64, bytes: 128 * mb);
    expect(held.length, 32, reason: '32 x 4 MB = 128 MB');
    expect(held.keys.first, 32, reason: 'the oldest went');
    expect(held.keys.last, 63);
  });

  test("Komga's small previews (online, ~20 KB): the count cap as before, the size cap never reached", () {
    final held = <int, Uint8List?>{for (var i = 0; i < 80; i++) i: Uint8List(20 * 1024)};
    trimPictures(held, count: 64, bytes: 128 * mb);
    expect(held.length, 64);
  });

  test('one picture bigger than the cap on its own stays (it is the one wanted now)', () {
    final held = <int, Uint8List?>{0: Uint8List(2 * mb), 1: Uint8List(200 * mb)};
    trimPictures(held, count: 64, bytes: 128 * mb);
    expect(held.keys, [1]);
  });
}
