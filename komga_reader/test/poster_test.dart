import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:komga_reader/screens/book_details.dart';
import 'package:komga_reader/screens/library.dart';
import 'package:komga_reader/settings.dart';
import 'package:komga_reader/widgets/poster.dart';

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
    addTearDown(() => s.setDisplay(const DisplayPrefs()));
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

    expect(s.display.posterDate, isTrue);
    await show();
    expect(find.text('13 Mar 2024'), findsOneWidget);
    final h = [for (final e in find.byType(ClipRRect).evaluate()) e.size!.height];
    expect(h[0], h[1], reason: 'the undated book keeps the date line: same cover size');
    expect(tester.takeException(), isNull);

    s.setDisplay(const DisplayPrefs(posterDate: false));
    await show();
    expect(find.text('13 Mar 2024'), findsNothing);
    final off = [for (final e in find.byType(ClipRRect).evaluate()) e.size!.height];
    expect(off[0], greaterThan(h[0]), reason: 'without the line the cover gets its room back');
  });

  testWidgets('book posters: any of three lines - series #, title, release date - always in that order (user, '
      '2026-10-07: no title = the series # over the date)', (tester) async {
    final api = plainKomga();
    final s = AppSettings.instance;
    addTearDown(() => s.setDisplay(const DisplayPrefs()));
    final b = {'id': 'b1', 'seriesTitle': 'X-Men', 'metadata': {'number': '3', 'title': 'Dated',
        'releaseDate': '2024-03-13'}};
    Future<List<String>> lines(bool series, bool title, bool date) async {
      s.setDisplay(DisplayPrefs(posterSeries: series, posterTitle: title, posterDate: date));
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
}
