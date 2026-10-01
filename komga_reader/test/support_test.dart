import 'dart:async';

import 'package:flutter_test/flutter_test.dart';

import 'support/helpers.dart';
import 'support/no_network.dart';

/// Answers libraries(); everything else is left to the real client.
class _LibrariesOnly extends TestKomga {
  @override
  Future<List<dynamic>> libraries() async => [{'id': 'L1'}];
}

/// Runs [body] in a zone that collects what is reported to it as uncaught (what would fail the test).
Future<List<Object>> reported(Future<void> Function() body) async {
  final errors = <Object>[];
  final done = Completer<void>();
  unawaited(runZonedGuarded(() async {
    try {
      await body();
    } finally {
      done.complete();
    }
  }, (e, _) => errors.add(e)));
  await done.future;
  return errors;
}

/// The test support itself (test audit, 2026-09-30): a fake built through noNetwork fails the test on any call it
/// doesn't override - even when the app catches the error - and can't be built any other way; waitUntil fails on
/// timeout instead of returning quietly.
void main() {
  test('noNetwork: an overridden call answers as usual', () async {
    final api = noNetwork(_LibrariesOnly.new);
    expect(await api.libraries(), [{'id': 'L1'}]);
  });

  test('noNetwork: a call the fake does not override throws a TestFailure naming it', () async {
    final api = noNetwork(_LibrariesOnly.new);
    late Object thrown;
    final errors = await reported(() async {
      try {
        await api.oneSeries('S1');
      } catch (e) {
        thrown = e;
      }
    });
    expect(thrown, isA<TestFailure>().having((f) => f.message, 'message', contains('GET /api/v1/series/S1')));
    expect(errors, [isA<TestFailure>()], reason: 'reported to the test as well');
  });

  test('noNetwork: the test still fails when the app swallows the error', () async {
    final api = noNetwork(_LibrariesOnly.new);
    final errors = await reported(() async {
      try {
        await api.putClientSetting('k', 'v'); // what settings sync does: catch, retry later
      } catch (_) {}
    });
    expect(errors.single, isA<TestFailure>()
        .having((f) => f.message, 'message', contains('unexpected network call: PATCH /api/v1/client-settings/user')));
  });

  test('a plain Komga built through noNetwork refuses too', () async {
    final errors = await reported(() async {
      await expectLater(plainKomga().me(), throwsA(isA<TestFailure>()));
    });
    expect(errors, hasLength(1));
  });

  test('a fake built outside noNetwork refuses to exist', () {
    expect(_LibrariesOnly.new, throwsA(isA<StateError>()));
  });

  test('waitUntil returns as soon as the condition holds, and fails with the reason when it never does', () async {
    var n = 0;
    await waitUntil(() => ++n >= 3, timeout: const Duration(seconds: 1));
    expect(n, 3);
    await expectLater(waitUntil(() => false, timeout: const Duration(milliseconds: 100), reason: 'the queue settles'),
        throwsA(isA<TestFailure>().having((f) => f.message, 'message', contains('the queue settles'))));
  });
}
