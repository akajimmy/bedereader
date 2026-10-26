import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:komga_reader/api.dart';
import 'package:komga_reader/local/folder_komga.dart';
import 'package:komga_reader/local/folder_scan.dart';
import 'package:komga_reader/local/mixed_komga.dart';
import 'package:komga_reader/settings.dart';
import 'package:komga_reader/widgets/poster.dart';
import 'package:komga_reader/widgets/source_badge.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/helpers.dart';

/// Posters' source icon (user, 2026-10-26: Settings > Library & Home, "show source icon"): a book or series on this
/// device, on a network share, or from Komga.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory dir, data;
  late FolderKomga local;
  const share = LocalLibrary('NAS', r'\\nas\comics\Ongoing');
  late LocalLibrary here;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    dir = await Directory.systemTemp.createTemp('source_lib');
    data = await Directory.systemTemp.createTemp('source_data');
    here = LocalLibrary.at(dir.path);
    local = await FolderKomga.open([here], dataDir: data);
    // the two libraries' books as a scan leaves them (the share's isn't scanned here: no share to scan)
    await local.setLibraries([here, share]);
    for (final (id, series, lib) in [('B1', 'S1', here), ('B2', 'S2', share)]) {
      local.store.books[id] = {
        'book': {'id': id, 'seriesId': series, 'libraryId': lib.id},
        'path': '${lib.path}${Platform.pathSeparator}x${Platform.pathSeparator}$id.cbz',
      };
    }
    local.changed.value++; // (the series' libraries worked out again)
  });
  tearDown(() async {
    AppSettings.instance.display = const DisplayPrefs();
    await deleteTemp(dir);
    await deleteTemp(data);
  });

  test('No server mode: a book and its series on this device, or on a network share', () {
    expect([for (final id in ['B1', 'S1', 'B2', 'S2']) sourceOf(local, id)],
        [BookSource.local, BookSource.local, BookSource.network, BookSource.network]);
  });

  test("signed in to Komga, the local libraries beside it: Komga's books from Komga, the local ones by their library",
      () {
    final mixed = MixedKomga('http://komga.test', 'key', client: MockClient((_) async => http.Response('', 404)))
      ..local = local;
    expect([for (final id in ['B1', 'S2', 'K9']) sourceOf(mixed, id)],
        [BookSource.local, BookSource.network, BookSource.komga]);
    expect(sourceOf(Komga('http://komga.test', 'key'), 'B1'), BookSource.komga, reason: 'no local libraries');
  });

  testWidgets("a library's icon (side menu, Home, the picker): with the setting on, its source's - Komga's and local "
      'libraries of the same name told apart (user, 2026-10-26); off, the plain folder', (tester) async {
    final mixed = MixedKomga('http://komga.test', 'key', client: MockClient((_) async => http.Response('', 404)))
      ..local = local;
    expect(libraryIcon(mixed, here.id), isA<Icon>(), reason: 'off');
    AppSettings.instance.display = const DisplayPrefs(sourceIcon: true);
    final icons = [for (final id in [here.id, share.id, 'KomgaLib']) libraryIcon(mixed, id)];
    expect([for (final i in icons) (i as SourceIcon).source], [BookSource.local, BookSource.network, BookSource.komga]);
    await tester.pumpWidget(MaterialApp(home: Material(child: Column(children: icons))));
    expect(tester.takeException(), isNull);
    expect(find.byType(SourceIcon), findsNWidgets(3));
  });

  testWidgets("a source icon is the size icons are where it is - a button's 18, not 24 (tablet, 2026-10-26: Home's "
      'library buttons came out taller than All libraries beside them)', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: Material(child: Center(child: IconTheme(
        data: IconThemeData(size: 18), child: SourceIcon(BookSource.komga))))));
    expect(tester.getSize(find.byType(SourceIcon)), const Size(18, 18));
  });

  testWidgets('the setting off: no icon; on: the icon, on the poster', (tester) async {
    expect(sourceBadgeFor(local, 'B2'), isNull, reason: 'off by default');
    AppSettings.instance.display = const DisplayPrefs(sourceIcon: true);
    final badge = sourceBadgeFor(local, 'B2');
    expect((badge! as SourceBadge).source, BookSource.network);
    await tester.pumpWidget(MaterialApp(home: Material(child: SizedBox(width: 160, height: 320, child: PosterTile(
        api: local, imageUrl: '', image: const ColoredBox(color: Colors.teal), title: 'x', onOpen: () {},
        source: badge)))));
    expect(find.byType(SourceBadge), findsOneWidget);
  });
}
