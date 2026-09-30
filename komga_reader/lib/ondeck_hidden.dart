import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'api.dart';

/// Series and books left out of On deck (book / series menu > "Hide from On deck"). Komga has no such setting, so
/// the app keeps the list and filters On deck with it:
/// - a **series** never shows there;
/// - a **book** is skipped - its series stays out of On deck until that book is read, then the next one shows.
/// Kept on the device and in the user's Komga client settings (like pins), so every device agrees.
class OnDeckHidden extends ChangeNotifier {
  OnDeckHidden._();
  static final OnDeckHidden instance = OnDeckHidden._();

  static const komgaKey = 'komgareader.ondeckhidden';
  static const _local = 'ondeck.hidden';
  static const _dirtyKey = 'ondeck.hidden.unsent'; // changed while Komga couldn't be reached

  Komga? _api;
  Set<String> series = {}, books = {};

  bool get isEmpty => series.isEmpty && books.isEmpty;
  int get count => series.length + books.length;

  Future<void> load(Komga api) async {
    _api = api;
    final p = await SharedPreferences.getInstance();
    final raw = p.getString(_local);
    if (raw != null) _decode(raw);
    notifyListeners();
    try {
      if (p.getBool(_dirtyKey) ?? false) {
        await _send(p); // this device's changes haven't reached Komga: they win
        return;
      }
      final remote = (await api.clientSettings())[komgaKey]?['value'];
      if (remote is String) {
        _decode(remote);
        await p.setString(_local, remote);
        notifyListeners();
      }
    } catch (_) {
      // offline / not reachable: the device's copy stands
    }
  }

  /// Switch connection (online / offline) without reloading.
  void useApi(Komga api) => _api = api;

  bool seriesHidden(String? id) => id != null && series.contains(id);
  bool bookHidden(String? id) => id != null && books.contains(id);

  /// Whether an On deck entry (a book) should be left out.
  bool hides(dynamic book) => bookHidden(book['id'] as String?) || seriesHidden(book['seriesId'] as String?);

  void setSeries(String id, bool hidden) => _change(() => hidden ? series.add(id) : series.remove(id));
  void setBook(String id, bool hidden) => _change(() => hidden ? books.add(id) : books.remove(id));
  void clear() => _change(() { series.clear(); books.clear(); });

  String get _raw => jsonEncode({'series': series.toList(), 'books': books.toList()});

  void _change(void Function() f) {
    f();
    notifyListeners();
    SharedPreferences.getInstance().then((p) async {
      await p.setString(_local, _raw);
      await _send(p);
    });
  }

  /// To Komga; if it can't be reached the change is flagged and sent at the next start-up.
  Future<void> _send(SharedPreferences p) async {
    final api = _api;
    try {
      if (api == null) throw StateError('no server');
      await api.putClientSetting(komgaKey, _raw);
      await p.setBool(_dirtyKey, false);
    } catch (_) {
      await p.setBool(_dirtyKey, true);
    }
  }

  void _decode(String raw) {
    try {
      final j = jsonDecode(raw) as Map;
      series = {for (final s in (j['series'] as List? ?? const [])) s as String};
      books = {for (final b in (j['books'] as List? ?? const [])) b as String};
    } catch (_) {
      // damaged: keep what we have
    }
  }

  /// Signed out: the account's list goes from this device (it comes back from Komga on signing in again) - an unsent
  /// change here was sent to the next account, over its own list (code review, 2026-09-30).
  Future<void> clearAccount() async {
    _api = null;
    series = {};
    books = {};
    notifyListeners();
    final p = await SharedPreferences.getInstance();
    await p.remove(_local);
    await p.remove(_dirtyKey);
  }

  @visibleForTesting
  void reset() {
    _api = null;
    series = {};
    books = {};
  }
}
