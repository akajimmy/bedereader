import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:komga_reader/local_names.dart';

/// A Komga server by a bare name the system doesn't know (user, 2026-10-26: http://nick-nas:25600 "Can't reach Komga"
/// on the tablet - Windows finds nick-nas by itself, Android and iOS only as nick-nas.local).
void main() {
  late HttpServer server;
  final asked = <String>[], connected = <String>[];
  var localKnown = true; // the local network answers to nas.local
  var refuse = false; // connections fail (the NAS away, or at another address)

  setUp(() async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((r) => r.response
      ..write('komga')
      ..close());
    asked.clear();
    connected.clear();
    localKnown = true;
    refuse = false;
    lookupHost = (name) async {
      asked.add(name);
      if (name == 'nas.local' && localKnown) return [InternetAddress.loopbackIPv4];
      if (name == 'known') return [InternetAddress.loopbackIPv4];
      throw SocketException('Failed host lookup: $name');
    };
    // connected by name, as the system does: 'nas.local' and 'known' are this machine
    connectHost = (name, port) {
      connected.add(name);
      if (refuse) return Socket.startConnect(InternetAddress.loopbackIPv4, 1); // (nothing listens on port 1)
      return Socket.startConnect(InternetAddress.loopbackIPv4, port);
    };
    HttpOverrides.global = LocalNames(); // (as main.dart sets it)
  });
  tearDown(() async {
    HttpOverrides.global = null;
    lookupHost = InternetAddress.lookup;
    connectHost = (host, port) => Socket.startConnect(host, port);
    await server.close(force: true);
  });

  test("a bare name the system doesn't know: connected to as name.local, by name - the request answered", () async {
    final r = await http.get(Uri.parse('http://nas:${server.port}/api/v2/users/me'));
    expect(r.body, 'komga');
    expect(asked, ['nas', 'nas.local']);
    expect(connected, ['nas.local'], reason: 'by name, not an address kept: every address tried, a new one found');
  });

  test('a bare name the system finds, a full name, an address: used as they are', () async {
    expect(await hostToConnect('known'), 'known');
    expect(asked, ['known'], reason: 'no .local asked for');
    expect(await hostToConnect('nas.example.com'), 'nas.example.com');
    expect(await hostToConnect('10.0.0.226'), '10.0.0.226');
    expect(asked, ['known']);
  });

  test('the choice is kept for the run: the next connection looks nothing up', () async {
    final names = LocalNames();
    HttpOverrides.global = names;
    for (var i = 0; i < 2; i++) {
      final c = HttpClient(); // (each its own connection)
      final rq = await c.getUrl(Uri.parse('http://nas:${server.port}/'));
      expect(await (await rq.close()).transform(const SystemEncoding().decoder).join(), 'komga');
      c.close(force: true);
    }
    expect(asked, ['nas', 'nas.local'], reason: 'looked up the first time only');
    expect(connected, ['nas.local', 'nas.local']);
  });

  // review, 2026-10-26: the experiment kept the first address found for the whole run - a NAS at a new address
  // stayed "unreachable" until the app was restarted
  test('a connection that fails forgets the choice: the next one looks again', () async {
    refuse = true;
    await expectLater(http.get(Uri.parse('http://nas:${server.port}/')), throwsA(anything));
    await Future<void>.delayed(Duration.zero);
    refuse = false;
    asked.clear();
    final r = await http.get(Uri.parse('http://nas:${server.port}/'));
    expect(r.body, 'komga');
    expect(asked, ['nas', 'nas.local'], reason: 'asked again');
  });
}
