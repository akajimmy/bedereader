import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:komga_reader/api.dart';
import 'package:komga_reader/screens/actions.dart';
import 'package:komga_reader/screens/edit_metadata.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/no_network.dart';

// Metadata editing (user, 2026-10-27; reports\10-27-metadata-plan.md): step 1, Komga.

/// A Komga that records the edits sent to it, and answers whether the account is an admin.
class _EditKomga extends TestKomga {
  bool admin = true;
  int asked = 0;
  final booksSaved = <String, Map<String, Object?>>{}, seriesSaved = <String, Map<String, Object?>>{};
  @override
  Future<bool> canEditMetadata(String id) async {
    asked++;
    return admin;
  }

  @override
  Future<void> editBookMetadata(String bookId, Map<String, Object?> changes) async => booksSaved[bookId] = changes;
  @override
  Future<void> editSeriesMetadata(String seriesId, Map<String, Object?> changes) async => seriesSaved[seriesId] = changes;
  @override
  Future<Map<String, dynamic>> series({String? libraryId, String? collectionId, List<String>? readStatus,
          String sort = 'metadata.titleSort,asc', int page = 0, int size = 60}) async =>
      const {'content': [{'id': 'S1', 'name': 'Saga'}, {'id': 'S2', 'name': 'Saga Deluxe'}]};
  @override
  Future<List<String>> publishers({String? libraryId, String? collectionId}) async => const ['Image', 'Marvel'];
}

