import 'package:flutter/widgets.dart';

import '../api.dart';
import '../epub/source.dart';
import '../offline/offline_komga.dart';
import 'epub_reader.dart';
import 'reader.dart';

/// Whether [book] is an EPUB (Komga's media profile) - read in the EPUB reader, not the comic reader.
bool isEpub(dynamic book) => book?['media']?['mediaProfile'] == 'EPUB';

/// The reader for [book]: the EPUB reader for EPUBs, the comic reader for everything else. Every place that opens a
/// book goes through here.
Widget readerFor(Komga api, dynamic book, {String? readListId, bool skipRead = false}) {
  if (!isEpub(book)) return ReaderScreen(api: api, book: book, readListId: readListId, skipRead: skipRead);
  // offline: a downloaded EPUB is read from its file (its progress kept on the device, sent to Komga later)
  final file = api is OfflineKomga ? api.epubFile(book['id'] as String) : null;
  return EpubReaderScreen(api: api, book: book as Map<String, dynamic>,
      source: file == null ? null : FileEpubSource(file));
}
