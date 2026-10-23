import 'dart:async';
import 'dart:io' show FileSystemException, OSError;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:komga_reader/api.dart';
import 'package:komga_reader/errors.dart';
import 'package:komga_reader/offline/offline_komga.dart' show NotAvailableOffline;
import 'package:komga_reader/widgets/error_text.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Errors in plain words (user, 2026-09-29): each failure its catalogue entry, and never the raw error text.
void main() {
  const home = 'http://192.168.1.10:25600';
  String message(Object e, {bool signIn = false, String thing = 'item'}) =>
      explain(e, signIn: signIn, thing: thing).message;

  // each failure gets its kind's entry from the catalogue, with what the app fills in (the address, the thing, the
  // status, the action) - not the catalogue's words, which may be reworded (user's ruling, 2026-10-23: no wording
  // tests; this group checked every message word for word)
  group('the catalogue: each failure its entry', () {
    ErrorKind kind(Object e, {bool signIn = false}) => explain(e, signIn: signIn).kind;

    test('no answer: the address without http://; on the sign-in screen its own advice', () {
      expect(kind(KomgaUnreachable(home)), ErrorKind.unreachable);
      expect(message(KomgaUnreachable(home)), contains('192.168.1.10:25600'));
      expect(message(KomgaUnreachable(home)), isNot(contains('http://')));
      expect(message(KomgaUnreachable(home), signIn: true), isNot(message(KomgaUnreachable(home))));
    });

    test('the API key: refused, with its own words on the sign-in screen (a key just typed)', () {
      expect(kind(KomgaError(401, '/api/v2/users/me'), signIn: true), ErrorKind.keyRefused);
      expect(kind(KomgaError(401, '/api/v1/books')), ErrorKind.keyRefused);
      expect(message(KomgaError(401, ''), signIn: true), isNot(message(KomgaError(401, ''))));
    });

    test('not allowed (with the reason when it is known), gone (naming the thing), server fault, turned down - the '
        'status shown', () {
      expect(kind(KomgaError(403, '/x')), ErrorKind.forbidden);
      expect(explain(KomgaError(403, '/x'), forbidden: deleteNeedsAdmin).reason, deleteNeedsAdmin);
      expect(kind(KomgaError(404, '/x')), ErrorKind.gone);
      expect(message(KomgaError(404, '/x'), thing: 'book'), contains('book'));
      expect(kind(KomgaError(500, '/x')), ErrorKind.serverFault);
      expect(kind(KomgaError(503, '/x')), ErrorKind.serverFault);
      expect(message(KomgaError(503, '/x')), contains('503'));
      expect(kind(KomgaError(400, '/x')), ErrorKind.refused);
      expect(message(KomgaError(400, '/x')), contains('400'));
    });

    test('something else answered (its address); https not trusted (the host); not an address', () {
      expect(kind(KomgaNotKomga('http://192.168.1.10:8080')), ErrorKind.notKomga);
      expect(message(KomgaNotKomga('http://192.168.1.10:8080')), contains('192.168.1.10:8080'));
      expect(kind(KomgaCertificate('https://komga.example.org')), ErrorKind.certificate);
      expect(message(KomgaCertificate('https://komga.example.org')), contains('komga.example.org'));
      expect(kind(const FormatException('Scheme not starting with alphabetic character')), ErrorKind.badAddress);
      expect(kind(ArgumentError("Unsupported scheme 'ftp' in URI ftp://x")), ErrorKind.badAddress);
    });

    test('offline (naming what needs Komga; a page or the next book just not downloaded), storage full or not, a page '
        'that cannot be shown, anything else', () {
      expect(kind(NotAvailableOffline('Deleting a book')), ErrorKind.offline);
      expect(message(NotAvailableOffline('Deleting a book')), startsWith('Deleting a book'));
      expect(message(NotAvailableOffline('Page 3 of this book')), startsWith('Page 3 of this book'));
      expect(message(NotAvailableOffline('Page 3 of this book')), isNot(contains('needs Komga')),
          reason: "a page isn't downloaded; it doesn't need Komga");
      expect(kind(const FileSystemException('write failed', '/x', OSError('No space left on device', 28))),
          ErrorKind.storageFull);
      expect(kind(const FileSystemException('write failed', '/x', OSError('There is not enough space', 112))),
          ErrorKind.storageFull);
      expect(kind(const FileSystemException('write failed', '/x', OSError('Access denied', 13))), ErrorKind.storage);
      expect(kind(PageUnreadable(Exception('Invalid image data'))), ErrorKind.unreadablePage);
      expect(kind(StateError('bad state')), ErrorKind.unexpected);
    });

    test('failed actions name the action, then the reason', () {
      final e = KomgaUnreachable(home);
      expect(couldnt('mark "Saga #3" as read', e), 'Couldn\'t mark "Saga #3" as read: ${explain(e).reason}.');
      expect(couldnt('delete "Saga #3"', KomgaError(403, '/x'), forbidden: deleteNeedsAdmin),
          'Couldn\'t delete "Saga #3": $deleteNeedsAdmin.');
      expect(stoppedAfter('Marked 4 of 7 as read', e), 'Marked 4 of 7 as read, then stopped: ${explain(e).reason}.');
    });

    test('addresses are shown without http://', () {
      expect(displayAddress('http://192.168.1.10:25600/'), '192.168.1.10:25600');
      expect(displayAddress('https://komga.example.org'), 'komga.example.org');
    });
  });

  test('nothing technical ever reaches the message: no exception names, HTTP, paths or raw URLs', () {
    final raw = <Object>[
      KomgaUnreachable(home), KomgaNotKomga(home), KomgaCertificate('https://x.org'),
      for (final s in [400, 401, 403, 404, 409, 500, 502, 503]) KomgaError(s, '/api/v1/books/B1/read-progress'),
      NotAvailableOffline('Deleting a book'), PageUnreadable(Exception('Codec failed')),
      const FormatException('Scheme not starting with alphabetic character (at character 1)'),
      const FileSystemException('Cannot create file', r'C:\x', OSError('No space left on device', 112)),
      TimeoutException('x'), StateError('x'), Exception('boom'), TypeError(),
    ];
    for (final e in raw) {
      for (final signIn in [false, true]) {
        final ex = explain(e, signIn: signIn);
        for (final text in [ex.message, ex.reason]) {
          expect(text, isNot(matches(RegExp(r'Exception|Error\b|HTTP \d|/api/|https?://[^ ]*[:/]|errno|at character'))),
              reason: '${e.runtimeType} -> $text');
        }
      }
    }
  });

  group('error log', () {
    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      await ErrorLog.instance.clear();
    });

    test('newest first, at most 50, raw text kept, and it survives a restart', () async {
      for (var i = 0; i < 55; i++) {
        ErrorLog.instance.record('message $i', KomgaError(500, '/p$i'));
      }
      await Future<void>.delayed(Duration.zero);
      final log = ErrorLog.instance.entries;
      expect(log.length, 50);
      expect(log.first.message, 'message 54');
      expect(log.first.detail, 'KomgaError: HTTP 500 on /p54'); // the technical text, for Details / Copy
      final saved = (await SharedPreferences.getInstance()).getStringList('errorLog')!;
      expect(saved.length, 50);

      // the restart itself: memory gone, read back from the device (it never called load() - test audit, 2026-09-30)
      ErrorLog.instance.reset();
      expect(ErrorLog.instance.entries, isEmpty);
      await ErrorLog.instance.load();
      final back = ErrorLog.instance.entries;
      expect(back.map((e) => e.message), [for (var i = 54; i >= 5; i--) 'message $i'], reason: 'newest first, all 50');
      expect((back.first.message, back.first.detail), ('message 54', 'KomgaError: HTTP 500 on /p54'));
    });
  });

  group('on screen', () {
    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      await ErrorLog.instance.clear();
    });

    testWidgets('an error on a screen: the message, Details with the raw error and Copy; logged once', (tester) async {
      final e = KomgaError(500, '/api/v1/series');
      final shown = explain(e).message;
      await tester.pumpWidget(MaterialApp(home: Scaffold(body: ErrorText(shown, e))));
      await tester.pumpWidget(MaterialApp(home: Scaffold(body: ErrorText(shown, e)))); // a rebuild
      expect(find.text(shown), findsOneWidget);
      expect(ErrorLog.instance.entries.length, 1); // not once per rebuild

      String? copied;
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
        if (call.method == 'Clipboard.setData') copied = (call.arguments as Map)['text'] as String;
        return null;
      });
      await tester.tap(find.text('Details'));
      await tester.pumpAndSettle();
      expect(find.textContaining('KomgaError: HTTP 500 on /api/v1/series'), findsOneWidget);
      await tester.tap(find.text('Copy'));
      await tester.pumpAndSettle();
      expect(copied, contains('HTTP 500 on /api/v1/series'));
    });

    testWidgets('a failed action: the pop-up message with Details, and in the log', (tester) async {
      final e = KomgaUnreachable(home);
      await tester.pumpWidget(MaterialApp(home: Scaffold(body: Builder(builder: (context) => TextButton(
        onPressed: () => showErrorSnack(context, couldnt('mark "Saga #3" as read', e), e),
        child: const Text('go'),
      )))));
      await tester.tap(find.text('go'));
      await tester.pump();
      expect(find.text('Couldn\'t mark "Saga #3" as read: can\'t reach Komga.'), findsOneWidget);
      expect(find.text('Details'), findsOneWidget);
      expect(ErrorLog.instance.entries.single.detail, 'KomgaUnreachable: no answer from $home');
      await tester.pump(const Duration(seconds: 10)); // the message times out
    });

    testWidgets('the error log screen lists them newest first, with the raw text on opening one', (tester) async {
      ErrorLog.instance.record('First', KomgaError(500, '/a'));
      ErrorLog.instance.record('Second', KomgaUnreachable(home));
      await tester.pumpWidget(const MaterialApp(home: ErrorLogScreen()));
      final titles = tester.widgetList<Text>(find.descendant(of: find.byType(ExpansionTile), matching: find.byType(Text)))
          .map((t) => t.data).where((d) => d == 'First' || d == 'Second').toList();
      expect(titles, ['Second', 'First']);
      await tester.tap(find.text('Second'));
      await tester.pumpAndSettle();
      expect(find.textContaining('no answer from $home'), findsOneWidget);
    });
  });
}
