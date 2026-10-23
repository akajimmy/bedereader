// A webtoon's episodes on its series page show the series' cover (user, 2026-10-22: "we're going with series cover";
// on the tablet they still showed their first pages - nothing had told the app the series was a webtoon).
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:komga_reader/screens/series.dart';
import 'package:komga_reader/settings.dart';
import 'package:komga_reader/widgets/poster.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/browse_server.dart';
import 'support/no_network.dart';

/// A webtoon series, W1, with two episodes; Komga says Webtoon only when asked for the series itself.
class _Strip extends BrowseServer {
  @override
  Future<Map<String, dynamic>?> oneSeries(String id) async =>
      {'id': id, 'name': 'Strip', 'metadata': {'title': 'Strip', 'readingDirection': 'WEBTOON'}};

  @override
  Future<Map<String, dynamic>> seriesBooks(String seriesId, {List<String>? readStatus,
      String sort = 'metadata.numberSort,asc', int page = 0, int size = 500}) async => {
        'content': [
          for (final n in [1, 2])
            {'id': 'B$n', 'seriesId': seriesId, 'seriesTitle': 'Strip', 'name': 'Strip #$n',
                'metadata': {'number': '$n', 'title': 'Episode $n'}, 'media': {'pagesCount': 10}},
        ],
        'last': true, 'totalElements': 2, 'number': page,
      };
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    AppSettings.instance.webtoonSeries.clear();
  });
  tearDown(AppSettings.instance.webtoonSeries.clear);

  testWidgets("opened with no reading direction to hand (from a book, a pin), the series page asks Komga - a "
      "webtoon's episodes then show the series' cover and their number", (tester) async {
    final api = noNetwork(_Strip.new);
    await tester.pumpWidget(MaterialApp(home: SeriesScreen(api: api,
        series: const {'id': 'W1', 'name': 'Strip'}))); // (only its id and name, as from a book or a pin)
    for (var i = 0; i < 5; i++) {
      await tester.pump();
    }
    final tiles = tester.widgetList<PosterTile>(find.byType(PosterTile)).toList();
    expect(tiles, hasLength(2));
    expect([for (final t in tiles) t.imageUrl], everyElement(api.seriesThumb('W1')), reason: "the series' cover");
    expect([for (final t in tiles) t.corner], ['Ep. 1', 'Ep. 2']);
    expect(AppSettings.instance.webtoonSeries, contains('W1'), reason: 'remembered');
  });
}
