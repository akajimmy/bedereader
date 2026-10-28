// Where books come from, shown (rebuild step 12): the source icons and their setting, the book details' format and
// path, dates to the precision they're known, the offline wording through one helper, the side menu's libraries kept
// up to date.
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:komga_reader/combined_source.dart';
import 'package:komga_reader/content_changed.dart';
import 'package:komga_reader/local/local_library.dart';
import 'package:komga_reader/local/local_source.dart';
import 'package:komga_reader/screens/book_details.dart';
import 'package:komga_reader/settings.dart';
import 'package:komga_reader/widgets/connection_prompt.dart' show offlineBooks;
import 'package:komga_reader/widgets/drawer.dart';
import 'package:komga_reader/widgets/source_badge.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/no_network.dart';
import 'support/status_server.dart';
import 'support/zip_writer.dart';

/// Komga, counting how often the libraries shown are asked for (the side menu asks for the kept list: the local
/// libraries' part of it is fresh each time).
class _Counting extends StatusServer {
  int asked = 0;
  @override
  Future<List<dynamic>> visibleLibraries({bool kept = false}) async {
    asked++;
    return [];
  }
}

void main() {
  test('a date shown as far as it is known: the year alone, the month and year, or the whole date', () {
    expect(detailsDate('2012-03-01', precision: 'year'), '2012');
    expect(detailsDate('2012-03-01', precision: 'month'), 'March 2012');
    expect(detailsDate('2012-03-07'), '7 March 2012');
    expect(posterDate('2012-03-01', precision: 'year'), '2012');
    expect(posterDate('2012-03-01', precision: 'month'), 'Mar 2012');
    expect(posterDate('2012-03-07', precision: 'day'), '7 Mar 2012');
  });

  test("a book's format from its file name, else its media type; its path from its library's folder on", () {
    expect(bookFormat({'url': r'\\nas\books\Saga\Saga 1.cbr'}), 'CBR');
    expect(bookFormat({'url': '', 'media': {'mediaType': 'application/epub+zip'}}), 'EPUB');
    expect(bookFormat({'media': {'mediaType': 'application/zip'}}), 'CBZ');
    expect(bookFormat({}), isNull);
    expect(pathInLibrary(r'\\nas\books\Comics\Saga\Saga 1.cbz', r'\\NAS\books\Comics'), 'Saga/Saga 1.cbz');
    expect(pathInLibrary('/data/Saga/1.cbz', '/other'), '/data/Saga/1.cbz', reason: 'not under it: whole');
    expect(pathInLibrary('/data/Saga/1.cbz', null), '/data/Saga/1.cbz');
  });

  group('the local libraries', () {
    late Directory root, data;
    late LocalSource local;
    late CombinedSource api;
    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      root = await Directory.systemTemp.createTemp('shown_lib');
      data = await Directory.systemTemp.createTemp('shown_data');
      final f = File('${root.path}${Platform.pathSeparator}Saga${Platform.pathSeparator}Saga 1.cbz');
      await f.parent.create();
      await f.writeAsBytes(zipOf({'1.png': Uint8List.fromList([...pngHead(10, 10), 1])}));
      local = await LocalSource.open(data, [LocalLibrary.at(root.path), LocalLibrary.at(r'\\nas\books\Manga')]);
      api = CombinedSource(noNetwork(StatusServer.new), local: local);
    });
    tearDown(() async {
      await local.closeFiles();
      await root.delete(recursive: true);
      await data.delete(recursive: true);
    });

    test("each item's origin: a book, series or library on this device, a library on a share, Komga's", () async {
      expect(offlineBooks(api), 'downloaded books', reason: 'no local book yet: the downloads only');
      await local.rescan();
      final book = ((await local.books())['content'] as List).single as Map;
      expect(originOf(api, book['id'] as String), Origin.local);
      expect(originOf(api, book['seriesId'] as String), Origin.local);
      expect(originOf(api, LocalLibrary.at(root.path).id), Origin.local);
      expect(originOf(api, LocalLibrary.at(r'\\nas\books\Manga').id), Origin.network);
      expect(originOf(api, 'B0S0E37'), Origin.komga);
      expect(offlineBooks(api), contains('local'), reason: 'local books beside the downloads');
    });

    test('the badge on a poster only with the setting on (this device\'s own, kept)', () async {
      final s = AppSettings.instance;
      addTearDown(() => s.setDisplay(const DisplayPrefs()));
      s.setDisplay(const DisplayPrefs());
      expect(sourceBadgeFor(api, 'B0S0E37'), isNull);
      s.setDisplay(s.display.copyWith(sourceIcon: true));
      expect(sourceBadgeFor(api, 'B0S0E37'), isA<SourceBadge>());
      expect(DisplayPrefs.fromJson(s.display.toJson()).sourceIcon, isTrue);
      expect(DisplayPrefs.fromJson(const DisplayPrefs().toJson()).sourceIcon, isFalse);
    });
  });

  testWidgets("the side menu's libraries asked for again when the content changes (a local library added, Komga "
      'back) - a menu kept open on a wide screen showed the old list', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final komga = noNetwork(_Counting.new);
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: AppDrawer(api: komga, onSignOut: () {}))));
    await tester.pump();
    final before = komga.asked;
    contentChanged.value++;
    await tester.pump();
    expect(komga.asked, greaterThan(before));
  });
}
