import 'package:flutter/material.dart';

import '../offline/connection.dart';
import '../offline/downloads.dart';
import '../offline/sync.dart';
import '../widgets/fullscreen_exit.dart';

/// Downloads (side menu > Downloads), in two tabs (user, 2026-10-07): **Queue** - what's downloading: each book's
/// state, pages done / total for the one downloading, failed ones with why and Retry; **Manage** - what's downloaded:
/// a flat list sorted by name or size, filtered by read state, with a select mode, a whole series' removal and
/// "Remove all read". Opens on Queue while something is queued, Manage otherwise.
class DownloadsScreen extends StatefulWidget {
  const DownloadsScreen({super.key});

  static String size(int bytes) {
    if (bytes >= Downloads.gb) return '${(bytes / Downloads.gb).toStringAsFixed(1)} GB';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(bytes < 10 * 1024 * 1024 ? 1 : 0)} MB';
  }

  @override
  State<DownloadsScreen> createState() => _DownloadsScreenState();
}

/// What Manage shows.
enum ManageFilter { all, read, unread, gone }

/// How Manage sorts.
enum ManageSort { name, size }

/// One downloaded book, as Manage lists it.
class _Item {
  _Item(this.id, Map<String, dynamic> e, Map<String, dynamic>? progress)
      : book = e['book'] as Map,
        bytes = (e['bytes'] as num? ?? 0).toInt(),
        epub = e['epubFile'] != null,
        pages = (e['pages'] as List?)?.length ?? 0,
        gone = e['gone'] == true,
        read = progress?['completed'] == true && progress?['none'] != true,
        started = progress?['none'] != true && ((progress?['page'] as num?) ?? 0) > 0;
  final String id;
  final Map book;
  final int bytes, pages;
  final bool epub, gone, read, started;

  String get series => '${book['seriesTitle'] ?? ''}';
  String get seriesId => '${book['seriesId'] ?? ''}';
  String get title => '$series #${book['metadata']?['number'] ?? ''}';
  num get number => (book['metadata']?['numberSort'] as num?) ?? 0;
}

class _DownloadsScreenState extends State<DownloadsScreen> with SingleTickerProviderStateMixin {
  final d = Downloads.instance;
  late final TabController _tabs =
      TabController(length: 2, vsync: this, initialIndex: d.queue.isNotEmpty ? 0 : 1)..addListener(_onTab);

  ManageFilter _filter = ManageFilter.all;
  ManageSort _sort = ManageSort.name;
  final Set<String> _selected = {};
  bool _selecting = false;

  void _onTab() {
    if (!_tabs.indexIsChanging) setState(() => _endSelecting());
  }

  @override
  void dispose() {
    _tabs.dispose();
    super.dispose();
  }

  void _endSelecting() {
    _selecting = false;
    _selected.clear();
  }

  /// Everything downloaded (finished downloads only).
  List<_Item> _downloaded() {
    final store = d.store;
    if (store == null) return const [];
    return [
      for (final e in store.books.entries)
        if (e.value['state'] == 'done') _Item(e.key, e.value, store.progress[e.key]),
    ];
  }

  List<_Item> _shown(List<_Item> all) {
    final out = all.where((i) => switch (_filter) {
          ManageFilter.all => true,
          ManageFilter.read => i.read,
          ManageFilter.unread => !i.read, // in progress counts as unread, as Hide read has it
          ManageFilter.gone => i.gone,
        }).toList();
    switch (_sort) {
      case ManageSort.name:
        out.sort((a, b) {
          final c = a.series.compareTo(b.series);
          return c != 0 ? c : a.number.compareTo(b.number);
        });
      case ManageSort.size:
        out.sort((a, b) => b.bytes.compareTo(a.bytes));
    }
    return out;
  }

  static int _bytes(Iterable<_Item> items) => items.fold(0, (n, i) => n + i.bytes);

