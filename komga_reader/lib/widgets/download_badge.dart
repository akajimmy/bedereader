import 'package:flutter/material.dart';

import '../offline/connection.dart';
import '../offline/downloads.dart';

/// Small mark in a poster's bottom-right corner saying what of it is on this device:
/// - a book: downloaded (tick), in the queue (a ring filling with its pages; paused shows a pause sign), or failed;
/// - a series or read list: how many of its books are downloaded (tick alone when all of them are).
/// Hidden in offline mode, where everything shown is downloaded anyway, and where downloads aren't possible (web).
class DownloadBadge extends StatelessWidget {
  const DownloadBadge.book(String this.bookId, {super.key}) : seriesId = null, readListId = null, total = 0;
  const DownloadBadge.series(String this.seriesId, {super.key, required this.total}) : bookId = null, readListId = null;
  const DownloadBadge.readList(String this.readListId, {super.key, required this.total}) : bookId = null, seriesId = null;

  final String? bookId, seriesId, readListId;
  final int total; // books in the series / read list

  static const _done = Color(0xFF2E9BFF); // blue: apart from the green "read" tick

  @override
  Widget build(BuildContext context) {
    final d = Downloads.instance;
    if (!d.ready) return const SizedBox.shrink();
    return ListenableBuilder(
      listenable: Listenable.merge([d, Connection.instance]),
      builder: (context, _) {
        if (Connection.instance.offline) return const SizedBox.shrink();
        final id = bookId;
        if (id != null) {
          if (d.isDownloaded(id)) return _disc(const Icon(Icons.download_done, size: 18, color: Colors.white), _done);
          final job = d.jobFor(id);
          if (job == null) return const SizedBox.shrink();
          return switch (job.state) {
            JobState.failed => _disc(const Icon(Icons.priority_high, size: 18, color: Colors.white), const Color(0xFFD64545)),
            JobState.paused => _disc(const Icon(Icons.pause, size: 18, color: Colors.white), Colors.black87),
            _ => _disc(
                Padding(
                  padding: const EdgeInsets.all(4),
                  child: CircularProgressIndicator(
                    value: job.pagesTotal > 0 ? job.pagesDone / job.pagesTotal : null, // queued: spinning
                    strokeWidth: 3, color: _done, backgroundColor: Colors.white24,
                  ),
                ),
                Colors.black87),
          };
        }
        final n = seriesId != null ? d.downloadedInSeries(seriesId!) : d.downloadedInReadList(readListId!);
        if (n == 0) return const SizedBox.shrink();
        if (n >= total && total > 0) return _disc(const Icon(Icons.download_done, size: 18, color: Colors.white), _done);
        return Container(
          height: 28,
          padding: const EdgeInsets.symmetric(horizontal: 8),
          decoration: _decoration(_done, BorderRadius.circular(14)),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            const Icon(Icons.download_done, size: 16, color: Colors.white),
            const SizedBox(width: 3),
            Text('$n', style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: Colors.white)),
          ]),
        );
      },
    );
  }

  static BoxDecoration _decoration(Color color, [BorderRadius? radius]) => BoxDecoration(
        color: color,
        shape: radius == null ? BoxShape.circle : BoxShape.rectangle,
        borderRadius: radius,
        border: Border.all(color: Colors.white, width: 1.5),
        boxShadow: const [BoxShadow(color: Colors.black54, blurRadius: 4, offset: Offset(0, 1))],
      );

  static Widget _disc(Widget child, Color color) =>
      Container(width: 28, height: 28, alignment: Alignment.center, decoration: _decoration(color), child: child);
}
