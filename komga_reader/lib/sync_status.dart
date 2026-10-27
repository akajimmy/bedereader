import 'package:clock/clock.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// When this device last synced with Komga (Settings > Server & Sync > Sync - user, 2026-10-27: "Last Sync" and a
/// Sync now, for when something seems off): the last time Komga answered for the synced settings - reading settings,
/// series settings, pins, On deck hidden, the pairing - read from it or written to it (api.dart client settings).
/// Kept on this device, across restarts.
class SyncStatus extends ChangeNotifier {
  SyncStatus._();
  static final SyncStatus instance = SyncStatus._();

  static const _key = 'sync.last';

  /// Null: never (on this device).
  DateTime? last;

  Future<void> load() async {
    last = DateTime.tryParse((await SharedPreferences.getInstance()).getString(_key) ?? '')?.toLocal();
    notifyListeners();
  }

  /// Komga answered for the synced settings just now.
  void synced() {
    final now = last = clock.now();
    notifyListeners();
    // (this one's time: by the time the store is open, [last] may have moved on; not kept: no harm, nothing thrown -
    // a full run found a request's test without the store failing on it)
    SharedPreferences.getInstance()
        .then((p) => p.setString(_key, now.toUtc().toIso8601String()))
        .then<void>((_) {}, onError: (Object _) {});
  }

  /// Tests: never synced.
  @visibleForTesting
  void reset() => last = null;
}

/// [t] as Last Sync says it, against [now]: "Today, 14:05", "Yesterday, 09:30", else "27 Oct 2026, 14:05".
String syncTimeLabel(DateTime t, DateTime now) {
  String two(int n) => n.toString().padLeft(2, '0');
  final time = '${two(t.hour)}:${two(t.minute)}';
  final day = DateTime(t.year, t.month, t.day), today = DateTime(now.year, now.month, now.day);
  final days = today.difference(day).inDays;
  if (days == 0) return 'Today, $time';
  if (days == 1) return 'Yesterday, $time';
  const months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
  return '${t.day} ${months[t.month - 1]} ${t.year}, $time';
}