  /// Asks, then removes [items] together. True if they were removed.
  Future<bool> _confirmRemove(String title, List<_Item> items) async {
    if (items.isEmpty) return false;
    final n = items.length;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: Text('$n download${n == 1 ? '' : 's'} · ${DownloadsScreen.size(_bytes(items))} freed. The books stay '
            'on Komga; reading progress not sent yet still goes.'),
        actions: [
          TextButton(autofocus: true, onPressed: () => Navigator.pop(ctx, false), child: const Text('Keep')),
          TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Remove')),
        ],
      ),
    );
    if (ok != true) return false;
    await d.removeAll(items.map((i) => i.id));
    return true;
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: d,
      builder: (context, _) {
        final all = _downloaded();
        _selected.retainAll(all.map((i) => i.id)); // (removed meanwhile)
        final onManage = _tabs.index == 1;
        final selecting = onManage && _selecting;
        return PopScope(
          canPop: !selecting,
          onPopInvokedWithResult: (didPop, _) {
            if (!didPop) setState(_endSelecting); // Back leaves select mode first
          },
          child: Scaffold(
            appBar: AppBar(
              leading: selecting
                  ? IconButton(tooltip: 'Done selecting', icon: const Icon(Icons.close),
                      onPressed: () => setState(_endSelecting))
                  : null,
              title: selecting ? _selectionTitle(all) : const Text('Downloads'),
              actions: [
                if (selecting) ..._selectionActions(all) else if (!onManage) ..._queueActions(),
                const FullscreenExit(),
              ],
              bottom: TabBar(controller: _tabs, tabs: [
                Tab(text: d.queue.isEmpty ? 'Queue' : 'Queue · ${d.queue.length}'),
                Tab(text: 'Manage · ${all.length}'),
              ]),
            ),
            body: !d.ready
                ? const Center(
                    child: Text('Downloads aren\'t available on this device', style: TextStyle(color: _grey)))
                : TabBarView(controller: _tabs, children: [_queueTab(), _manageTab(all)]),
          ),
        );
      },
    );
  }

  // ---- Queue ----------------------------------------------------------------------------------------------------

  List<Widget> _queueActions() {
    final queue = d.queue;
    final failed = queue.where((j) => j.state == JobState.failed).length;
    return [
      if (queue.isNotEmpty)
        d.paused
            ? TextButton.icon(onPressed: d.resumeAll, icon: const Icon(Icons.play_arrow), label: const Text('Resume'))
            : TextButton.icon(onPressed: d.pauseAll, icon: const Icon(Icons.pause), label: const Text('Pause')),
      if (failed > 0) TextButton.icon(onPressed: d.retryAll, icon: const Icon(Icons.refresh), label: Text('Retry $failed')),
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
    ];
  }

  Widget _queueTab() {
    final queue = d.queue;
    return ListView(padding: const EdgeInsets.fromLTRB(16, 8, 16, 32), children: [
      const _PendingProgress(),
      if (queue.isNotEmpty)
        _Heading('${queue.length} in the queue${d.paused ? ' · paused' : ''}'
            '${d.waitingForWifi && !d.paused ? ' · waiting for Wi-Fi' : ''}'
            '${d.waitingForServer && !d.paused ? " · waiting for Komga" : ''}'),
      for (final j in queue) _JobRow(job: j),
      if (queue.isEmpty)
        const Padding(
          padding: EdgeInsets.symmetric(vertical: 16),
          child: Text('Nothing downloading. Long-press a book, series or read list and choose Download.',
              style: TextStyle(color: _grey)),
        ),
      if (d.recentlyDone.isNotEmpty) ...[
        const _Heading('Finished this session'),
        for (final t in d.recentlyDone.take(5))
          ListTile(dense: true, contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.check, color: Color(0xFF16C75F)), title: Text(t)),
      ],
    ]);
  }

  // ---- Manage ---------------------------------------------------------------------------------------------------

  Widget _selectionTitle(List<_Item> all) {
    final picked = all.where((i) => _selected.contains(i.id));
    return Text(_selected.isEmpty
        ? 'Select downloads'
        : '${_selected.length} selected · ${DownloadsScreen.size(_bytes(picked))}');
  }

  List<Widget> _selectionActions(List<_Item> all) {
    final shown = _shown(all);
    final allShown = shown.isNotEmpty && shown.every((i) => _selected.contains(i.id));
    return [
      TextButton(
        onPressed: shown.isEmpty
            ? null
            : () => setState(() => allShown
                ? _selected.removeAll(shown.map((i) => i.id))
                : _selected.addAll(shown.map((i) => i.id))),
        child: Text(allShown ? 'Select none' : 'Select all'),
      ),
      TextButton.icon(
        onPressed: _selected.isEmpty
            ? null
            : () async {
                final picked = all.where((i) => _selected.contains(i.id)).toList();
                if (await _confirmRemove('Remove the selected downloads?', picked) && mounted) {
                  setState(_endSelecting);
                }
              },
        icon: const Icon(Icons.delete_outline),
        label: const Text('Remove'),
      ),
    ];
  }

  Widget _manageTab(List<_Item> all) {
    final cap = d.capBytes;
    final shown = _shown(all);
    final read = all.where((i) => i.read).toList();
    final anyGone = all.any((i) => i.gone);
    if (_filter == ManageFilter.gone && !anyGone) _filter = ManageFilter.all;
    final header = Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text('${DownloadsScreen.size(d.usedBytes)} used · ${cap == null ? 'no limit' : 'limit ${DownloadsScreen.size(cap)}'}'
            ' · ${all.length} book${all.length == 1 ? '' : 's'}',
            style: const TextStyle(color: _grey)),
        if (cap != null) ...[
          const SizedBox(height: 6),
          LinearProgressIndicator(value: (d.usedBytes / cap).clamp(0.0, 1.0), minHeight: 4),
        ],
        const SizedBox(height: 8),
        Wrap(spacing: 8, runSpacing: 4, crossAxisAlignment: WrapCrossAlignment.center, children: [
          for (final f in ManageFilter.values)
            if (f != ManageFilter.gone || anyGone)
              ChoiceChip(
                label: Text(switch (f) {
                  ManageFilter.all => 'All',
                  ManageFilter.read => 'Read',
                  ManageFilter.unread => 'Unread',
                  ManageFilter.gone => 'No longer on Komga',
                }),
                selected: _filter == f,
                onSelected: (_) => setState(() => _filter = f),
              ),
          PopupMenuButton<ManageSort>(
            tooltip: 'Sort',
            initialValue: _sort,
            onSelected: (s) => setState(() => _sort = s),
            itemBuilder: (_) => const [
              PopupMenuItem(value: ManageSort.name, child: Text('Name')),
              PopupMenuItem(value: ManageSort.size, child: Text('Size, largest first')),
            ],
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 10),
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                Text('Sort: ${_sort == ManageSort.name ? 'Name' : 'Size'}'),
                const Icon(Icons.arrow_drop_down),
              ]),
            ),
          ),
          if (read.isNotEmpty && !_selecting)
            TextButton.icon(
              onPressed: () => _confirmRemove('Remove all ${read.length} read?', read),
              icon: const Icon(Icons.done_all),
              label: const Text('Remove all read'),
            ),
          if (!_selecting && all.isNotEmpty)
            TextButton.icon(
              onPressed: () => setState(() => _selecting = true),
              icon: const Icon(Icons.checklist),
              label: const Text('Select'),
            ),
        ]),
      ]),
    );
    if (all.isEmpty) {
      return ListView(children: [
        header,
        const Padding(
          padding: EdgeInsets.all(16),
          child: Text('Nothing downloaded yet. Long-press a book, series or read list and choose Download.',
              style: TextStyle(color: _grey)),
        ),
      ]);
    }
    // built as they scroll into view (it rebuilt every row on each page downloaded - general scan #37)
    return ListView.builder(
      padding: const EdgeInsets.only(bottom: 32),
      itemCount: shown.length + 1,
      itemBuilder: (context, i) => i == 0 ? header : _row(shown[i - 1], all),
    );
  }

  Widget _row(_Item item, List<_Item> all) {
    final picked = _selected.contains(item.id);
    final state = item.read ? 'read' : item.started ? 'in progress' : null;
    void toggle() => setState(() => picked ? _selected.remove(item.id) : _selected.add(item.id));
    return ListTile(
      key: ValueKey(item.id),
      contentPadding: const EdgeInsets.symmetric(horizontal: 16),
      leading: _selecting
          ? Checkbox(value: picked, onChanged: (_) => toggle())
          : Icon(item.read ? Icons.done_all : Icons.download_done, color: item.read ? _grey : null),
      title: Text(item.title),
      // an EPUB is its file, with no pages to count ("0 pages" - Windows check, build 79)
      subtitle: Text([
        item.epub ? 'EPUB' : '${item.pages} pages',
        DownloadsScreen.size(item.bytes),
        if (state != null) state,
        if (item.gone) 'no longer on Komga',
      ].join(' · ')),
      onTap: _selecting ? toggle : null,
      onLongPress: _selecting
          ? null
          : () => setState(() {
                _selecting = true;
                _selected.add(item.id);
              }),
      trailing: _selecting
          ? null
          : PopupMenuButton<String>(
              tooltip: 'Remove',
              icon: const Icon(Icons.more_vert),
              onSelected: (what) async {
                if (what == 'book') {
                  await d.remove(item.id);
                } else {
                  final series = all.where((i) => i.seriesId == item.seriesId).toList();
                  await _confirmRemove('Remove ${item.series}?', series);
                }
              },
              itemBuilder: (_) {
                final n = all.where((i) => i.seriesId == item.seriesId).length;
                return [
                  const PopupMenuItem(value: 'book', child: Text('Remove download')),
                  if (n > 1) PopupMenuItem(value: 'series', child: Text('Remove the series\' $n downloads')),
                ];
              },
            ),
    );
  }
}

