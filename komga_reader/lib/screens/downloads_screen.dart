import 'package:flutter/material.dart';

import '../offline/downloads.dart';

/// The download queue and everything downloaded (side menu > Downloads). The queue shows each book's state and,
/// for the one downloading, pages done / total with a progress bar; failed books say why and can be retried.
class DownloadsScreen extends StatelessWidget {
  const DownloadsScreen({super.key});

  static String size(int bytes) {
    if (bytes >= Downloads.gb) return '${(bytes / Downloads.gb).toStringAsFixed(1)} GB';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(bytes < 10 * 1024 * 1024 ? 1 : 0)} MB';
  }

  @override
  Widget build(BuildContext context) {
    final d = Downloads.instance;
    return ListenableBuilder(
      listenable: d,
      builder: (context, _) {
        final store = d.store;
        final queue = d.queue;
        final downloaded = store == null
            ? <MapEntry<String, Map<String, dynamic>>>[]
            : (store.books.entries.where((e) => e.value['state'] == 'done').toList()
              ..sort((a, b) {
                final sa = '${(a.value['book'] as Map)['seriesTitle']}', sb = '${(b.value['book'] as Map)['seriesTitle']}';
                final c = sa.compareTo(sb);
                if (c != 0) return c;
                num n(Map e) => ((e['book'] as Map)['metadata']?['numberSort'] as num?) ?? 0;
                return n(a.value).compareTo(n(b.value));
              }));
        final failed = queue.where((j) => j.state == JobState.failed).length;
        final cap = d.capBytes;
        return Scaffold(
          appBar: AppBar(
            title: const Text('Downloads'),
            actions: [
              if (queue.isNotEmpty)
                d.paused
                    ? TextButton.icon(onPressed: d.resumeAll, icon: const Icon(Icons.play_arrow), label: const Text('Resume'))
                    : TextButton.icon(onPressed: d.pauseAll, icon: const Icon(Icons.pause), label: const Text('Pause')),
              if (failed > 0)
                TextButton.icon(onPressed: d.retryAll, icon: const Icon(Icons.refresh), label: Text('Retry $failed')),
              if (queue.isNotEmpty)
                TextButton.icon(
                  onPressed: () async {
                    final ok = await showDialog<bool>(
                      context: context,
                      builder: (ctx) => AlertDialog(
                        title: Text('Cancel all ${queue.length} in the queue?'),
                        content: const Text('Books waiting, paused or failed are removed from the queue, and the one '
                            'downloading stops. Finished downloads stay.'),
                        actions: [
                          TextButton(autofocus: true, onPressed: () => Navigator.pop(ctx, false), child: const Text('Keep')),
                          TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Cancel all')),
                        ],
                      ),
                    );
                    if (ok == true) await d.cancelAll();
                  },
                  icon: const Icon(Icons.clear_all),
                  label: const Text('Cancel all'),
                ),
            ],
          ),
          body: !d.ready
              ? const Center(child: Text('Downloads aren\'t available on this device', style: TextStyle(color: Color(0xFF9A9A9A))))
              : ListView(padding: const EdgeInsets.fromLTRB(16, 8, 16, 32), children: [
                  // storage
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text('${size(d.usedBytes)} used · ${cap == null ? 'no limit' : 'limit ${size(cap)}'}'
                          ' · ${downloaded.length} book${downloaded.length == 1 ? '' : 's'}',
                          style: const TextStyle(color: Color(0xFF9A9A9A))),
                      if (cap != null) ...[
                        const SizedBox(height: 6),
                        LinearProgressIndicator(value: (d.usedBytes / cap).clamp(0.0, 1.0), minHeight: 4),
                      ],
                    ]),
                  ),
                  _Heading(queue.isEmpty ? 'Queue · empty' : 'Queue · ${queue.length}${d.paused ? ' · paused' : ''}'),
                  for (final j in queue) _JobRow(job: j),
                  if (d.recentlyDone.isNotEmpty) ...[
                    const _Heading('Finished this session'),
                    for (final t in d.recentlyDone.take(5))
                      ListTile(dense: true, contentPadding: EdgeInsets.zero,
                          leading: const Icon(Icons.check, color: Color(0xFF16C75F)), title: Text(t)),
                  ],
                  _Heading('Downloaded · ${downloaded.length}'),
                  if (downloaded.isEmpty)
                    const Padding(
                      padding: EdgeInsets.symmetric(vertical: 8),
                      child: Text('Nothing yet. Long-press a book, series or read list and choose Download.',
                          style: TextStyle(color: Color(0xFF9A9A9A))),
                    ),
                  for (final e in downloaded)
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: const Icon(Icons.download_done),
                      title: Text('${(e.value['book'] as Map)['seriesTitle']} #${(e.value['book'] as Map)['metadata']?['number'] ?? ''}'),
                      subtitle: Text('${(e.value['pages'] as List).length} pages · ${size((e.value['bytes'] as num).toInt())}'),
                      trailing: IconButton(
                        tooltip: 'Remove download',
                        icon: const Icon(Icons.delete_outline),
                        onPressed: () => d.remove(e.key),
                      ),
                    ),
                ]),
        );
      },
    );
  }
}

class _JobRow extends StatelessWidget {
  const _JobRow({required this.job});
  final DownloadJob job;
  @override
  Widget build(BuildContext context) {
    final d = Downloads.instance;
    final (label, colour) = switch (job.state) {
      JobState.downloading => (
          job.pagesTotal == 0
              ? 'Starting…'
              : 'Page ${job.pagesDone} of ${job.pagesTotal} · ${DownloadsScreen.size(job.bytes)}',
          Theme.of(context).colorScheme.primary),
      JobState.queued => ('Waiting', const Color(0xFF9A9A9A)),
      JobState.paused => ('Paused', const Color(0xFFFACC15)),
      JobState.failed => ('Failed: ${job.error ?? 'unknown error'}', const Color(0xFFFF8A80)),
    };
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(children: [
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(job.title, style: const TextStyle(fontSize: 15)),
            const SizedBox(height: 2),
            Text(label, style: TextStyle(color: colour, fontSize: 12)),
            if (job.state == JobState.downloading && job.pagesTotal > 0) ...[
              const SizedBox(height: 6),
              LinearProgressIndicator(value: job.pagesDone / job.pagesTotal, minHeight: 4),
            ],
          ]),
        ),
        if (job.state == JobState.failed)
          IconButton(tooltip: 'Retry', icon: const Icon(Icons.refresh), onPressed: () => d.retry(job.bookId)),
        IconButton(tooltip: 'Cancel', icon: const Icon(Icons.close), onPressed: () => d.cancel(job.bookId)),
      ]),
    );
  }
}

class _Heading extends StatelessWidget {
  const _Heading(this.text);
  final String text;
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(top: 18, bottom: 6),
        child: Text(text, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w500)),
      );
}
