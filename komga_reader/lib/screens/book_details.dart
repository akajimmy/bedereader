import 'dart:async';

import 'package:flutter/material.dart';

import '../api.dart';
import '../errors.dart';
import '../widgets/arrow_scroll.dart';
import '../widgets/fullscreen_exit.dart';
import '../widgets/error_text.dart';
import 'reader.dart';
import 'series.dart';

/// One book's details: cover, title, series and number, publisher, release date, pages, read status, summary and
/// credits (grouped by role), with Read / Mark read or unread / View series. Fetched fresh from Komga.
class BookDetailsScreen extends StatefulWidget {
  const BookDetailsScreen({super.key, required this.api, required this.book, this.readListId, this.showViewSeries = true});
  final Komga api;
  final dynamic book;
  final String? readListId; // opened from a read list: Read continues through that list
  final bool showViewSeries; // hidden when already coming from that series
  @override
  State<BookDetailsScreen> createState() => _BookDetailsScreenState();
}

/// Credit roles in the order comics list them; anything else follows, as Komga names it.
const _roleOrder = ['writer', 'penciller', 'artist', 'inker', 'colorist', 'letterer', 'cover', 'editor', 'translator'];

class _BookDetailsScreenState extends State<BookDetailsScreen> {
  late dynamic _book = widget.book;
  dynamic _series;
  Object? _error; // shown through lib/errors.dart

  Komga get api => widget.api;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final fresh = await api.book(_book['id'] as String);
      final series = await api.oneSeries(_book['seriesId'] as String);
      if (mounted) setState(() { if (fresh != null) _book = fresh; _series = series; _error = null; });
    } catch (e) {
      if (mounted) setState(() => _error = e);
    }
  }

  Future<void> _toggleRead(bool completed) async {
    try {
      completed ? await api.markUnread(_book['id']) : await api.markRead(_book['id']);
      await _load();
    } catch (e, st) {
      final title = '${_book['seriesTitle'] ?? ''} #${_book['metadata']?['number'] ?? ''}';
      if (mounted) {
        showErrorSnack(context, couldnt('mark "$title" as ${completed ? 'unread' : 'read'}', e, thing: 'book'), e, st);
      }
    }
  }

  Future<void> _read() async {
    await Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => ReaderScreen(api: api, book: _book, readListId: widget.readListId)));
    unawaited(_load()); // back from the reader: read state may have changed
  }

  Future<void> _viewSeries() async {
    final s = _series ?? await api.oneSeries(_book['seriesId'] as String);
    if (s == null || !mounted) return;
    await Navigator.of(context).push(MaterialPageRoute(builder: (_) => SeriesScreen(api: api, series: s)));
    unawaited(_load()); // back from the series: read state may have changed
  }

  @override
  Widget build(BuildContext context) {
    final m = _book['metadata'] ?? {};
    final rp = _book['readProgress'];
    final completed = rp?['completed'] == true;
    final pages = _book['media']?['pagesCount'] ?? 0;
    final status = completed ? 'Read' : rp != null ? 'In progress · page ${rp['page']} of $pages' : 'Unread';
    final summary = ((m['summary'] as String?)?.trim().isNotEmpty ?? false)
        ? m['summary'] as String
        : ((_series?['metadata']?['summary'] as String?)?.trim() ?? '');
    final wide = MediaQuery.sizeOf(context).width >= 700;

    final cover = ClipRRect(
      borderRadius: BorderRadius.circular(6),
      child: AspectRatio(
        aspectRatio: 0.66,
        child: Image(image: api.thumbImage(api.bookThumb(_book['id'] as String)), fit: BoxFit.cover,
            errorBuilder: (_, __, ___) => const ColoredBox(color: Color(0xFF1C1C1F))),
      ),
    );

    final facts = Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text('${_book['seriesTitle'] ?? ''} #${m['number'] ?? ''}',
          style: const TextStyle(fontSize: 15, color: Color(0xFF9A9A9A))),
      const SizedBox(height: 4),
      Text((m['title'] ?? _book['name'] ?? '') as String, style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w500)),
      const SizedBox(height: 12),
      detailsFact('Publisher', _series?['metadata']?['publisher'] as String?),
      detailsFact('Released', detailsDate(m['releaseDate'] as String?)),
      detailsFact('Pages', pages == 0 ? null : '$pages'),
      detailsFact('Status', status),
      const SizedBox(height: 16),
      Wrap(spacing: 10, runSpacing: 10, children: [
        FilledButton.icon(autofocus: true, onPressed: _read, icon: const Icon(Icons.menu_book),
            label: Text(rp != null && !completed ? 'Continue' : 'Read')),
        OutlinedButton.icon(onPressed: () => _toggleRead(completed),
            icon: Icon(completed ? Icons.radio_button_unchecked : Icons.check_circle_outline),
            label: Text(completed ? 'Mark as unread' : 'Mark as read')),
        if (widget.showViewSeries)
          OutlinedButton.icon(onPressed: _viewSeries, icon: const Icon(Icons.collections_bookmark_outlined),
              label: const Text('View series')),
      ]),
    ]);

    return ArrowScroll(builder: (scroll) => Scaffold( // the remote's Up / Down scroll past the buttons
      appBar: AppBar(title: const Text('Details'), actions: const [FullscreenExit()]),
      // pull down to refresh (re-reads the book and series from Komga)
      body: RefreshIndicator(onRefresh: _load, child: ListView(controller: scroll,
          physics: const AlwaysScrollableScrollPhysics(), padding: const EdgeInsets.fromLTRB(20, 8, 20, 32), children: [
        if (_error != null)
          Padding(padding: const EdgeInsets.only(bottom: 12),
              child: ErrorText(explain(_error!, thing: 'book').message, _error!)),
        wide
            ? Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                SizedBox(width: 220, child: cover),
                const SizedBox(width: 24),
                Expanded(child: facts),
              ])
            : Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Center(child: SizedBox(width: 200, child: cover)),
                const SizedBox(height: 16),
                facts,
              ]),
        if (summary.isNotEmpty) ...[
          const DetailsHeading('Summary'),
          Text(summary, style: const TextStyle(fontSize: 15, height: 1.45)),
        ],
        ...creditsSection(m['authors'] as List?),
      ])),
    ));
  }

}

