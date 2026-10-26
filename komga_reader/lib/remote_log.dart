import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:clock/clock.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import 'app_log.dart';
import 'screen.dart' show appVersionInfo;

/// The remote log (Settings > About > Remote log; off by default): the app's log lines ([AppLog]) sent to a collector
/// on the user's server, so they can be read from the PC wherever the device is - the iPad above all, whose own log
/// this PC can't read (user, 2026-10-25). Kept on this device: on or off, the collector's address, this device's name
/// in the logs, and its key (encrypted, like Komga's API key).
///
/// Lines are queued while it's on and sent in batches every [every], oldest first; unsent ones are kept (also across
/// restarts) and sent when the collector answers again, waiting longer after each failure (up to [longestWait]).
/// A refused key stops the sending until the settings change.
class RemoteLog extends ChangeNotifier {
  RemoteLog._();
  static final RemoteLog instance = RemoteLog._();

  static const every = Duration(seconds: 30);
  static const longestWait = Duration(minutes: 15);
  static const batch = 500;

  static const _on = 'remoteLog.on', _url = 'remoteLog.url', _device = 'remoteLog.device', _token = 'remoteLogToken';
  static const _secure = FlutterSecureStorage();

  /// Tests: the HTTP client, and the key store.
  @visibleForTesting
  static http.Client Function() client = http.Client.new;
  @visibleForTesting
  static Future<String?> Function() readToken = () => _secure.read(key: _token);
  @visibleForTesting
  static Future<void> Function(String) writeToken = (t) => _secure.write(key: _token, value: t);

  bool on = false;
  String url = '';
  String device = defaultDevice;
  bool hasToken = false;
  String? _tokenValue;

  /// What happened last ("Sent 12 lines at 13:12", "The collector refused the key"...), for Settings.
  String status = '';
  bool _refused = false;
  bool _sending = false;
  Duration _wait = every;
  Timer? _timer;

  static String get defaultDevice => switch (defaultTargetPlatform) {
        TargetPlatform.iOS => 'ios',
        TargetPlatform.android => 'android',
        TargetPlatform.windows => 'windows',
        _ => defaultTargetPlatform.name,
      };

  Future<void> load() async {
    final p = await SharedPreferences.getInstance();
    on = p.getBool(_on) ?? false;
    url = p.getString(_url) ?? '';
    device = p.getString(_device) ?? defaultDevice;
    try {
      _tokenValue = await readToken();
    } catch (_) {
      _tokenValue = null;
    }
    hasToken = (_tokenValue ?? '').isNotEmpty;
    _apply();
  }

  /// New settings ([token] null: the key kept as it is).
  Future<void> set({bool? on, String? url, String? device, String? token}) async {
    final p = await SharedPreferences.getInstance();
    if (on != null) await p.setBool(_on, this.on = on);
    if (url != null) await p.setString(_url, this.url = url.trim());
    if (device != null) {
      final name = clean(device);
      await p.setString(_device, this.device = name.isEmpty ? defaultDevice : name);
    }
    if (token != null) {
      _tokenValue = token.trim();
      hasToken = _tokenValue!.isNotEmpty;
      try {
        await writeToken(_tokenValue!);
      } catch (_) {}
    }
    _refused = false;
    _wait = every;
    status = '';
    _apply();
  }

  /// A device's name as the collector keeps it: letters, digits and dashes.
  static String clean(String name) =>
      name.trim().toLowerCase().replaceAll(RegExp(r'[^a-z0-9-]+'), '-').replaceAll(RegExp(r'^-+|-+$'), '');

  bool get _ready => on && url.isNotEmpty && hasToken;

  void _apply() {
    AppLog.instance.collecting = on;
    _timer?.cancel();
    _timer = null;
    if (_ready && !_refused) _later(every);
    notifyListeners();
  }

  void _later(Duration d) {
    _timer?.cancel();
    _timer = Timer(d, () async {
      _timer = null;
      final ok = await sendNow();
      if (_ready && !_refused) _later(ok ? every : _wait);
    });
  }

  /// A batch's body is kept under this (the collector takes 256 KB).
  static const maxBody = 200 * 1024;

