import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:komga_reader/api.dart';

/// Builds a Komga (usually a fake) whose HTTP client fails the test on any call it makes.
///
/// [Komga] creates its `http.Client()` in a field initialiser; inside [http.runWithClient] that constructor returns
/// the client given there instead. So a fake built here has every method it doesn't override wired to a client that
/// refuses: the call throws a [TestFailure], and the failure is also reported to the test's zone directly, so the
/// test fails even when the app catches the error (most screens show it as text, settings sync retries quietly).
///
/// Before this, an un-overridden call went to `http://test` and came back as the test binding's HTTP 400 (or a DNS
/// failure in a plain `test`), which the app handled quietly: a test could pass on a path it was never meant to take
/// (test audit, 2026-09-30).
T noNetwork<T extends Komga>(T Function() create) => runZoned(
      () => http.runWithClient(create, () => MockClient(_refuse)),
      zoneValues: {_inNoNetwork: true},
    );

/// A plain [Komga] at [baseUrl] that fails the test on any network call (for widgets that only need an api to hold).
Komga plainKomga([String baseUrl = 'http://test']) => noNetwork(() => Komga(baseUrl, 'k'));

final _inNoNetwork = Object();

Future<http.Response> _refuse(http.Request request) async {
  final failure = TestFailure('unexpected network call: ${request.method} ${request.url.path} - the fake needs an '
      'override for it');
  Zone.current.handleUncaughtError(failure, StackTrace.current); // even if the app catches what's thrown below
  throw failure;
}

/// Base of every fake Komga in the tests: refuses to be built outside [noNetwork], so no fake can quietly fall
/// through to a real HTTP client. Build one with `noNetwork(MyFake.new)` (or `noNetwork(() => MyFake(...))`).
class TestKomga extends Komga {
  TestKomga([String baseUrl = 'http://test']) : super(baseUrl, 'k') {
    if (Zone.current[_inNoNetwork] != true) {
      throw StateError('$runtimeType built outside noNetwork(): its un-overridden calls would reach the network');
    }
  }
}
