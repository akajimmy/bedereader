import 'package:flutter/widgets.dart';

import '../api.dart';
import 'epub_reader.dart';
import 'reader.dart';

/// Whether [book] is an EPUB (Komga's media profile) - read in the EPUB reader, not the comic reader.
bool isEpub(dynamic book) => book?['media']?['mediaProfile'] == 'EPUB';

/// The reader for [book]: the EPUB reader for EPUBs, the comic reader for everything else. Every place that opens a
/// book goes through here.
Widget readerFor(Komga api, dynamic book, {String? readListId, bool skipRead = false}) => isEpub(book)
    ? EpubReaderScreen(api: api, book: book as Map<String, dynamic>)
    : ReaderScreen(api: api, book: book, readListId: readListId, skipRead: skipRead);
