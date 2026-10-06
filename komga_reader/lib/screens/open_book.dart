import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';

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
  if (kIsWeb) return const _NoEpubInBrowser(); // Android and Windows only (user, 2026-10-05)
  // offline: a downloaded EPUB is read from its file (its progress kept on the device, sent to Komga later)
  final file = api is OfflineKomga ? api.epubFile(book['id'] as String) : null;
  return EpubReaderScreen(api: api, book: book as Map<String, dynamic>,
      source: file == null ? null : FileEpubSource(file));
}

/// The browser version: EPUBs aren't read there (Android and Windows only).
class _NoEpubInBrowser extends StatelessWidget {
  const _NoEpubInBrowser();
  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(),
        body: const Center(child: Padding(
          padding: EdgeInsets.all(24),
          child: Text("EPUB books can't be read in the browser version. Read them in the Android or Windows app.",
              textAlign: TextAlign.center),
        )),
      );
}