  /// Sends what's queued, in batches; true if everything queued went (or nothing was). What the collector answers
  /// (tt-fu.com's, agreed with the VPS session 2026-10-25): 204 stored; 400 a batch it can't read - dropped, never
  /// sent again (sent again, it would be refused forever); 401/403 the key refused - nothing more until the settings
  /// change; 413 too big - split in half, a single line too big alone dropped; 429 too much (a rate limit, today's
  /// cap) - waits the Retry-After it gives; anything else, or no answer - waits longer each time, with some jitter.
  Future<bool> sendNow() async {
    if (!_ready || _refused || _sending) return false;
    _sending = true;
    final c = client();
    try {
      final version = await appVersionInfo();
      var total = 0, dropped = 0;
      var limit = batch;
      while (AppLog.instance.outbox.isNotEmpty) {
        final lines = _take(limit);
        final r = await c
            .post(Uri.parse(url), headers: {
              'Authorization': 'Bearer $_tokenValue',
              'Content-Type': 'application/json',
            }, body: _body(lines, version))
            .timeout(const Duration(seconds: 20));
        switch (r.statusCode) {
          case >= 200 && < 300:
            AppLog.instance.sent(lines.length);
            total += lines.length;
            limit = batch;
          case 400:
            AppLog.instance.sent(lines.length); // (dropped: unreadable to the collector, now or ever)
            dropped += lines.length;
          case 401 || 403:
            _refused = true;
            _say('The collector refused the key');
            return false;
          case 413:
            if (lines.length == 1) {
              AppLog.instance.sent(1);
              dropped++;
            } else {
              limit = lines.length ~/ 2;
            }
          case 429:
            final after = int.tryParse(r.headers['retry-after'] ?? '');
            _wait = Duration(seconds: (after ?? every.inSeconds).clamp(1, 24 * 3600));
            _say('The collector asks to wait (${_time(clock.now())}) - trying again in ${_inWords(_wait)}');
            return false;
          default:
            _failed('The collector answered ${r.statusCode}');
            return false;
        }
      }
      _wait = every;
      if (total > 0 || dropped > 0) {
        _say('Sent $total line${total == 1 ? '' : 's'} at ${_time(clock.now())}'
            '${dropped > 0 ? ' ($dropped refused as unreadable)' : ''}');
      }
      return true;
    } catch (e) {
      _failed("Couldn't reach the collector");
      return false;
    } finally {
      c.close();
      _sending = false;
    }
  }

  /// The oldest queued lines, at most [limit] of them, and no more than fit under [maxBody] (at least one).
  List<LogLine> _take(int limit) {
    final out = <LogLine>[];
    var size = 512; // (the rest of the body)
    for (final l in AppLog.instance.outbox) {
      if (out.length >= limit) break;
      final n = utf8.encode(jsonEncode(l.toJson())).length + 1;
      if (out.isNotEmpty && size + n > maxBody) break;
      out.add(l);
      size += n;
    }
    return out;
  }

  String _body(List<LogLine> lines, (String, int)? version) => jsonEncode({
        'device': device,
        'platform': defaultTargetPlatform.name,
        'app': version?.$1,
        'build': version?.$2,
        'lines': [for (final l in lines) l.toJson()],
      });

  void _failed(String why) {
    final doubled = _wait * 2 > longestWait ? longestWait : _wait * 2;
    // jitter: up to a fifth more, so devices that lost the collector together don't all come back at once
    _wait = doubled + Duration(milliseconds: _random.nextInt(doubled.inMilliseconds ~/ 5 + 1));
    _say('$why (${_time(clock.now())}) - trying again in ${_inWords(_wait)}');
  }

  static final _random = Random();

  static String _inWords(Duration d) => d.inMinutes > 0 ? '${d.inMinutes} min' : '${d.inSeconds} s';

  void _say(String s) {
    status = s;
    notifyListeners();
  }

  static String _time(DateTime t) => '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';

  /// Tests: off, nothing kept, no timer.
  @visibleForTesting
  void reset() {
    _timer?.cancel();
    _timer = null;
    on = false;
    url = '';
    device = defaultDevice;
    hasToken = false;
    _tokenValue = null;
    status = '';
    _refused = false;
    _sending = false;
    _wait = every;
  }
}
