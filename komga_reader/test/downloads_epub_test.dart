// EPUBs downloaded and read offline (plan v2: offline in v1): the book's file and Komga's positions are kept; offline
// the reader reads the file and keeps its place on the device, sent to Komga later as the read progress.
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:komga_reader/epub/source.dart';
import 'package:komga_reader/offline/downloads.dart';
import 'package:komga_reader/offline/offline_komga.dart';
import 'package:komga_reader/screens/epub_reader.dart';
import 'package:komga_reader/screens/open_book.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'downloads_test.dart' show settle;
import 'epub_source_test.dart' show epub3, zip;
import 'support/helpers.dart';
import 'support/library_server.dart';
import 'support/no_network.dart';

/// The library server, with B1 an EPUB: its file, its positions (Komga's "pages" for it).
class EpubLibrary extends LibraryServer {
  int fileRequests = 0, pageRequestsForEpub = 0;
  final Uint8List file = zip(epub3());

  @override
  Future<Map<String, dynamic>?> book(String id) async {
    final b = await super.book(id);
    if (id != 'B1' || b == null) return b;
    return {...b, 'media': {'mediaProfile': 'EPUB', 'pagesCount': 4}, 'sizeBytes': file.length};
  }

  @override
  Future<List<dynamic>> pages(String bookId) async {
    if (bookId == 'B1') pageRequestsForEpub++;
    return super.pages(bookId);
  }

  @override
  Future<List<dynamic>> epubPositions(String bookId) async => [
        for (var i = 0; i < 4; i++)
          {'href': 'OEBPS/Text/ch2.xhtml', 'type': 'application/xhtml+xml',
            'locations': {'position': i + 1, 'progression': i / 4}},
      ];

  @override
  Future<Uint8List> bookFileBytes(String bookId) async {
    fileRequests++;
    return file;
  }
}

Map<String, dynamic> book(String id, int n) => {'id': id, 'seriesTitle': 'Discworld', 'metadata': {'number': '$n'}};

void main() {
  late Directory dir;
  final d = Downloads.instance;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    d.reset();
    dir = await Directory.systemTemp.createTemp('komga_epub_downloads_test');
  });
  tearDown(() async {
    d.pauseAll();
    for (var i = 0; i < 300 && d.busy; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    d.paused = false;
    await deleteTemp(dir);
  });

  test("an EPUB downloads as its file (not pages), with Komga's positions; offline it opens from that file",
      () async {
    final api = noNetwork(EpubLibrary.new);
    await d.attach(api, root: dir);
    await d.add([book('B1', 1)]);
    await settle(d);
    expect(d.isDownloaded('B1'), isTrue);
    expect(api.fileRequests, 1);
    expect(api.pageRequestsForEpub, 0, reason: 'no page pictures for an EPUB');
    final entry = d.store!.books['B1']!;
    expect(entry['epubFile'], 'book.epub');
    expect((entry['positions'] as List).length, 4);
    expect(await d.store!.file('B1/book.epub').length(), api.file.length);
    expect(d.usedBytes, api.file.length);

    final offline = OfflineKomga(d.store!);
    final f = offline.epubFile('B1')!;
    final info = await FileEpubSource(f).info();
    expect(info.title, 'Sourcery', reason: 'the downloaded file reads');
    // offline, every way of opening it reads that file
    final reader = readerFor(offline, (await offline.book('B1'))!) as EpubReaderScreen;
    expect(reader.source, isA<FileEpubSource>());
    // online, from Komga as usual
    expect((readerFor(api, (await api.book('B1'))!) as EpubReaderScreen).source, isNull);
  });

  test("offline: the place is kept on the device - the exact place to reopen at, and its position as the read "
      'progress (sent to Komga later); read to the end: every position', () async {
    final api = noNetwork(EpubLibrary.new);
    await d.attach(api, root: dir);
    await d.add([book('B1', 1)]);
    await settle(d);
    final offline = OfflineKomga(d.store!);
    expect(await offline.epubProgression('B1'), isNull);
    final saved = {
      'device': {'id': 'x', 'name': 'BeDeReader (Android)'},
      'modified': '2026-10-06T12:00:00Z',
      'locator': {'href': 'OEBPS/Text/ch2.xhtml', 'type': 'application/xhtml+xml',
        'locations': {'progression': 0.6, 'position': 3}},
    };
    await offline.setEpubProgression('B1', saved);
    expect(await offline.epubProgression('B1'), saved, reason: 'reopened here: the exact place');
    expect(offline.store.readProgressOf('B1')!['page'], 3, reason: 'the read progress: its position');
    expect(await offline.epubPositions('B1'), hasLength(4));
    await offline.markRead('B1');
    expect(offline.store.readProgressOf('B1')!['page'], 4, reason: "an EPUB's pages are its positions");
    expect(offline.store.readProgressOf('B1')!['completed'], isTrue);
  });
}
