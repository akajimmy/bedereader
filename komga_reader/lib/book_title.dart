/// A book's name as people say it - one place for what used to be built a dozen ways across the app (code review
/// 2026-10-05, #54). A comic is its "series #number", e.g. "Saga #3" ([bookSeriesLine]); an eBook is its own title,
/// "Small Gods" (user, 2026-10-18: "It doesn't make sense to have the series and number in the way that we do for
/// comics. Nobody thinks of books in that way") - the series and number only if it has no title.
String bookTitle(dynamic b) {
  if (isEbook(b)) {
    final own = bookOwnTitle(b);
    if (own.isNotEmpty) return own;
  }
  return bookSeriesLine(b);
}

/// The series and number, "Saga #3". The number is the metadata's, else the book's own; a book with none is just
/// "Saga" (it showed "Saga #null" or "Saga #"), one in no series just "#3".
String bookSeriesLine(dynamic b) {
  final series = '${b['seriesTitle'] ?? ''}';
  final number = '${(b['metadata'] as Map?)?['number'] ?? b['number'] ?? ''}';
  return [if (series.isNotEmpty) series, if (number.isNotEmpty) '#$number'].join(' ');
}

/// The book's own title (its file name if it has none).
String bookOwnTitle(dynamic b) => '${(b['metadata'] as Map?)?['title'] ?? b['name'] ?? ''}';

/// An eBook (EPUB) rather than a comic: named after its title and author, not its series ([bookTitle]).
bool isEbook(dynamic b) => (b?['media'] as Map?)?['mediaProfile'] == 'EPUB';

/// Who wrote it: the writers Komga lists ("Terry Pratchett, Neil Gaiman"), else whoever it lists first; '' for none.
String bookAuthors(dynamic b) {
  final authors = [for (final a in ((b['metadata'] as Map?)?['authors'] as List?) ?? const []) if (a is Map) a];
  final writers = [for (final a in authors) if ('${a['role']}'.toLowerCase() == 'writer') '${a['name']}'];
  final names = writers.isNotEmpty ? writers : [if (authors.isNotEmpty) '${authors.first['name']}'];
  return {...names}.join(', ');
}

/// The line under a book's name ([bookTitle]) where both are shown - a menu's heading, say: a comic's own title, an
/// eBook's author.
String bookSubtitle(dynamic b) => isEbook(b) ? bookAuthors(b) : bookOwnTitle(b);

/// The reader's top-bar heading, over the book's own title: a comic's [bookSeriesLine] (none for a comic in no
/// series); an eBook's author (none if Komga lists nobody).
String? bookHeading(dynamic b) {
  if (isEbook(b)) {
    final who = bookAuthors(b);
    return who.isEmpty ? null : who;
  }
  final series = b['seriesTitle'] as String?;
  return series == null || series.isEmpty ? null : bookSeriesLine(b);
}
