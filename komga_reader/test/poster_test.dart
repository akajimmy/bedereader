import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:komga_reader/screens/book_details.dart';
import 'package:komga_reader/screens/library.dart';
import 'package:komga_reader/settings.dart';
import 'package:komga_reader/widgets/poster.dart';
import 'package:komga_reader/widgets/poster_row.dart';

import 'support/no_network.dart';

void main() {
  for (final scale in const [1.0, 1.3]) {
    testWidgets('a long title does not shrink the cover (text scale $scale)', (tester) async {
      final api = plainKomga();
      Widget tile(String title) => SizedBox(
            width: 150,
            height: 290,
            child: PosterTile(api: api, imageUrl: 'http://test/x', title: title, subtitle: 'Subtitle', onOpen: () {}),
          );
      await tester.pumpWidget(MediaQuery(
        data: MediaQueryData(textScaler: TextScaler.linear(scale)),
        child: MaterialApp(home: Scaffold(body: Row(children: [
          tile('Short #1'),
          tile('A very long series title that certainly wraps onto a second line #123'),
        ]))),
      ));
      await tester.pump();
      final covers = tester.widgetList<ClipRRect>(find.byType(ClipRRect)).toList();
      expect(covers.length, 2);
      final h = [for (final e in find.byType(ClipRRect).evaluate()) e.size!.height];
      expect(h[0], h[1]); // same cover height whatever the title length
      expect(h[0], greaterThan(150));
      expect(tester.takeException(), isNull); // no overflow
    });
  }

  test('release dates on posters read "13 Mar 2024"; none, or not a date: nothing', () {
    expect(posterDate('2024-03-13'), '13 Mar 2024');
    expect(posterDate('1963-09-01'), '1 Sep 1963');
    expect(posterDate(null), isNull);
    expect(posterDate(''), isNull);
    expect(posterDate('soon'), isNull);
  });

  testWidgets('book posters: the release date under the title (a setting, on by default); a book without one keeps '
      'the line, so covers stay the same size; off, no date', (tester) async {
    final api = plainKomga();
    final s = AppSettings.instance;
    addTearDown(() {
      s.setDisplay(const DisplayPrefs());
      s.setLibrary(const LibraryPrefs());
    });
    final dated = {'id': 'b1', 'seriesTitle': 'X-Men', 'metadata': {'number': '3', 'title': 'Dated',
        'releaseDate': '2024-03-13'}};
    final undated = {'id': 'b2', 'seriesTitle': 'X-Men', 'metadata': {'number': '4', 'title': 'Undated'}};
    Future<void> show() async {
      await tester.pumpWidget(MaterialApp(home: Scaffold(body: Builder(builder: (context) => Row(children: [
        for (final b in [dated, undated])
          SizedBox(width: 150, height: 300, child: bookTile(context, api, b, onOpen: () {})),
      ])))));
      await tester.pump();
    }

    expect(s.library.posterDate, isTrue);
    await show();
    expect(find.text('13 Mar 2024'), findsOneWidget);
    final h = [for (final e in find.byType(ClipRRect).evaluate()) e.size!.height];
    expect(h[0], h[1], reason: 'the undated book keeps the date line: same cover size');
    expect(tester.takeException(), isNull);

    s.setLibrary(const LibraryPrefs(posterDate: false));
    await show();
    expect(find.text('13 Mar 2024'), findsNothing);
    final off = [for (final e in find.byType(ClipRRect).evaluate()) e.size!.height];
    expect(off[0], h[0], reason: 'the cover keeps its shape, line or not');
  });

  // Home's rows were a fixed height and the grids' tiles a fixed shape: a larger text size (Settings > Look) took its
  // room from the cover, which (filling its box) lost its top and bottom (user, 2026-10-25: X-Factor #3 on On deck)
  for (final (scale, size) in const [(1.0, PosterSize.medium), (1.3, PosterSize.medium), (1.3, PosterSize.small),
      (1.15, PosterSize.large)]) {
    testWidgets('a cover keeps its shape at any text size - in a row and in a grid (text $scale, ${size.name} '
        'posters)', (tester) async {
      final api = plainKomga();
      final s = AppSettings.instance;
      addTearDown(() => s.setDisplay(const DisplayPrefs()));
      s.setDisplay(s.display.copyWith(posterSize: size));
      Widget tile(BuildContext _, int i) => PosterTile(api: api, imageUrl: 'http://test/$i', title: 'X-Factor #$i',
          subtitle: 'The Big Bang', caption: '13 Mar 2024', onOpen: () {});
      final shapes = <String, double>{}; // the cover box's width / height
      for (final list in [
        PosterRow(title: 'On deck', itemCount: 3, itemBuilder: tile),
        PosterGrid(itemCount: 6, itemBuilder: tile),
      ]) {
        await tester.pumpWidget(MediaQuery(
          data: MediaQueryData(size: const Size(1200, 900), textScaler: TextScaler.linear(scale)),
          child: MaterialApp(key: UniqueKey(), home: Scaffold(body: list is PosterRow
              ? SingleChildScrollView(child: list) : list)),
        ));
        await tester.pump();
        final cover = tester.getSize(find.byType(ClipRRect).first);
        shapes['${list.runtimeType}'] = cover.width / cover.height;
        expect(tester.takeException(), isNull, reason: 'no overflow');
      }
      expect(shapes, {for (final k in shapes.keys) k: closeTo(PosterTile.coverAspect, 0.003)});
    });
  }

  testWidgets('book posters: any of three lines - series #, title, release date - always in that order (user, '
      '2026-10-07: no title = the series # over the date)', (tester) async {
    final api = plainKomga();
    final s = AppSettings.instance;
    addTearDown(() {
      s.setDisplay(const DisplayPrefs());
      s.setLibrary(const LibraryPrefs());
    });
    final b = {'id': 'b1', 'seriesTitle': 'X-Men', 'metadata': {'number': '3', 'title': 'Dated',
        'releaseDate': '2024-03-13'}};
    Future<List<String>> lines(bool series, bool title, bool date) async {
      s.setLibrary(LibraryPrefs(posterSeries: series, posterTitle: title, posterDate: date));
      await tester.pumpWidget(MaterialApp(home: Scaffold(body: Builder(builder: (context) =>
          SizedBox(width: 150, height: 300, child: bookTile(context, api, b, onOpen: () {}))))));
      await tester.pump();
      // the texts under the poster, top to bottom
      final texts = [for (final e in find.byType(Text).evaluate()) (e.widget as Text).data ?? '']
          .where((t) => ['X-Men #3', 'Dated', '13 Mar 2024'].contains(t)).toList();
      final tops = {for (final t in texts) t: tester.getTopLeft(find.text(t)).dy};
      return texts..sort((a, c) => tops[a]!.compareTo(tops[c]!));
    }

    expect(await lines(true, true, true), ['X-Men #3', 'Dated', '13 Mar 2024']);
    expect(await lines(true, false, true), ['X-Men #3', '13 Mar 2024']);
    expect(await lines(false, true, true), ['Dated', '13 Mar 2024']);
    expect(await lines(false, true, false), ['Dated']);
    expect(await lines(false, false, true), ['13 Mar 2024']);
    expect(await lines(false, false, false), isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets("a webtoon's episodes (Komga's Webtoon series, as seen in a list) show the series' cover with an "
      "episode badge - their first page is just the top of a strip (user, 2026-10-22: \"we're going with series "
      'cover"); other books their own cover, no badge', (tester) async {
    final api = plainKomga();
    final s = AppSettings.instance;
    addTearDown(s.webtoonSeries.clear);
    Future<PosterTile> tileOf(Map<String, dynamic> b) async {
      await tester.pumpWidget(MaterialApp(key: UniqueKey(), home: Scaffold(body: Builder(builder: (context) =>
          SizedBox(width: 150, height: 300, child: bookTile(context, api, b, onOpen: () {}))))));
      await tester.pump();
      return tester.widget<PosterTile>(find.byType(PosterTile));
    }

    final episode = {'id': 'b3', 'seriesId': 'W1', 'seriesTitle': 'Strip', 'metadata': {'number': '3', 'title': 'Ep'}};
    final comic = {'id': 'c1', 'seriesId': 'C1', 'seriesTitle': 'X-Men', 'metadata': {'number': '4', 'title': 'Y'}};
    // the series seen as a webtoon (a series list, its page, the reader tell the app)
    s.noteDirection('W1', 'WEBTOON');
    s.noteDirection('C1', 'LEFT_TO_RIGHT');
    final ep = await tileOf(episode);
    expect(ep.imageUrl, api.seriesThumb('W1'), reason: "the series' cover");
    expect(ep.corner, 'Ep. 3');
    expect(find.text('Ep. 3'), findsOneWidget, reason: 'on the cover');
    final c = await tileOf(comic);
    expect(c.imageUrl, api.bookThumb('c1'), reason: 'a comic: its own cover');
    expect(c.corner, isNull);
    // Komga no longer says Webtoon: its own cover again
    s.noteDirection('W1', 'VERTICAL');
    expect((await tileOf(episode)).imageUrl, api.bookThumb('b3'));
  });

  testWidgets("eBook posters have their own lines (user, 2026-10-18: \"Nobody thinks of books in that way\"): title "
      "then author by default, not the series and number; the series and the date if asked; the comics' lines don't "
      'touch them', (tester) async {
    final api = plainKomga();
    final s = AppSettings.instance;
    addTearDown(() {
      s.setDisplay(const DisplayPrefs());
      s.setLibrary(const LibraryPrefs());
    });
    final b = {'id': 'e1', 'seriesTitle': 'Discworld', 'media': {'mediaProfile': 'EPUB'}, 'metadata': {'number': '13',
        'title': 'Small Gods', 'releaseDate': '1992-05-01',
        'authors': [{'name': 'Josh Kirby', 'role': 'cover'}, {'name': 'Terry Pratchett', 'role': 'writer'}]}};
    const all = ['Small Gods', 'Terry Pratchett', 'Discworld #13', '1 May 1992'];
    Future<List<String>> lines(LibraryPrefs d) async {
      s.setLibrary(d);
      await tester.pumpWidget(MaterialApp(key: UniqueKey(), home: Scaffold(body: Builder(builder: (context) =>
          SizedBox(width: 150, height: 300, child: bookTile(context, api, b, onOpen: () {}))))));
      await tester.pump();
      final texts = [for (final e in find.byType(Text).evaluate()) (e.widget as Text).data ?? '']
          .where(all.contains).toList();
      final tops = {for (final t in texts) t: tester.getTopLeft(find.text(t)).dy};
      return texts..sort((a, c) => tops[a]!.compareTo(tops[c]!));
    }

    expect(await lines(const LibraryPrefs()), ['Small Gods', 'Terry Pratchett'], reason: 'the defaults');
    expect(await lines(const LibraryPrefs(posterSeries: false, posterTitle: false, posterDate: false)),
        ['Small Gods', 'Terry Pratchett'], reason: "the comics' lines: not the eBooks'");
    expect(await lines(const LibraryPrefs(ebookPosterAuthor: false, ebookPosterSeries: true, ebookPosterDate: true)),
        ['Small Gods', 'Discworld #13', '1 May 1992']);
    expect(await lines(const LibraryPrefs(ebookPosterTitle: false, ebookPosterSeries: true)),
        ['Terry Pratchett', 'Discworld #13']);
    expect(tester.takeException(), isNull);
  });
}
