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

    IconButton button(String tip) => tester.widget<IconButton>(find.widgetWithIcon(IconButton,
        tip.endsWith('back') ? Icons.chevron_left : Icons.chevron_right).first);
    expect(button('Continue reading: back').onPressed, isNull); // at the start
    expect(button('Continue reading: more').onPressed, isNotNull);
    final firstX = tester.getTopLeft(find.text('Series #1')).dx;

    await tester.tap(find.byTooltip('Continue reading: more'));
    await tester.pumpAndSettle();
    expect(find.text('Series #1').hitTestable(), findsNothing); // scrolled past the first poster
    expect(button('Continue reading: back').onPressed, isNotNull);

    await tester.tap(find.byTooltip('Continue reading: back'));
    await tester.pumpAndSettle();
    expect(tester.getTopLeft(find.text('Series #1')).dx, firstX); // back at the start
  });
}
