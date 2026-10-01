import 'package:flutter_test/flutter_test.dart';
import 'package:komga_reader/api.dart';
import 'package:komga_reader/paged.dart';

/// The read filter, Paged and the server address (api.dart, paged.dart) - this was widget_test.dart, a name left from
/// the project template (test audit, 2026-09-30).
void main() {
  test('read filters map to Komga read_status values', () {
    expect(ReadFilter.all.api, isNull);
    expect(ReadFilter.hideRead.api, ['UNREAD', 'IN_PROGRESS']); // in progress counts as unread
    expect(ReadFilterApi.fromName('inProgress'), ReadFilter.hideRead); // old saved filters carry over
    expect(ReadFilterApi.fromName('read'), ReadFilter.all);
  });

  test('Paged loads page by page, then refreshes what is loaded in place', () async {
    final all = List.generate(250, (i) => i);
    var calls = 0;
    Future<Map<String, dynamic>> fetch(int page, int size) async {
      calls++;
      final chunk = all.skip(page * size).take(size).toList();
      return {'content': chunk, 'totalElements': all.length, 'last': (page + 1) * size >= all.length};
    }

    final p = Paged(fetch);
    await p.more();
    expect(p.items.length, 100);
    expect(p.hasMore, isTrue);
    await p.more();
    await p.more();
    expect(p.items, all);
    expect(p.hasMore, isFalse);
    await p.more(); // nothing left: no request
    expect(calls, 3);
    await p.refresh();
    expect(p.items, all);
    expect(calls, 6);
  });

  test('server URL loses trailing slashes', () {
    expect(Komga('http://192.168.1.10:25600/', 'k').baseUrl, 'http://192.168.1.10:25600');
    expect(Komga('http://192.168.1.10:25600', 'k').pageUrl('B1', 3), 'http://192.168.1.10:25600/api/v1/books/B1/pages/3');
  });
}
