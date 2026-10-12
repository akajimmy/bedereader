import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'api.dart';
import 'errors.dart';

/// A highlight in an eBook: a chapter (its file in the book) and the stretch of its text, in chapter positions - the
/// same in every layout, font and page size - with the words themselves (for a list, and to see it's still right).
@immutable
class Highlight {
  const Highlight(this.chapter, this.start, this.end, this.text);
  final String chapter;
  final int start, end;
  final String text;

  bool overlaps(String inChapter, int from, int to) => inChapter == chapter && from < end && to > start;

  Map<String, dynamic> toJson() => {'c': chapter, 's': start, 'e': end, 't': text};
  static Highlight? fromJson(Object? j) {
    if (j is! Map) return null;
    final c = j['c'], s = j['s'], e = j['e'];
    if (c is! String || s is! int || e is! int || e <= s) return null;
    return Highlight(c, s, e, j['t'] is String ? j['t'] as String : '');
  }

  @override
  bool operator ==(Object other) =>
      other is Highlight && other.chapter == chapter && other.start == start && other.end == end;
  @override
  int get hashCode => Object.hash(chapter, start, end);
}

/// [marks] in reading order: by their chapter's place in the book ([spine]), then where in it - not by file name
/// (ch10 came before ch2 in the Contents list - audit, 2026-10-11).
List<Highlight> inReadingOrder(List<Highlight> marks, List<String> spine) => [...marks]..sort((x, y) {
    final cx = spine.indexOf(x.chapter), cy = spine.indexOf(y.chapter);
    return cx != cy ? cx - cy : x.start - y.start;
  });

/// One book's highlights (user, 2026-10-11: one colour, synced through Komga - no notes yet). Kept in the user's
/// Komga client-settings store, a key per book, so the tablet and the PC share them; a copy on the device, so they
/// show at once and offline. A change made here wins: it's saved on the device and sent, and sent again every minute
/// until Komga has it (as pins are).
class BookHighlights extends ChangeNotifier {
  BookHighlights(this.api, this.bookId);
  final Komga api;
  final String bookId;

  String get komgaKey => 'komgareader.highlights.$bookId';
  String get _local => 'highlights.$bookId';
  String get _dirty => 'highlights.$bookId.unsent';

  List<Highlight> items = const [];
  Timer? _retry;
  bool _disposed = false;

  /// A failed send will be tried again (tests).
  @visibleForTesting
  bool get retrying => _retry?.isActive ?? false;

  static List<Highlight> _decode(String raw) {
    try {
      return [for (final j in jsonDecode(raw) as List) Highlight.fromJson(j)].whereType<Highlight>().toList();
    } catch (_) {
      return const [];
    }
  }

  String get _raw => jsonEncode([for (final h in items) h.toJson()]);

  /// This device's copy, then Komga's (unless a change made here hasn't reached it: that's sent instead).
  Future<void> load() async {
    final p = await SharedPreferences.getInstance();
    final raw = p.getString(_local);
    if (raw != null) _set(_decode(raw));
    if (p.getBool(_dirty) ?? false) {
      await _send();
      return;
    }
    try {
      final remote = (await api.clientSettings())[komgaKey]?['value'];
      if (_disposed || (p.getBool(_dirty) ?? false)) return; // highlighted here meanwhile: that goes to Komga
      if (remote is String) {
        _set(_decode(remote));
        await p.setString(_local, _raw);
      }
    } catch (e) {
      // offline, or Komga not answering: this device's copy stands
    }
  }

  /// Highlights [h] - taking in any it overlaps (one highlight from the start of the first to the end of the last).
  Future<void> add(Highlight h) {
    var start = h.start, end = h.end;
    final keep = <Highlight>[];
    for (final o in items) {
      if (o.overlaps(h.chapter, start, end)) {
        start = start < o.start ? start : o.start;
        end = end > o.end ? end : o.end;
      } else {
        keep.add(o);
      }
    }
    final text = start == h.start && end == h.end ? h.text : _joined(h, start, end);
    return _change([...keep, Highlight(h.chapter, start, end, text)]);
  }

  /// [h]'s words when it grew into others it overlapped: its own, ends marked as more.
  static String _joined(Highlight h, int start, int end) =>
      '${start < h.start ? '… ' : ''}${h.text}${end > h.end ? ' …' : ''}';

  Future<void> remove(Highlight h) => _change([for (final o in items) if (o != h) o]);

  /// The highlights in [chapter] touching [from]..[to].
  List<Highlight> within(String chapter, int from, int to) =>
      [for (final h in items) if (h.overlaps(chapter, from, to)) h];

  Future<void> _change(List<Highlight> next) async {
    _set(next);
    final p = await SharedPreferences.getInstance();
    await p.setString(_local, _raw);
    await p.setBool(_dirty, true); // until Komga has it
    await _send();
  }

  void _set(List<Highlight> next) {
    // (a copy sorted: [_decode]'s empty list can't be - a damaged saved value threw - audit, 2026-10-11)
    items = List.unmodifiable([...next]..sort((a, b) =>
        a.chapter != b.chapter ? a.chapter.compareTo(b.chapter) : a.start - b.start));
    if (!_disposed) notifyListeners();
  }

  bool _sending = false, _again = false, _noted = false;

  Future<void> _send() async {
    if (_sending) {
      _again = true;
      return;
    }
    _sending = true;
    _retry?.cancel();
    final p = await SharedPreferences.getInstance();
    try {
      await api.putClientSetting(komgaKey, _raw);
      if (!_again) await p.setBool(_dirty, false);
      _noted = false;
    } catch (e) {
      if (!_noted) ErrorLog.instance.record('Highlights saved on this device, not on Komga yet: ${explain(e).reason}.', e);
      _noted = true; // (once, not every minute)
      if (!_disposed) _retry = Timer(const Duration(minutes: 1), _send);
    } finally {
      _sending = false;
    }
    if (_again) {
      _again = false;
      await _send();
    }
  }

  @override
  void dispose() {
    if (_disposed) return; // (once)
    _disposed = true;
    _retry?.cancel();
    super.dispose();
  }
}
