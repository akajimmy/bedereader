// EPUB books held in memory for the tests (moved out of the EPUB reader's test, 2026-10-07: other tests imported them
// from there).
import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:komga_reader/epub/source.dart';

class MemorySource implements EpubSource {
  MemorySource(this.files, this.infoValue, {this.binary = const {}});
  final Map<String, String> files;
  final Map<String, Uint8List> binary; // pictures
  final EpubInfo infoValue;
  @override
  Future<EpubInfo> info() async => infoValue;
  @override
  Future<Uint8List> resource(String path) async {
    final pic = binary[path];
    if (pic != null) return pic;
    final f = files[path];
    if (f == null) throw StateError('no $path');
    return Uint8List.fromList(utf8.encode(f));
  }
}

/// A [MemorySource] whose files take a moment to read (a chapter coming back takes a while, as on a device).
class SlowSource extends MemorySource {
  SlowSource(super.files, super.infoValue);
  bool slow = false; // on once the book is open (its first loads run before the test's clock does)
  @override
  Future<Uint8List> resource(String path) async {
    if (slow) await Future<void>.delayed(const Duration(milliseconds: 30));
    return super.resource(path);
  }
}

/// A 1 x 1 PNG.
final onePixelPng = Uint8List.fromList(base64Decode(
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg=='));

/// A [MemorySource] where one file ([hangs]) never comes: the book is never wholly counted.
class HangingSource extends MemorySource {
  HangingSource(super.files, super.infoValue, {required this.hangs});
  final String hangs;
  @override
  Future<Uint8List> resource(String path) => path == hangs ? Completer<Uint8List>().future : super.resource(path);
}

String para(String word, int n) => '<p>${List.filled(n, word).join(' ')}</p>';

MemorySource twoChapters() => MemorySource({
      'c1.xhtml': '<html><body><h1>One</h1>${List.filled(12, para('alpha', 40)).join()}'
          '<p>Here<a href="notes.xhtml#n1">*</a> is a note.</p></body></html>',
      'c2.xhtml': '<html><body><h1 id="two">Two</h1>${List.filled(12, para('beta', 40)).join()}</body></html>',
      'notes.xhtml': '<html><body><p id="n1"><a href="c1.xhtml">*</a>The note itself.</p></body></html>',
    }, const EpubInfo(spine: ['c1.xhtml', 'c2.xhtml'], toc: [
      TocEntry('One', 'c1.xhtml', 0),
      TocEntry('Two', 'c2.xhtml#two', 0),
    ], title: 'Book'));