const _grey = Color(0xFF9A9A9A);

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
      JobState.queued => ('Waiting', _grey),
      JobState.paused => ('Paused', const Color(0xFFFACC15)),
      JobState.failed => ('Failed: ${job.error ?? 'something unexpected went wrong'}.', const Color(0xFFFF8A80)),
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

/// Reading progress made offline that hasn't reached Komga yet, with Send now (online only).
class _PendingProgress extends StatelessWidget {
  const _PendingProgress();
  @override
  Widget build(BuildContext context) {
    final sync = ProgressSync.instance;
    return ListenableBuilder(
      listenable: Listenable.merge([sync, Connection.instance, Downloads.instance]),
      builder: (context, _) {
        final n = sync.pending;
        if (n == 0) return const SizedBox.shrink();
        final offline = Connection.instance.offline;
        return Card(
          margin: const EdgeInsets.only(bottom: 12),
          child: ListTile(
            leading: const Icon(Icons.sync),
            title: Text('Reading progress for $n ${n == 1 ? 'book' : 'books'} waiting for Komga'),
            subtitle: Text(offline ? 'Sent when back online' : 'Sent automatically; or send it now'),
            trailing: offline
                ? null
                : sync.running
                    ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
                    : TextButton(onPressed: sync.run, child: const Text('Send now')),
          ),
        );
      },
    );
  }
}
