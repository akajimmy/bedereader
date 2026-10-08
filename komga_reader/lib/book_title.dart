/// A book's "series #number" title, e.g. "Saga #3" - one place for what used to be built a dozen ways across the app
/// (code review 2026-10-05, #54). The options keep each caller's output exactly as it was:
///
/// * [trim]: drop the leading space a book in no series gets (" #3" -> "#3"), and the trailing one a book with no
///   number gets.
/// * [bookNumber]: fall back to the book's own `number` when its metadata has none (the offline copies and the
///   end card read it that way). With neither, the number shows as "null" - what those callers have always shown;
///   without [bookNumber] a missing number is empty.
String bookTitle(dynamic b, {bool trim = false, bool bookNumber = false}) {
  final meta = (b['metadata'] as Map?)?['number'];
  final number = bookNumber ? (meta ?? b['number']) : (meta ?? '');
  final s = '${b['seriesTitle'] ?? ''} #$number';
  return trim ? s.trim() : s;
}

/// The reader's top-bar heading: "Saga #1"; just "Saga" when the book has no number; null for a book in no series.
String? bookHeading(dynamic b) {
  final series = b['seriesTitle'] as String?;
  final number = (b['metadata'] as Map?)?['number'];
  return series == null || series.isEmpty ? null : '$series${number == null ? '' : ' #$number'}';
}