class DetailsHeading extends StatelessWidget {
  const DetailsHeading(this.text, {super.key});
  final String text;
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(top: 24, bottom: 8),
        child: Text(text, style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w500)),
      );
}

/// Shared with the series Details screen.
List<Widget> creditsSection(List? authors) {
  if (authors == null || authors.isEmpty) return const [];
  final byRole = <String, List<String>>{};
  for (final a in authors) {
    final role = ((a['role'] as String?) ?? 'other').toLowerCase();
    final names = byRole.putIfAbsent(role, () => []), name = a['name'] as String? ?? '';
    if (!names.contains(name)) names.add(name); // a series lists every book's credits: once each
  }
  final roles = byRole.keys.toList()
    ..sort((a, b) {
      final ia = _roleOrder.indexOf(a), ib = _roleOrder.indexOf(b);
      return (ia < 0 ? 99 : ia).compareTo(ib < 0 ? 99 : ib);
    });
  return [
    const DetailsHeading('Credits'),
    for (final r in roles)
      Padding(
        padding: const EdgeInsets.only(bottom: 6),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          SizedBox(width: 110, child: Text(_roleLabel(r, byRole[r]!.length),
              style: const TextStyle(color: Color(0xFF9A9A9A)))),
          Expanded(child: Text(byRole[r]!.join(', '))),
        ]),
      ),
  ];
}

String _roleLabel(String role, int n) {
  final base = role.isEmpty ? 'Other' : role[0].toUpperCase() + role.substring(1);
  return n > 1 && !base.endsWith('s') ? '${base}s' : base;
}

String? detailsDate(String? iso) {
  if (iso == null || iso.isEmpty) return null;
  final d = DateTime.tryParse(iso);
  if (d == null) return iso;
  const months = ['January', 'February', 'March', 'April', 'May', 'June', 'July', 'August', 'September', 'October',
      'November', 'December'];
  return '${d.day} ${months[d.month - 1]} ${d.year}';
}

Widget detailsFact(String label, String? value) => value == null || value.isEmpty
    ? const SizedBox.shrink()
    : Padding(
        padding: const EdgeInsets.only(bottom: 4),
        child: Row(children: [
          SizedBox(width: 90, child: Text(label, style: const TextStyle(color: Color(0xFF9A9A9A)))),
          Expanded(child: Text(value)),
        ]),
      );
