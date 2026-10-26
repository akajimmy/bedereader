// Book details: where a book comes from, its path from its library's root, its format, and badges - Downloaded,
// Cached, Not Found (user, 2026-10-26).
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:komga_reader/local/folder_komga.dart';
import 'package:komga_reader/local/folder_scan.dart';
import 'package:komga_reader/local/storage.dart';
import 'package:komga_reader/offline/downloads.dart';
import 'package:komga_reader/offline/store.dart';
import 'package:komga_reader/screens/book_details.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/helpers.dart';
import 'support/no_network.dart';
import 'support/zip_writer.dart';

final _gone = {
  'id': '0B1', 'seriesId': '0S1', 'libraryId': '0L1', 'name': 'Saga #1', 'deleted': true,
  'url': '/data/comics/Archive/Saga (2012)/Saga #1 (2012).cbz',
  'media': {'pagesCount': 20, 'mediaType': 'application/zip'}, 'readProgress': null, 'metadata': {'title': 'Saga'},
};

class _Komga extends TestKomga {
  @override
  Future<List<dynamic>> libraries() async => [{'id': '0L1', 'name': 'Archive', 'root': '/data/comics/Archive'}];
  @override
  Future<Map<String, dynamic>?> book(String id) async => _gone;
  @override
  Future<Map<String, dynamic>?> oneSeries(String id) async => {'id': '0S1', 'name': 'Saga', 'metadata': {}};
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test("a book's format from its file's name, else its media type; its path from its library's root", () {
    expect(bookFormat({'url': r'\\nick-nas\NAS\Saga\Saga 1.cbr'}), 'CBR');
    expect(bookFormat({'url': '/x/Frankenstein.epub'}), 'EPUB');
    expect(bookFormat({'url': '', 'media': {'mediaType': 'application/x-rar-compressed; version=5'}}), 'CBR');
    expect(pathInLibrary(r'\\nick-nas\NAS\COMICS\Archive\Saga (2012)\Saga 1.cbz', r'\\nick-nas\NAS\COMICS\Archive\'),
        'Saga (2012)/Saga 1.cbz');
    expect(pathInLibrary('/data/comics/Archive/Saga/Saga 1.cbz', '/DATA/comics/Archive'), 'Saga/Saga 1.cbz',
        reason: 'any case');
    expect(pathInLibrary('/elsewhere/Saga 1.cbz', '/data/comics/Archive'), '/elsewhere/Saga 1.cbz',
        reason: 'not under it: whole');
  });

  testWidgets("a Komga book: its source, its path from its library's root, its format; Not Found when Komga says its "
      "file is gone; Downloaded and Cached from the downloads", (t) async {
    final d = Downloads.instance;
    d.store = OfflineStore(Directory.systemTemp) // never read or written here
      ..books['0B1'] = {'state': 'done', 'cache': true, 'book': {'seriesId': '0S1'}};
    addTearDown(() => d.store = null);
    await t.pumpWidget(MaterialApp(home: BookDetailsScreen(api: noNetwork(_Komga.new), book: _gone)));
    await t.pumpAndSettle();
    expect(find.text('Saga (2012)/Saga #1 (2012).cbz'), findsOneWidget);
    expect(find.text('CBZ'), findsOneWidget);
    expect(find.byIcon(Icons.error_outline), findsOneWidget, reason: 'Not Found');
    expect(find.byIcon(Icons.history), findsOneWidget, reason: 'Cached');
    expect(find.byIcon(Icons.download_done), findsNothing, reason: "cached isn't downloaded on purpose");
  });

  group("a local book's file", () {
    late Directory root, data;
    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      root = await Directory.systemTemp.createTemp('facts_lib');
      data = await Directory.systemTemp.createTemp('facts_data');
      final f = File('${root.path}${Platform.pathSeparator}Saga${Platform.pathSeparator}Saga 1.cbz');
      await f.parent.create();
      await f.writeAsBytes(zipOf({'1.png': await solidPng(2, 3)}));
    });
    tearDown(() async {
      Storage.fsFor = null;
      await deleteTemp(root);
      await deleteTemp(data);
    });

    test('gone once deleted (Not Found); there, or out of reach, not gone', () async {
      final api = await FolderKomga.open([LocalLibrary.at(root.path)], dataDir: data);
      final id = api.store.books.keys.single;
      expect(api.libraryPath(api.store.books[id]!['book']['libraryId'] as String), root.path);
      expect(await api.fileGone(id), isFalse);
      Storage.fsFor = (_) => _Away();
      expect(await api.fileGone(id), isFalse, reason: "out of reach isn't gone");
      Storage.fsFor = null;
      await File(api.store.books[id]!['path'] as String).delete();
      expect(await api.fileGone(id), isTrue);
    });
  });
}

/// A share out of reach: nothing on it answers.
class _Away implements LibraryFs {
  @override
  dynamic noSuchMethod(Invocation i) => Future<Never>.error(const SocketException('away'));
}
