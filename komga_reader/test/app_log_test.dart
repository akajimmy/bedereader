// The app's log (lib/app_log.dart) and the remote log (lib/remote_log.dart): kept across runs, queued only while the
// remote log is on, and sent to the collector as it answers (user, 2026-10-25: logging from the iPad; the collector on
// tt-fu.com, its answers agreed with the VPS session).
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:komga_reader/app_log.dart';
import 'package:komga_reader/remote_log.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  final log = AppLog.instance, remote = RemoteLog.instance;
  late List<List<String>> posted; // each request's messages
  late List<http.Response> answers; // what the collector answers, in turn (the last one again after)

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    log.reset();
    remote.reset();
    posted = [];
    answers = [http.Response('', 204)];
    String? token;
    RemoteLog.readToken = () async => token;
    RemoteLog.writeToken = (t) async => token = t;
    RemoteLog.client = () => MockClient((req) async {
          expect(req.headers['authorization'], 'Bearer k3y');
          final body = jsonDecode(req.body) as Map;
          expect(body['device'], 'ipad-air');
          posted.add([for (final l in body['lines'] as List) '${l['msg']}']);
          return answers.length > 1 ? answers.removeAt(0) : answers.first;
        });
  });
  tearDown(() {
    log.reset();
    remote.reset();
  });

  Future<void> configure() => remote.set(on: true, url: 'https://log.test/v1/lines', device: 'iPad Air', token: 'k3y');

  test('lines are queued to send only while the remote log is on; the log and the queue are kept across runs',
      () async {
    final dir = await Directory.systemTemp.createTemp('app_log');
    addTearDown(() async {
      await log.written;
      await dir.delete(recursive: true);
    });
    await log.load(dir);
    log.info('app', 'before');
    expect(log.outbox, isEmpty, reason: 'off: nothing leaves the device');
    await configure();
    log.warn('reader', 'queued');
    log.add(LogLevel.crash, 'app', 'x' * 3000);
    expect(log.outbox.map((l) => l.msg.length), [6, 6, lessThan(2100)],
        reason: "this run's line from before it was on too; a long message cut");
    await log.save();

    log.reset();
    await log.load(dir);
    expect(log.recent.map((l) => l.tag), ['app', 'reader', 'app']);
    expect(log.outbox.map((l) => l.level), [LogLevel.info, LogLevel.warn, LogLevel.crash], reason: 'unsent: still to send');
  });

  test("turned on during a run, this run's lines so far are sent too - the start-up ones came before it could be "
      "turned on - each once, however often it's turned on and off; earlier runs' lines are not", () async {
    final dir = await Directory.systemTemp.createTemp('app_log_run');
    addTearDown(() async {
      await log.written;
      await dir.delete(recursive: true);
    });
    log.info('app', 'last run');
    await log.save(); // (no folder yet: nothing written)
    await log.load(dir);
    log.info('app', 'old');
    await log.save();
    log.reset();
    await log.load(dir); // a new run: "old" is an earlier run's
    log.info('app', 'started');
    log.info('storage', 'kept out of iCloud backup');
    expect(log.outbox, isEmpty, reason: 'off');
    await configure();
    expect(log.outbox.map((l) => l.msg), ['started', 'kept out of iCloud backup']);
    await remote.set(on: false);
    await remote.set(on: true);
    log.info('app', 'later');
    expect(log.outbox.map((l) => l.msg), ['started', 'kept out of iCloud backup', 'later'], reason: 'not twice');
  });

  test('leaving the app and coming back are logged on a phone or tablet only - on Windows they are just the window '
      'losing and getting the focus (user, 2026-10-25: "drop it on windows")', () {
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    for (final p in [TargetPlatform.windows, TargetPlatform.iOS, TargetPlatform.android]) {
      debugDefaultTargetPlatformOverride = p;
      log.lifecycle('back');
    }
    expect(log.recent.length, 2, reason: 'iOS and Android, not Windows');
  });

  test("sent oldest first in batches; what's stored leaves the queue, and the device's name is made clean", () async {
    await configure();
    for (var i = 0; i < 1200; i++) {
      log.info('t', '$i');
    }
    expect(await remote.sendNow(), isTrue);
    expect(posted.map((p) => p.length), [RemoteLog.batch, RemoteLog.batch, 200]);
    expect(posted.first.first, '0');
    expect(log.outbox, isEmpty);
    expect(remote.device, 'ipad-air');
  });

  test('400: the batch the collector cannot read is dropped, not sent again', () async {
    await configure();
    log.info('t', 'bad');
    answers = [http.Response('', 400), http.Response('', 204)];
    expect(await remote.sendNow(), isTrue);
    expect(log.outbox, isEmpty);
    expect(await remote.sendNow(), isTrue);
    expect(posted, [['bad']], reason: 'never sent again');
  });

  test('401: the key refused - nothing more is sent until the settings change', () async {
    await configure();
    log.info('t', 'a');
    answers = [http.Response('', 401)];
    expect(await remote.sendNow(), isFalse);
    expect(await remote.sendNow(), isFalse);
    expect(posted.length, 1, reason: 'not sent again with the refused key');
    expect(log.outbox.length, 1, reason: 'kept, for when a key works');
    answers = [http.Response('', 204)];
    await remote.set(token: 'k3y');
    expect(await remote.sendNow(), isTrue);
    expect(log.outbox, isEmpty);
  });

  test('413: too big - split in half; a line too big on its own dropped', () async {
    await configure();
    for (var i = 0; i < 4; i++) {
      log.info('t', '$i');
    }
    answers = [http.Response('', 413), http.Response('', 204)];
    expect(await remote.sendNow(), isTrue);
    expect(posted.map((p) => p.length), [4, 2, 2]);

    posted.clear();
    log.info('t', 'huge');
    answers = [http.Response('', 413)];
    expect(await remote.sendNow(), isTrue);
    expect(log.outbox, isEmpty, reason: 'dropped, not sent forever');
  });

  test("429: the collector's Retry-After is waited out; no answer at all: the lines are kept for later", () async {
    await configure();
    log.info('t', 'a');
    answers = [http.Response('', 429, headers: {'retry-after': '600'})];
    expect(await remote.sendNow(), isFalse);
    expect(remote.status, contains('10 min'));
    expect(log.outbox.length, 1);

    RemoteLog.client = () => MockClient((_) async => throw const SocketException('no route'));
    expect(await remote.sendNow(), isFalse);
    expect(log.outbox.length, 1);
  });
}
