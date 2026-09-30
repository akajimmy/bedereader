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

/// Errors in plain words (user, 2026-09-29): every message from the agreed catalogue, and never the raw error text.
void main() {
  const home = 'http://10.0.0.23:25600';
  String message(Object e, {bool signIn = false, String thing = 'item'}) =>
      explain(e, signIn: signIn, thing: thing).message;

  group('the catalogue, word for word', () {
    test('no answer', () {
      expect(message(KomgaUnreachable(home)),
          "Can't reach Komga at 10.0.0.23:25600. Check you're on your home network and the server is running.");
      expect(message(KomgaUnreachable(home), signIn: true),
          "Can't reach Komga at 10.0.0.23:25600. Check the address and port, and that the server is running.");
    });

    test('the API key', () {
      expect(message(KomgaError(401, '/api/v2/users/me'), signIn: true),
          "Komga didn't accept that API key. Copy it again from Komga (your account > API keys).");
      expect(message(KomgaError(401, '/api/v1/books')),
          "Komga no longer accepts this device's API key. It may have been deleted. Create a new one in Komga "
          '(your account > API keys) and sign in again.');
      expect(explain(KomgaError(401, '')).kind, ErrorKind.keyRefused);
    });

    test('not allowed, gone, server fault, turned down', () {
      expect(message(KomgaError(403, '/x')), "Your Komga account isn't allowed to do that.");
      expect(message(KomgaError(404, '/x'), thing: 'book'),
          'That book is no longer on Komga. It may have been deleted or moved; pull down to refresh.');
      expect(message(KomgaError(500, '/x')),
          "Komga ran into a problem (error 500). Try again; if it keeps happening, Komga's logs will say why.");
      expect(message(KomgaError(400, '/x')), 'Komga turned that down (error 400).');
    });

    test('something else answered; https not trusted; not an address', () {
      expect(message(KomgaNotKomga('http://10.0.0.23:8080')),
          "Something answered at 10.0.0.23:8080, but it isn't Komga. Check the port; Komga's is usually 25600.");
      expect(message(KomgaCertificate('https://komga.example.org')),
          "Couldn't make a secure connection to komga.example.org: this device doesn't trust the server's "
          'certificate. Use http:// at home, or a certificate from a trusted provider.');
      expect(message(const FormatException('Scheme not starting with alphabetic character')),
          "That isn't a server address. It should look like 192.168.1.10:25600.");
      expect(message(ArgumentError("Unsupported scheme 'ftp' in URI ftp://x")),
          "That isn't a server address. It should look like 192.168.1.10:25600.");
    });

    test('offline, storage, a page that cannot be shown, anything else', () {
      expect(message(NotAvailableOffline('Deleting a book')),
          "Deleting a book needs Komga, and you're using downloaded books only.");
      expect(message(NotAvailableOffline('Page 3 of this book')), "Page 3 of this book isn't downloaded.");
      expect(message(const FileSystemException('write failed', '/x', OSError('No space left on device', 28))),
          'This device is out of storage space. Free some up, then try again.');
      expect(message(const FileSystemException('write failed', '/x', OSError('Access denied', 13))),
          "Couldn't save to this device's storage.");
      expect(message(PageUnreadable(Exception('Invalid image data'))),
          "This page couldn't be shown: the image file is damaged or in a format this device can't read.");
      expect(message(StateError('bad state')), 'Something unexpected went wrong.');
    });

    test('failed actions name the action, then the reason', () {
      expect(couldnt('mark "Saga #3" as read', KomgaUnreachable(home)), 'Couldn\'t mark "Saga #3" as read: can\'t reach Komga.');
      expect(couldnt('delete "Saga #3"', KomgaError(403, '/x'), forbidden: deleteNeedsAdmin),
          'Couldn\'t delete "Saga #3": deleting files needs an admin account in Komga.');
      expect(stoppedAfter('Marked 4 of 7 as read', KomgaUnreachable(home)),
          "Marked 4 of 7 as read, then stopped: can't reach Komga.");
      expect(stoppedAfter('Deleted 2 of 5', KomgaError(500, '/x')),
          'Deleted 2 of 5, then stopped: Komga ran into a problem (error 500).');
    });

    test('addresses are shown without http://', () {
      expect(displayAddress('http://10.0.0.23:25600/'), '10.0.0.23:25600');
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
      final back = ErrorEntry.fromJson(ErrorLog.instance.entries.first.toJson());
      expect((back.message, back.detail), ('message 54', 'KomgaError: HTTP 500 on /p54'));
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
