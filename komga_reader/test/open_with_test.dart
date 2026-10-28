import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:komga_reader/open_with.dart';
import 'package:komga_reader/opened_file.dart';
import 'package:komga_reader/screens/reader.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/epub_files.dart' show epub3, zip;
import 'support/helpers.dart';
import 'support/memory_fs.dart';
import 'support/no_network.dart';
import 'support/reader_server.dart';
import 'support/zip_writer.dart';

// A book file opened from outside the app - Open with, Share, Open in (user, 2026-10-27): straight into the reader,
// nothing kept.

final _page = ReaderServer.onePixel;
final _cbz = zipOf({'001.png': _page, '002.png': _page});

void main() {
  setUpAll(preloadShaders);
  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('the file', () {
    test('a comic: its pages straight from the file; nothing it reads is kept - a page saved, a mark - and it has no '
        'books either side', () async {
      final f = await OpenedFile.open('C:/in/Saga 02.cbz', fs: MemoryFs({'C:/in/Saga 02.cbz': _cbz}));
      final id = f.bookJson['id'] as String;
      expect(f.bookJson['media']['mediaProfile'], 'DIVINA');
      expect(await f.pages(id), hasLength(2));
      expect(await f.pageBytes(id, 2), _page);
      await f.setProgress(id, 2);
      await f.markRead(id);
      expect((await f.book(id))!['readProgress'], isNull);
      expect(await f.nextBook(id), isNull);
      expect(await f.previousBook(id), isNull);
    });

    test("an EPUB handed over as Android hands it (/proc/self/fd/N): told by the name that comes with it; read from "
        "the file", () async {
      final bytes = zip(epub3());
      final f = await OpenedFile.open('/proc/self/fd/7', name: 'Dune.epub', fs: MemoryFs({'/proc/self/fd/7': bytes}));
      expect(f.bookJson['media']['mediaProfile'], 'EPUB');
      expect(await f.epubBytes(), bytes);
    });

    test("the reader's heading over a comic's title is its file's name when its title is another (its ComicInfo's) - "
        'else none, not the title twice (on the tablet)', () async {
      final titled = zipOf({'ComicInfo.xml': '<ComicInfo><Title>A Star Is Born</Title></ComicInfo>', '001.png': _page});
      final f = await OpenedFile.open('C:/in/Atomic Mouse 001.cbz', fs: MemoryFs({'C:/in/Atomic Mouse 001.cbz': titled}));
      expect(f.bookJson['seriesTitle'], 'Atomic Mouse 001');
      final g = await OpenedFile.open('C:/in/Saga 02.cbz', fs: MemoryFs({'C:/in/Saga 02.cbz': _cbz}));
      expect(g.bookJson['metadata']['title'], 'Saga 02');
      expect(g.bookJson['seriesTitle'], '');
    });

    test("a file that isn't a book: not opened, and what the platform holds for it is let go; a book's is let go "
        'once, when it closes', () async {
      var released = 0;
      await expectLater(OpenedFile.open('C:/in/notes.cbz', onClose: () => released++,
          fs: MemoryFs({'C:/in/notes.cbz': Uint8List.fromList('just text'.codeUnits)})), throwsA(anything));
      expect(released, 1);
      final f = await OpenedFile.open('C:/in/a.cbz', onClose: () => released++, fs: MemoryFs({'C:/in/a.cbz': _cbz}));
      expect(released, 1);
      f.close();
      f.close();
      await pumpEventQueue();
      expect(released, 2);
    });
  });

  testWidgets("the reader of a file on its own has no Mark read, Delete or books either side (a book's has)",
      (tester) async {
    Future<void> controlsOf(Widget reader) async {
      await tester.pumpWidget(MaterialApp(home: reader));
      await tester.pump(const Duration(milliseconds: 500));
      await tester.sendKeyEvent(LogicalKeyboardKey.enter); // the controls
      await tester.pump(const Duration(milliseconds: 300));
    }

    final controls = [Icons.check_circle_outline, Icons.delete_outline, Icons.skip_previous, Icons.skip_next];
    final api = noNetwork(ReaderServer.new);
    await controlsOf(ReaderScreen(api: api, book: api.theBook));
    for (final c in controls) {
      expect(find.byIcon(c), findsOneWidget, reason: '$c');
    }
    final f = await OpenedFile.open('C:/in/a.cbz', fs: MemoryFs({'C:/in/a.cbz': _cbz}));
    await controlsOf(ReaderScreen(api: f, book: f.bookJson, saveProgress: false));
    for (final c in controls) {
      expect(find.byIcon(c), findsNothing, reason: '$c');
    }
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('a file arriving while a book is open: the place in that book is saved and it closes, the file opens in '
      'its place; closed, the screen under the book is back and the file is let go', (tester) async {
    final calls = <MethodCall>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(OpenWith.channel, (call) async {
      calls.add(call);
      return null;
    });
    addTearDown(() => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(OpenWith.channel, null));
    final nav = GlobalKey<NavigatorState>();
    final api = noNetwork(ReaderServer.new);
    await tester.pumpWidget(MaterialApp(navigatorKey: nav, home: Builder(builder: (context) => TextButton(
        onPressed: () => Navigator.of(context).push(MaterialPageRoute<void>(
            builder: (_) => ReaderScreen(api: api, book: api.theBook))),
        child: const Text('open')))));
    await tester.tap(find.text('open'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight); // page 2 - saved only 1.5 s after it settles
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(api.saves, isEmpty);

    OpenWith(fs: MemoryFs({'C:/in/Saga 02.cbz': _cbz}))
      ..start(nav, const [])
      ..ready();
    await tester.binding.defaultBinaryMessenger.handlePlatformMessage(OpenWith.channel.name,
        OpenWith.channel.codec.encodeMethodCall(const MethodCall('open', {'path': 'C:/in/Saga 02.cbz', 'token': 5})),
        (_) {});
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(api.saves, [2], reason: "the book's place, saved as it closed");
    expect(find.byType(ReaderScreen), findsOneWidget);
    expect(tester.widget<ReaderScreen>(find.byType(ReaderScreen)).api, isA<OpenedFile>());

    await tester.binding.handlePopRoute();
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(find.byType(ReaderScreen), findsNothing);
    expect(find.text('open'), findsOneWidget);
    expect(calls.where((c) => c.method == 'done').map((c) => c.arguments), [{'token': 5}]);
    expect(calls.where((c) => c.method == 'back'), hasLength(1), reason: 'Android: back to the app it came from');
    expect(api.saves, [2]);
  });

  testWidgets('a second file shared while the first is open takes its place at once - it waited for the first to be '
      'closed (on the tablet); the app stays, and goes back to the other app only once the second is closed',
      (tester) async {
    final calls = <MethodCall>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(OpenWith.channel, (call) async {
      calls.add(call);
      return null;
    });
    addTearDown(() => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(OpenWith.channel, null));
    final nav = GlobalKey<NavigatorState>();
    await tester.pumpWidget(MaterialApp(navigatorKey: nav, home: const Text('home')));
    OpenWith(fs: MemoryFs({'C:/in/a.cbz': _cbz, 'C:/in/b.epub': zip(epub3())}))
      ..start(nav, const [])
      ..ready();
    Future<void> arrives(Map<String, Object> file) async {
      await tester.binding.defaultBinaryMessenger.handlePlatformMessage(OpenWith.channel.name,
          OpenWith.channel.codec.encodeMethodCall(MethodCall('open', file)), (_) {});
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
    }

    Object? shown() => (tester.widget<ReaderScreen>(find.byType(ReaderScreen)).api as OpenedFile).bookJson['name'];
    await arrives({'path': 'C:/in/a.cbz', 'token': 1});
    expect(shown(), 'a');
    await arrives({'path': 'C:/in/b.epub', 'token': 2});
    expect(find.byType(ReaderScreen), findsOneWidget);
    expect(shown(), 'b');
    expect(calls.where((c) => c.method == 'done').map((c) => c.arguments), [{'token': 1}]);
    expect(calls.where((c) => c.method == 'back'), isEmpty);
    await tester.binding.handlePopRoute();
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(find.text('home'), findsOneWidget);
    expect(calls.where((c) => c.method == 'back'), hasLength(1));
    await tester.pumpWidget(const SizedBox());
  });
}
