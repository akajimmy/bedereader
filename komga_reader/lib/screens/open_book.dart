import 'package:flutter/material.dart';

import '../api.dart';
import 'reader.dart';

/// Whether [book] is an EPUB (Komga's media profile) - read in the EPUB reader, not the comic reader.
bool isEpub(dynamic book) => book?['media']?['mediaProfile'] == 'EPUB';

/// The reader for [book]: the EPUB reader for EPUBs, the comic reader for everything else. Every place that opens a
/// book goes through here.
Widget readerFor(Komga api, dynamic book, {String? readListId, bool skipRead = false}) =>
    // the one Reader, its renderer by the book's kind (offline, a downloaded EPUB is read from its file)
    ReaderScreen(api: api, book: book, readListId: readListId, skipRead: skipRead);
