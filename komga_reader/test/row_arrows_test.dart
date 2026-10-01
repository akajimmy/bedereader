import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:komga_reader/screens/home.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'home_test.dart' as h;

/// Twenty books in progress - a Continue reading row wider than the screen.
class FakeKomga extends h.FakeKomga {
  @override
  Future<Map<String, dynamic>> inProgress({String? libraryId, int size = 30}) async => {
        'content': [
          for (var i = 1; i <= 20; i++)
            {'id': 'B$i', 'seriesTitle': 'Series', 'name': 'b$i', 'metadata': {'number': '$i', 'title': 'T$i'}},
        ],
        'totalElements': 20,
        'last': true,
      };
}

void main() {
  testWidgets('home rows have ‹ › buttons: greyed at the ends, each press scrolls about a screen', (tester) async {
    SharedPreferences.setMockInitialValues({});
    tester.view.physicalSize = const Size(1000, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(home: HomeScreen(api: FakeKomga(), onSignOut: () {})));
    await tester.pump();
    await tester.pump();

    // the button with that tooltip (the helper used to take the first chevron on the screen, whatever its row - test
    // audit, 2026-09-30)
    IconButton button(String tip) =>
        tester.widget<IconButton>(find.ancestor(of: find.byTooltip(tip), matching: find.byType(IconButton)));
    final strip = find.ancestor(of: find.text('Series #1'), matching: find.byType(ListView)).first;
    // (found once: the finder goes through "Series #1", which scrolls out of the strip)
    final scrollable = tester.state<ScrollableState>(find.descendant(of: strip, matching: find.byType(Scrollable)).first);
    ScrollPosition position() => scrollable.position;
    expect(position().axis, Axis.horizontal);
    final screen = tester.getSize(strip).width;

    expect(button('Continue reading: back').onPressed, isNull); // at the start
    expect(button('Continue reading: more').onPressed, isNotNull);
    final firstX = tester.getTopLeft(find.text('Series #1')).dx;

    await tester.tap(find.byTooltip('Continue reading: more'));
    await tester.pumpAndSettle();
    expect(position().pixels, closeTo(0.9 * screen, 1), reason: 'about a screen (90%, so a poster carries over)');
    expect(find.text('Series #1').hitTestable(), findsNothing); // scrolled past the first poster
    expect(button('Continue reading: back').onPressed, isNotNull);

    await tester.tap(find.byTooltip('Continue reading: back'));
    await tester.pumpAndSettle();
    expect(position().pixels, 0);
    expect(tester.getTopLeft(find.text('Series #1')).dx, firstX); // back at the start

    // to the end: there "more" is greyed and "back" isn't
    for (var i = 0; i < 10 && position().pixels < position().maxScrollExtent; i++) {
      await tester.tap(find.byTooltip('Continue reading: more'));
      await tester.pumpAndSettle();
    }
    expect(position().pixels, position().maxScrollExtent);
    expect(position().maxScrollExtent, greaterThan(2 * screen)); // (several presses: twenty posters)
    expect(button('Continue reading: more').onPressed, isNull);
    expect(button('Continue reading: back').onPressed, isNotNull);
  });
}
