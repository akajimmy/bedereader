// Opt-in: the EPUB reader with its controls up, in real fonts (Roboto, the icons, Literata), saved as a PNG
// (BEDEREADER_SHOT) - to look at the controls without the app. Skipped unless the file is given.
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:komga_reader/screens/reader.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/epub_books.dart' show twoChapters;
import 'support/no_network.dart';

void main() {
  final shot = Platform.environment['BEDEREADER_SHOT'];
  testWidgets('the controls, as a picture', (tester) async {
    SharedPreferences.setMockInitialValues({});
    await tester.runAsync(() async {
      Future<ByteData> bytes(String f) async => ByteData.sublistView(File(f).readAsBytesSync());
      const fonts = r'C:\Dev\flutter\bin\cache\artifacts\material_fonts';
      await (FontLoader('Roboto')..addFont(bytes('$fonts/roboto-regular.ttf'))..addFont(bytes('$fonts/roboto-medium.ttf')))
          .load();
      await (FontLoader('MaterialIcons')..addFont(bytes('$fonts/materialicons-regular.otf'))).load();
      await (FontLoader('Literata')..addFont(bytes('assets/fonts/Literata.ttf'))).load();
    });
    tester.view.physicalSize = const Size(1200, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final key = GlobalKey();
    await tester.pumpWidget(RepaintBoundary(key: key, child: MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: ThemeData(brightness: Brightness.dark, useMaterial3: true, fontFamily: 'Roboto',
            colorScheme: const ColorScheme.dark(primary: Color(0xFF26A69A))),
        home: ReaderScreen(api: plainKomga(), book: const {'id': 'B1', 'name': 'Book', 'seriesTitle': 'A Series',
            'metadata': {'title': 'The Book', 'number': '3'}, 'media': {'mediaProfile': 'EPUB'}},
            epubSource: twoChapters(), saveProgress: false))));
    for (var i = 0; i < 60; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pump();
    }
    await tester.tapAt(const Offset(600, 800));
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown); // the remote on Previous book, then the slider
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    await tester.runAsync(() async {
      final boundary = key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      final img = await boundary.toImage();
      final png = await img.toByteData(format: ui.ImageByteFormat.png);
      File(shot!).writeAsBytesSync(png!.buffer.asUint8List());
    });
  }, skip: shot == null);
}
