// Screens hear the settings they show, not every setting (code review 2026-10-05, #44): dragging the brightness
// slider rebuilt the whole reader and every poster grid under it, many times a second.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:komga_reader/screens/reader.dart';
import 'package:komga_reader/settings.dart';
import 'package:komga_reader/widgets/poster.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/no_network.dart';
import 'support/reader_server.dart';

void main() {
  final s = AppSettings.instance;
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    s.setDisplay(const DisplayPrefs());
  });

  testWidgets('a poster grid: brightness changing builds nothing again; poster size does', (tester) async {
    var built = 0;
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: PosterGrid(itemCount: 4, itemBuilder: (_, i) {
      built++;
      return Text('$i');
    }))));
    final first = built;
    for (final b in [0.3, 0.4, 0.5]) { // a slider drag
      s.setDisplay(s.display.copyWith(brightness: () => b));
      await tester.pump();
    }
    expect(built, first, reason: 'nothing rebuilt for brightness');
    s.setDisplay(s.display.copyWith(posterSize: PosterSize.large));
    await tester.pump();
    expect(built, greaterThan(first), reason: 'poster size: rebuilt');
  });

  testWidgets('the comic reader: brightness changing builds nothing again; a setting it shows does', (tester) async {
    final api = noNetwork(ReaderServer.new);
    await tester.pumpWidget(MaterialApp(home: ReaderScreen(api: api, book: api.theBook)));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    final first = ReaderScreen.debugBuilds;
    for (final b in [0.3, 0.4, 0.5]) {
      s.setDisplay(s.display.copyWith(brightness: () => b));
      await tester.pump();
    }
    expect(ReaderScreen.debugBuilds, first, reason: 'brightness is drawn over the whole app, not by the reader');
    s.setDisplay(s.display.copyWith(pageNumber: !s.display.pageNumber));
    await tester.pump();
    expect(ReaderScreen.debugBuilds, greaterThan(first));
    await tester.pump(const Duration(seconds: 2));
  });
}
