/// A book's "series #number" title, e.g. "Saga #3" - one place for what used to be built a dozen ways across the app
/// (code review 2026-10-05, #54). The number is the metadata's, else the book's own; a book with none is just "Saga"
/// (it showed "Saga #null" or "Saga #"), one in no series just "#3".
String bookTitle(dynamic b) {
  final series = '${b['seriesTitle'] ?? ''}';
  final number = '${(b['metadata'] as Map?)?['number'] ?? b['number'] ?? ''}';
  return [if (series.isNotEmpty) series, if (number.isNotEmpty) '#$number'].join(' ');
}

/// The reader's top-bar heading: [bookTitle], or null for a book in no series.
String? bookHeading(dynamic b) {
  final series = b['seriesTitle'] as String?;
  return series == null || series.isEmpty ? null : bookTitle(b);
}
