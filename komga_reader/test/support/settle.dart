// Waiting for the download queue (moved out of downloads_test, 2026-10-07: downloads_epub_test imported it from
// there).
import 'package:flutter_test/flutter_test.dart';
import 'package:komga_reader/offline/downloads.dart';

import 'helpers.dart';

/// Waits (on the real clock, 2 s at most) until nothing is queued or downloading. Fails the test if that never happens:
/// it used to return quietly, so the next expectation failed for the wrong reason (test audit, 2026-09-30).
Future<void> settle(Downloads d) async {
  bool working() => d.queue.any((j) => j.state == JobState.queued || j.state == JobState.downloading);
  try {
    await waitUntil(() => !working());
  } on TestFailure {
    fail('the queue never settled: ${[for (final j in d.queue) '${j.bookId} ${j.state.name}']}');
  }
}
