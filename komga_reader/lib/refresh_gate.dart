import 'package:flutter/foundation.dart';

/// Fetching a synced thing (pins, reader settings, On deck hidden) from Komga again when Home reloads, so changes
/// made on another device arrive without restarting the app (user, 2026-10-05). Several reloads come in a row (going
/// online rebuilds Home, and Home reloads as it comes back): one fetch at a time, and none within [gap] of the last.
class RefreshGate {
  @visibleForTesting
  static Duration gap = const Duration(seconds: 10);

  DateTime? _at; // the last time Komga was asked
  Future<void>? _running;

  /// Komga was asked just now (a start-up load counts too).
  void asked() => _at = DateTime.now();

  /// Runs [fetch] unless one is running (that one's answer is shared) or the last ask was within [gap].
  Future<void> run(Future<void> Function() fetch) {
    final running = _running;
    if (running != null) return running;
    final at = _at;
    if (at != null && DateTime.now().difference(at) < gap) return Future.value();
    return _running = fetch().whenComplete(() => _running = null);
  }
}
