import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:komga_reader/screen.dart';

/// Save page's file names and types (lib/screen.dart; user, 2026-10-02).
void main() {
  test("a picture's type from its first bytes: PNG, WebP, GIF; anything else is taken as JPEG", () {
    Uint8List b(List<int> x) => Uint8List.fromList([...x, 0, 0, 0, 0, 0, 0, 0, 0]);
    expect(pictureType(b([0x89, 0x50, 0x4E, 0x47])), ('png', 'image/png'));
    expect(pictureType(b([0x52, 0x49, 0x46, 0x46, 1, 2, 3, 4, 0x57, 0x45, 0x42, 0x50])), ('webp', 'image/webp'));
    expect(pictureType(b([0x52, 0x49, 0x46, 0x46, 1, 2, 3, 4, 0x57, 0x41, 0x56, 0x45])), ('jpg', 'image/jpeg'),
        reason: 'RIFF, but not WebP');
    expect(pictureType(b([0x47, 0x49, 0x46, 0x38])), ('gif', 'image/gif'));
    expect(pictureType(b([0xFF, 0xD8, 0xFF])), ('jpg', 'image/jpeg'));
    expect(pictureType(Uint8List(0)), ('jpg', 'image/jpeg'), reason: 'nothing to go on');
  });

  test('file names: the characters Windows refuses become _, no trailing dots or spaces; the rest is kept', () {
    expect(safeFileName('Fables TPB #Vol. 13 - page 186'), 'Fables TPB #Vol. 13 - page 186');
    expect(safeFileName('What If? / Who: "Me" <1|2>*'), 'What If_ _ Who_ _Me_ _1_2__');
    expect(safeFileName('Batman...  '), 'Batman');
    expect(safeFileName('tab\there'), 'tab_here');
  });
}
