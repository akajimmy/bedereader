import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:komga_reader/local/storage.dart';

/// A Komga server by a bare name DNS doesn't know (user, 2026-10-26: http://nick-nas:25600 "Can't reach Komga" on the
/// tablet - the shares found nick-nas as nick-nas.local, Komga didn't).
void main() {
  late HttpServer server;
  final asked = <String>[];

  setUp(() async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((r) => r.response
      ..write('komga')
      ..close());
    asked.clear();
    // DNS doesn't know "nas"; the local network answers to nas.local
    lookupHost = (name) async {
      asked.add(name);
      if (name == 'nas.local') return [InternetAddress.loopbackIPv4];
      throw SocketException('Failed host lookup: $name');
    };
    HttpOverrides.global = LocalNames(); // (as main.dart sets it)
  });
  tearDown(() async {
    HttpOverrides.global = null;
    lookupHost = InternetAddress.lookup;
    await server.close(force: true);
  });

  test('a bare name DNS doesn\'t know: found as name.local, and the request answered', () async {
    final r = await http.get(Uri.parse('http://nas:${server.port}/api/v2/users/me'));
    expect(r.body, 'komga');
    expect(asked, ['nas', 'nas.local']);
  });

  test('found once, kept for the run: the next connection asks no one', () async {
    final names = LocalNames();
    HttpOverrides.global = names;
    final c1 = HttpClient(), c2 = HttpClient(); // (each its own connection)
    for (final c in [c1, c2]) {
      final rq = await c.getUrl(Uri.parse('http://nas:${server.port}/'));
      expect(await (await rq.close()).transform(const SystemEncoding().decoder).join(), 'komga');
      c.close(force: true);
    }
    expect(asked, ['nas', 'nas.local'], reason: 'looked up the first time only');
  });
}
