import 'package:flutter/widgets.dart';

import '../api.dart';
import '../epub/source.dart';
import '../reader/epub_renderer.dart';
import '../settings.dart';
import 'reader.dart';

/// An EPUB in the one Reader (user, 2026-10-07: one Reader, a renderer per kind of book - the EPUB's is
/// lib/reader/epub_renderer.dart). Kept for the places that open an EPUB from a source of their own (tests) until the
/// clean-up step; everything else opens books through readerFor (open_book.dart).
class EpubReaderScreen extends StatelessWidget {
  const EpubReaderScreen({super.key, required this.api, required this.book, this.source, this.saveProgress = true,
      this.readListId, this.skipRead = false});

  final Komga api;
  final Map<String, dynamic> book;
  final EpubSource? source;
  final bool saveProgress;
  final String? readListId;
  final bool skipRead;

  /// Forgets the closing saves still on their way (tests: each starts with none).
  @visibleForTesting
  // ignore: invalid_use_of_visible_for_testing_member
  static void forgetClosingSaves() => ReaderScreen.forgetClosingSaves();

  /// The page's left / right margin at [width] (lib/reader/epub_renderer.dart).
  static double sideMargin(EpubPrefs e, double width) => EpubRenderer.sideMargin(e, width);

  @override
  Widget build(BuildContext context) => ReaderScreen(api: api, book: book, readListId: readListId,
      skipRead: skipRead, epubSource: source, saveProgress: saveProgress);
}
