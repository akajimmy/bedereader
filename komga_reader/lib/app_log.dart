import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:clock/clock.dart';
import 'package:flutter/foundation.dart';

/// How much a log line matters. [crash]: an error nothing caught (the app may be in a bad state after it).
enum LogLevel { info, warn, error, crash }

/// One line of the app's log.
class LogLine {
  const LogLine(this.t, this.level, this.tag, this.msg);
  final DateTime t;
  final LogLevel level;
  final String tag; // where it's from: "app", "reader", "connection", "downloads"...
  final String msg;

  Map<String, dynamic> toJson() => {'t': t.toUtc().toIso8601String(), 'level': level.name, 'tag': tag, 'msg': msg};

  static LogLine? fromJson(Object? j) {
    if (j is! Map) return null;
    final t = DateTime.tryParse('${j['t']}'), level = LogLevel.values.asNameMap()[j['level']];
    if (t == null || level == null) return null;
    return LogLine(t.toLocal(), level, '${j['tag']}', '${j['msg']}');
  }

  /// "13:12:05.120 error [reader] ..." - as the log screen and Copy show it.
  String get asText {
    String two(int n) => n.toString().padLeft(2, '0');
    final ms = t.millisecond.toString().padLeft(3, '0');
    return '${two(t.hour)}:${two(t.minute)}:${two(t.second)}.$ms ${level.name.padRight(5)} [$tag] $msg';
  }
}

/// What the app did, newest last: the last [keep] lines, kept on the device (Settings > About > App log) so a problem
/// can be looked at after the app was closed - and, while the remote log is on (lib/remote_log.dart), each line also
/// queued to be sent ([outbox]), kept until it's sent (user, 2026-10-25: logging from the iPad, which has no console
/// this PC can read).
class AppLog extends ChangeNotifier {
  AppLog._();
  static final AppLog instance = AppLog._();

  static const keep = 2000; // (a page turn is a line: a few hours of reading)
  static const outboxCap = 5000; // a collector out of reach for days: the oldest unsent lines go first
  static const maxMessage = 2000;

  final List<LogLine> recent = [];
  final List<LogLine> outbox = [];

  /// Lines also go to [outbox] (the remote log is on).
  bool collecting = false;

  Directory? _dir;
  bool _writing = false, _again = false;

  /// The log kept in [dir] (the app's storage, logs\): what was there before this run read back.
  Future<void> load(Directory dir) async {
    _dir = dir;
    final before = [...recent], queued = [...outbox];
    recent
      ..clear()
      ..addAll(await _read('recent.jsonl'))
      ..addAll(before);
    outbox
      ..clear()
      ..addAll(await _read('outbox.jsonl'))
      ..addAll(queued);
    _trim();
    notifyListeners();
  }

  void info(String tag, String msg) => add(LogLevel.info, tag, msg);
  void warn(String tag, String msg) => add(LogLevel.warn, tag, msg);
  void error(String tag, String msg) => add(LogLevel.error, tag, msg);
  void crash(String tag, String msg) => add(LogLevel.crash, tag, msg);

  void add(LogLevel level, String tag, String msg) {
    final line = LogLine(clock.now(), level, tag,
        msg.length > maxMessage ? '${msg.substring(0, maxMessage)}… (${msg.length} characters)' : msg);
    recent.add(line);
    if (collecting) outbox.add(line);
    _trim();
    notifyListeners();
    _saveSoon();
  }

  /// Written now, or right after the write under way (lines come a few a minute; no timer to leave behind).
  void _saveSoon() {
    if (_dir == null) return; // (kept nowhere: nothing to write)
    if (_writing) {
      _again = true;
      return;
    }
    _writing = true;
    save().whenComplete(() {
      _writing = false;
      if (_again) {
        _again = false;
        _saveSoon();
      }
    });
  }

  /// The app left or come back to ("to the background", "back") - on a phone or tablet only, where the system may
  /// then freeze or end the app (a gap in the log, a failure just after coming back, a run that ended without a
  /// crash). On Windows it's only the window losing or getting the focus, a line each time the user switches windows
  /// (user, 2026-10-25: "drop it on windows").
  void lifecycle(String what) {
    if (defaultTargetPlatform == TargetPlatform.iOS || defaultTargetPlatform == TargetPlatform.android) {
      info('app', what);
    }
  }

  /// The first [n] lines of [outbox] were sent.
  void sent(int n) {
    outbox.removeRange(0, n.clamp(0, outbox.length));
    notifyListeners();
    _saveSoon();
  }

  /// The lines on screen are cleared (the unsent ones stay queued).
  void clear() {
    recent.clear();
    notifyListeners();
    _saveSoon();
  }

  void _trim() {
    if (recent.length > keep) recent.removeRange(0, recent.length - keep);
    if (outbox.length > outboxCap) outbox.removeRange(0, outbox.length - outboxCap);
  }

  /// Written now (also done by itself a few seconds after a line, and when the app goes to the background).
  Future<void> save() async {
    final dir = _dir;
    if (dir == null) return;
    try {
      await dir.create(recursive: true);
      await _write('recent.jsonl', recent);
      await _write('outbox.jsonl', outbox);
    } catch (_) {
      // the log is a help, not something to fail over
    }
  }

  Future<List<LogLine>> _read(String name) async {
    try {
      final f = File('${_dir!.path}${Platform.pathSeparator}$name');
      if (!await f.exists()) return [];
      return [
        for (final l in await f.readAsLines())
          if (LogLine.fromJson(_decode(l)) case final line?) line,
      ];
    } catch (_) {
      return [];
    }
  }

  static Object? _decode(String l) {
    try {
      return jsonDecode(l);
    } catch (_) {
      return null;
    }
  }

  Future<void> _write(String name, List<LogLine> lines) async {
    final sep = Platform.pathSeparator;
    final tmp = File('${_dir!.path}$sep$name.tmp');
    await tmp.writeAsString(lines.map((l) => jsonEncode(l.toJson())).join('\n'), flush: true);
    await tmp.rename('${_dir!.path}$sep$name');
  }

  /// Tests: empty, kept nowhere, not collecting.
  @visibleForTesting
  void reset() {
    _dir = null;
    recent.clear();
    outbox.clear();
    collecting = false;
    _writing = _again = false;
  }
}
