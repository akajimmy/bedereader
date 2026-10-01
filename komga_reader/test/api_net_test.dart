import 'dart:async';
import 'dart:io' show HandshakeException;

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:komga_reader/api.dart';

/// How the server client sorts what comes back (Komga._net): each failure becomes one of the app's errors, and the
/// connection is told whether Komga answered - which is what raises "can't reach Komga" and the switch to the
/// downloaded books. The real [Komga] here, its HTTP client a package:http MockClient (no network).
void main() {
  final events = <String>[]; // what the connection was told, in order

  setUp(() {
    events.clear();
    Komga.onReachability = (api, reachable) => events.add(reachable ? 'answered' : 'unreachable');
    Komga.onKeyRefused = (api) => events.add('key refused');
  });
  tearDown(() {
    Komga.onReachability = null;
    Komga.onKeyRefused = null;
  });

  /// The app's own client, answering with [handler].
  Komga komga(MockClientHandler handler) =>
      http.runWithClient(() => Komga('http://komga.test:25600', 'key'), () => MockClient(handler));

  Future<http.Response> status(int code, [String body = '']) async => http.Response(body, code);
  Future<http.Response> never(http.Request _) => Completer<http.Response>().future; // no answer, ever

  /// The error [call] ends with (null: none).
  Future<Object?> errorOf(Future<Object?> Function() call) async {
    try {
      await call();
      return null;
    } catch (e) {
      return e;
    }
  }

  test('an answer: the result, and the connection hears Komga answered', () async {
    final api = komga((r) async => http.Response('{"id": "U1"}', 200));
    expect((await api.me())!['id'], 'U1');
    expect(events, ['answered']);
  });

  testWidgets("no answer within the time limit: KomgaUnreachable, and Komga is reported unreachable", (tester) async {
    final api = komga(never);
    Object? error;
    unawaited(api.me().then((_) {}, onError: (Object e) => error = e));
    await tester.pump(Komga.timeout - const Duration(seconds: 1));
    expect(error, isNull, reason: 'still waiting inside the limit');
    await tester.pump(const Duration(seconds: 2));
    expect(error, isA<KomgaUnreachable>());
    expect(events, ['unreachable']);
  });

  testWidgets('slowIsNotDown: a page or page preview running out of time fails on its own - Komga is not reported '
      'unreachable (no prompt, no switch to offline)', (tester) async {
    final api = komga(never);
    Object? page, thumb;
    unawaited(api.pageBytes('B1', 1).then((_) {}, onError: (Object e) => page = e));
    unawaited(api.pageThumbBytes('B1', 1).then((_) {}, onError: (Object e) => thumb = e));
    await tester.pump(Komga.timeout + const Duration(seconds: 1));
    expect(thumb, isA<KomgaUnreachable>(), reason: 'a preview has the ordinary limit');
    expect(page, isNull, reason: 'a page has the longer one');
    await tester.pump(Komga.pageTimeout - Komga.timeout);
    expect(page, isA<KomgaUnreachable>());
    expect(events, isEmpty, reason: 'slow is not down');
  });

  test("a socket error (refused, no route) is \"can't reach\" - for a page too: slowIsNotDown is only about time",
      () async {
    final api = komga((r) async => throw http.ClientException('Connection refused', r.url));
    expect(await errorOf(api.me), isA<KomgaUnreachable>());
    expect(await errorOf(() => api.pageBytes('B1', 1)), isA<KomgaUnreachable>());
    expect(events, ['unreachable', 'unreachable']);
  });

  test('401: the key is refused - said before "it answered", so the connection never offers to go back', () async {
    final api = komga((r) => status(401));
    final e = await errorOf(api.me);
    expect(e, isA<KomgaError>().having((e) => e.status, 'status', 401));
    expect(events, ['key refused', 'answered']);
  });

  test('403: an error from Komga, but not a refused key (no key prompt)', () async {
    final api = komga((r) => status(403));
    expect(await errorOf(() => api.setProgress('B1', 2)), isA<KomgaError>().having((e) => e.status, 'status', 403));
    expect(await errorOf(api.libraries), isA<KomgaError>().having((e) => e.status, 'status', 403));
    expect(events, ['answered', 'answered']);
  });

  test("404: a thing that isn't there - null where the call allows it, KomgaError 404 where it doesn't; Komga "
      'answered', () async {
    final api = komga((r) => status(404));
    expect(await api.book('B1'), isNull);
    expect(await api.oneSeries('S1'), isNull);
    expect(await errorOf(() => api.seriesBooks('S1')), isA<KomgaError>().having((e) => e.status, 'status', 404));
    expect(await errorOf(() => api.markRead('B1')), isA<KomgaError>().having((e) => e.status, 'status', 404));
    expect(events, everyElement('answered'));
    expect(events, hasLength(4));
  });

  test("5xx: Komga's own error - KomgaError with the status, and Komga is reachable (not \"can't reach\")", () async {
    for (final code in [500, 502, 503]) {
      events.clear();
      final api = komga((r) => status(code));
      expect(await errorOf(api.me), isA<KomgaError>().having((e) => e.status, 'status', code), reason: '$code');
      expect(events, ['answered'], reason: '$code');
    }
  });

  test('a web page instead of the API (wrong port, a router): KomgaNotKomga, and nothing usable answered', () async {
    final api = komga((r) => status(200, '<html><body>Router login</body></html>'));
    expect(await errorOf(api.libraries), isA<KomgaNotKomga>());
    expect(events, ['unreachable']);
  });

  test("https with a certificate this device doesn't trust: KomgaCertificate, reported unreachable", () async {
    final api = komga((r) async => throw const HandshakeException('CERTIFICATE_VERIFY_FAILED: self signed'));
    expect(await errorOf(api.me), isA<KomgaCertificate>());
    expect(events, ['unreachable']);
  });
}
