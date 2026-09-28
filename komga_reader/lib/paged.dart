import 'package:flutter/foundation.dart';

/// Fetches one Komga page ({content, last, totalElements}) of a listing.
typedef PageFetch = Future<Map<String, dynamic>> Function(int page, int size);

/// A Komga listing loaded a page at a time as the grid scrolls (touch or remote), so big libraries show everything.
class Paged extends ChangeNotifier {
  Paged(this.fetch, {this.pageSize = 100});

  PageFetch fetch;
  final int pageSize;
  final List<dynamic> items = [];
  int? total;
  bool loading = false;
  bool firstLoad = true; // nothing shown yet
  Object? error;
  int _nextPage = 0;
  bool _last = false;
  int _gen = 0; // bumped on reset, so answers to an older listing are dropped

  bool get hasMore => !_last;

  /// Start over (new library, filter or sort).
  Future<void> reset([PageFetch? f]) {
    if (f != null) fetch = f;
    _gen++;
    items.clear();
    total = null;
    _nextPage = 0;
    _last = false;
    loading = false;
    firstLoad = true;
    error = null;
    return more();
  }

  /// Load the next page, if there is one and none is already on its way.
  Future<void> more() async {
    if (loading || _last) return;
    final gen = _gen;
    loading = true;
    error = null;
    notifyListeners();
    try {
      final r = await fetch(_nextPage, pageSize);
      if (gen != _gen) return;
      final content = (r['content'] as List<dynamic>?) ?? [];
      items.addAll(content);
      total = r['totalElements'] as int?;
      _last = r['last'] == true || content.length < pageSize;
      _nextPage++;
    } catch (e) {
      if (gen != _gen) return;
      error = e;
    }
    loading = false;
    firstLoad = false;
    notifyListeners();
  }

  /// Re-fetch what is already loaded (read state may have changed) without losing the scroll position.
  Future<void> refresh() async {
    if (_nextPage == 0) return reset();
    final gen = ++_gen;
    loading = true;
    try {
      final pages = await Future.wait([for (var p = 0; p < _nextPage; p++) fetch(p, pageSize)]);
      if (gen != _gen) return;
      items
        ..clear()
        ..addAll(pages.expand((r) => (r['content'] as List<dynamic>?) ?? []));
      total = pages.last['totalElements'] as int?;
      _last = pages.last['last'] == true;
      error = null;
    } catch (e) {
      if (gen != _gen) return;
      error = e;
    }
    loading = false;
    notifyListeners();
  }
}