Map<String, dynamic> _book(String id, {String title = 'Saga', String number = '1', String? date = '2012-03-14'}) => {
      'id': id, 'seriesId': 'S1', 'seriesTitle': 'Saga', 'libraryId': 'L1', 'name': 'Saga 001',
      'metadata': {'title': title, 'number': number, 'numberSort': 1, 'releaseDate': date},
    };

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('the changes sent', () {
    test("a book: only the fields changed; a number's sort number follows it (none for a number with no figures); a "
        'date cleared is null', () {
      final b = _book('B1');
      expect(bookChanges(b, title: 'Saga', number: '1', date: DateTime(2012, 3, 14)), isEmpty);
      expect(bookChanges(b, title: ' Saga, Chapter One ', number: '12.5', date: null),
          {'title': 'Saga, Chapter One', 'number': '12.5', 'numberSort': 12.5, 'releaseDate': null});
      expect(bookChanges(b, title: 'Saga', number: 'Annual', date: DateTime(2013, 1, 2)),
          {'number': 'Annual', 'releaseDate': '2013-01-02'});
      expect(bookChanges(b, title: 'Saga', number: '1', date: DateTime(2012, 3, 14), series: 'saga'), isEmpty,
          reason: 'the same series, written another way');
      expect(bookChanges(b, title: 'Saga', number: '1', date: DateTime(2012, 3, 14), series: 'Saga Deluxe'),
          {'seriesName': 'Saga Deluxe'});
    });

    test('a series: only the fields changed; reading direction "not set" is null', () {
      final s = {'id': 'S1', 'metadata': {'title': 'Saga', 'titleSort': 'Saga', 'readingDirection': 'LEFT_TO_RIGHT',
          'status': 'ONGOING', 'publisher': 'Image'}};
      expect(seriesChanges(s, title: 'Saga', titleSort: 'Saga', readingDirection: 'LEFT_TO_RIGHT', status: 'ONGOING',
          publisher: 'Image'), isEmpty);
      expect(seriesChanges(s, title: 'Saga', titleSort: 'Saga', readingDirection: null, status: 'HIATUS',
          publisher: 'Image Comics'), {'readingDirection': null, 'status': 'HIATUS', 'publisher': 'Image Comics'});
    });
  });

  group("Komga's side", () {
    Komga komga(List<http.Request> sent, {List<String> roles = const ['ADMIN']}) => http.runWithClient(
        () => Komga('http://komga.test:25600', 'key'),
        () => MockClient((r) async {
              sent.add(r);
              return r.url.path == '/api/v2/users/me'
                  ? http.Response(jsonEncode({'id': 'U1', 'roles': roles}), 200)
                  : http.Response('', 204);
            }));

    test("Edit is an admin's (asked once); a book's fields are saved with a lock each, its series not sent", () async {
      final sent = <http.Request>[];
      final api = komga(sent);
      expect(await api.canEditMetadata('B1'), isTrue);
      expect(await api.canEditMetadata('S1'), isTrue);
      expect(sent.where((r) => r.url.path == '/api/v2/users/me'), hasLength(1));
      expect(await komga([], roles: const ['FILE_DOWNLOAD']).canEditMetadata('B1'), isFalse);

      final changes = {'title': 'One', 'releaseDate': null, 'seriesName': 'Other'};
      await api.editBookMetadata('B1', changes);
      final r = sent.last;
      expect((r.method, r.url.path), ('PATCH', '/api/v1/books/B1/metadata'));
      expect(jsonDecode(r.body), {'title': 'One', 'titleLock': true, 'releaseDate': null, 'releaseDateLock': true});
      expect(changes, contains('seriesName'), reason: "the caller's map left as it was");

      await api.editSeriesMetadata('S1', {'status': 'ENDED'});
      expect((sent.last.method, sent.last.url.path), ('PATCH', '/api/v1/series/S1/metadata'));
      expect(jsonDecode(sent.last.body), {'status': 'ENDED', 'statusLock': true});
    });
  });

  group('the editors', () {
    Future<void> show(WidgetTester tester, Future<void> Function(BuildContext) open) async {
      await tester.pumpWidget(MaterialApp(home: Builder(builder: (context) => TextButton(
          onPressed: () => open(context), child: const Text('go')))));
      await tester.tap(find.text('go'));
      await tester.pumpAndSettle();
    }

    testWidgets("a Komga book: its fields saved as changed; its series shown, not editable (Komga's folders)",
        (tester) async {
      final api = noNetwork(_EditKomga.new);
      var saved = false;
      await show(tester, (c) async => saved = await editBook(c, api, _book('B1')));
      expect(find.byKey(const ValueKey('edit-series')), findsNothing);
      await tester.enterText(find.byKey(const ValueKey('edit-title')), 'Chapter One');
      await tester.tap(find.byKey(const ValueKey('edit-date-clear')));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('edit-save')));
      await tester.pumpAndSettle();
      expect(api.booksSaved['B1'], {'title': 'Chapter One', 'releaseDate': null});
      expect(saved, isTrue);
    });

    testWidgets('a local book: its series can be typed (a new one) and is sent by name', (tester) async {
      final api = noNetwork(_EditKomga.new);
      await show(tester, (c) => editBook(c, api, _book('lbBOOK')));
      await tester.enterText(find.byKey(const ValueKey('edit-series')), 'Saga Deluxe');
      await tester.tap(find.byKey(const ValueKey('edit-save')));
      await tester.pumpAndSettle();
      expect(api.booksSaved['lbBOOK'], {'seriesName': 'Saga Deluxe'});
    });

    testWidgets('a series: status and publisher saved; nothing changed, nothing sent', (tester) async {
      final api = noNetwork(_EditKomga.new);
      final s = {'id': 'S1', 'libraryId': 'L1', 'metadata': {'title': 'Saga', 'status': 'ONGOING', 'publisher': 'Image'}};
      await show(tester, (c) => editSeries(c, api, s));
      await tester.tap(find.byKey(const ValueKey('edit-save')));
      await tester.pumpAndSettle();
      expect(api.seriesSaved, isEmpty);
      await show(tester, (c) => editSeries(c, api, s));
      await tester.tap(find.byKey(const ValueKey('edit-status')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Ended').last);
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const ValueKey('edit-publisher')), 'Image Comics');
      await tester.tap(find.byKey(const ValueKey('edit-save')));
      await tester.pumpAndSettle();
      expect(api.seriesSaved['S1'], {'status': 'ENDED', 'publisher': 'Image Comics'});
    });

    testWidgets("Edit is in a book's and a series' long-press menu only where the source allows it", (tester) async {
      final api = noNetwork(_EditKomga.new);
      for (final admin in [true, false]) {
        api.admin = admin;
        await show(tester, (c) => showBookActions(c, api, _book('B1'), onChanged: () {}));
        expect(find.byIcon(Icons.edit_outlined), admin ? findsOneWidget : findsNothing, reason: 'book, admin $admin');
        await tester.tapAt(const Offset(10, 10)); // (the sheet closed)
        await tester.pumpAndSettle();
        await show(tester, (c) => showSeriesActions(c, api, {'id': 'S1', 'name': 'Saga'}, onChanged: () {}));
        expect(find.byIcon(Icons.edit_outlined), admin ? findsOneWidget : findsNothing, reason: 'series, admin $admin');
        await tester.tapAt(const Offset(10, 10));
        await tester.pumpAndSettle();
      }
    });
  });
}
