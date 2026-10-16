import 'synced_ids.dart';

/// Series and books left out of On deck (book / series menu > "Hide from On deck"). Komga has no such setting, so
/// the app keeps the list and filters On deck with it:
/// - a **series** never shows there;
/// - a **book** is skipped - its series stays out of On deck until that book is read, then the next one shows.
/// Kept on the device and in the user's Komga client settings (like pins), so every device agrees.
class OnDeckHidden extends SyncedIds {
  OnDeckHidden._() : super(komgaKey, 'ondeck.hidden', const ['series', 'books']);
  static final OnDeckHidden instance = OnDeckHidden._();
  static const komgaKey = 'komgareader.ondeckhidden';

  Set<String> get series => sets['series']!;
  Set<String> get books => sets['books']!;

  bool seriesHidden(String? id) => id != null && series.contains(id);
  bool bookHidden(String? id) => id != null && books.contains(id);

  /// Whether an On deck entry (a book) should be left out.
  bool hides(dynamic book) => bookHidden(book['id'] as String?) || seriesHidden(book['seriesId'] as String?);

  void setSeries(String id, bool hidden) => put('series', id, hidden);
  void setBook(String id, bool hidden) => put('books', id, hidden);
  void clear() => change(() { series.clear(); books.clear(); });
}
