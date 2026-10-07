import 'package:flutter/material.dart';

import '../api.dart';
import '../offline/offline_komga.dart' show NotAvailableOffline;
import '../widgets/native_poster.dart';
import '../widgets/focus_style.dart';

/// The page after the last, for both kinds of book (the one Reader, user 2026-10-07, decision 1): what's next - its
/// poster and title - or that this was the last one; then **Next book** and **Close**, both reachable with the remote
/// (it lands on Next book, on Close when there's none). Forward (tap, key, wheel) opens the next book too - the
/// Reader's.
class ReaderEndCard extends StatelessWidget {
  const ReaderEndCard({super.key, required this.api, required this.next, required this.ink, required this.where,
      required this.lastText, required this.nextNode, required this.closeNode, required this.onNext,
      required this.onClose, this.skipRead = false, this.subtitle});

  final Komga api;
  final Future<Map<String, dynamic>?> next; // the book after this one (null: none)
  final Color Function(double alpha) ink; // text on the page's background
  final String where; // 'the series', 'this read list'
  final String lastText; // there's no next book: 'End of the series'
  final bool skipRead; // the next one not read yet
  final String? subtitle; // under the heading: the book's own title
  final FocusNode nextNode, closeNode;
  final VoidCallback onNext, onClose;

  /// The end card is reached: the remote on Next book (on Close when there's none). [still]: still on the card.
  static void focusOn(Future<Map<String, dynamic>?> next, FocusNode nextNode, FocusNode closeNode,
      bool Function() still) {
    next.then((n) {
      if (still()) (n == null ? closeNode : nextNode).requestFocus();
    }, onError: (Object _) {
      if (still()) closeNode.requestFocus();
    });
  }

  @override
  Widget build(BuildContext context) {
    final dim = TextStyle(color: ink(0.38));
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Theme(
          data: readerControlsTheme(context),
          child: FutureBuilder<Map<String, dynamic>?>(
            future: next,
            builder: (context, snap) {
              final book = snap.data;
              final waiting = snap.connectionState != ConnectionState.done;
              final offline = snap.error is NotAvailableOffline;
              // couldn't look it up (not offline): Next book tries again, and says why if it can't
              final canGoOn = !waiting && (book != null || (snap.hasError && !offline));
              final List<Widget> body;
              if (waiting) {
                body = [const SizedBox(width: 28, height: 28, child: CircularProgressIndicator(strokeWidth: 2))];
              } else if (offline) {
                // offline, and the book that comes next isn't downloaded: no jumping ahead to one that is
                body = [Text("The next book in $where isn't downloaded", textAlign: TextAlign.center,
                    style: TextStyle(color: ink(0.7), fontSize: 16))];
              } else if (snap.hasError) {
                body = const [];
              } else if (book == null) {
                body = [Text(lastText, textAlign: TextAlign.center, style: TextStyle(color: ink(0.7), fontSize: 16))];
              } else {
                final number = book['metadata']?['number'] ?? book['number'];
                final title = (book['metadata']?['title'] ?? book['name']) as String?;
                final heading = '${book['seriesTitle'] ?? ''} #$number'.trim();
                body = [
                  Text(skipRead ? 'Next unread in $where' : 'Up next in $where', style: dim),
                  const SizedBox(height: 12),
                  Builder(builder: (context) {
                    final h = (MediaQuery.sizeOf(context).height * 0.42).clamp(160.0, 520.0);
                    // the book's poster as Komga has it (a poster picked in Komga included), at its own size - so
                    // its size follows the server's thumbnail size - and no bigger than the plate (user, 2026-10-03)
                    return NativePoster(api.thumbImage(api.bookThumb(book['id'] as String)), max: Size(h * 0.8, h));
                  }),
                  const SizedBox(height: 14),
                  Text(heading, textAlign: TextAlign.center, style: TextStyle(color: ink(1), fontSize: 18)),
                  if (title != null && title != heading && !title.endsWith('#$number'))
                    Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: Text(title, textAlign: TextAlign.center, maxLines: 2, overflow: TextOverflow.ellipsis,
                          style: TextStyle(color: ink(0.7))),
                    ),
                ];
              }
              return Column(mainAxisSize: MainAxisSize.min, children: [
                Text('End of book', style: TextStyle(color: ink(0.7), fontSize: 18)),
                if (subtitle != null) ...[
                  const SizedBox(height: 4),
                  Text(subtitle!, textAlign: TextAlign.center, style: TextStyle(color: ink(0.55))),
                ],
                const SizedBox(height: 16),
                ...body,
                const SizedBox(height: 22),
                if (canGoOn)
                  FilledButton.icon(
                    focusNode: nextNode,
                    onPressed: onNext,
                    icon: const Icon(Icons.skip_next),
                    label: const Text('Next book'),
                  ),
                const SizedBox(height: 8),
                TextButton(focusNode: closeNode, onPressed: onClose,
                    child: Text('Close', style: TextStyle(color: ink(0.8)))),
              ]);
            },
          ),
        ),
      ),
    );
  }
}
