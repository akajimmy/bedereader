import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:komga_reader/api.dart';
import 'package:komga_reader/widgets/poster.dart';

void main() {
  for (final scale in const [1.0, 1.3]) {
    testWidgets('a long title does not shrink the cover (text scale $scale)', (tester) async {
      final api = Komga('http://test', 'k');
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
}
