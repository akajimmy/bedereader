import 'package:flutter/material.dart';

import '../api.dart';
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
  String? _error;

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
      if (mounted) setState(() => _error = '$e');
    }
  }

  Future<void> _toggleRead(bool completed) async {
    try {
      completed ? await api.markUnread(_book['id']) : await api.markRead(_book['id']);
      await _load();
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
    }
  }

  Future<void> _read() async {
    await Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => ReaderScreen(api: api, book: _book, readListId: widget.readListId)));
    _load();
  }

  Future<void> _viewSeries() async {
    final s = _series ?? await api.oneSeries(_book['seriesId'] as String);
    if (s == null || !mounted) return;
    await Navigator.of(context).push(MaterialPageRoute(builder: (_) => SeriesScreen(api: api, series: s)));
    _load();
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
      _fact('Publisher', _series?['metadata']?['publisher'] as String?),
      _fact('Released', _date(m['releaseDate'] as String?)),
      _fact('Pages', pages == 0 ? null : '$pages'),
      _fact('Status', status),
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

    return Scaffold(
      appBar: AppBar(title: const Text('Details')),
      // pull down to refresh (re-reads the book and series from Komga)
      body: RefreshIndicator(onRefresh: _load, child: ListView(
          physics: const AlwaysScrollableScrollPhysics(), padding: const EdgeInsets.fromLTRB(20, 8, 20, 32), children: [
        if (_error != null)
          Padding(padding: const EdgeInsets.only(bottom: 12),
              child: Text(_error!, style: const TextStyle(color: Color(0xFFFF8A80)))),
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
          const _Heading('Summary'),
          Text(summary, style: const TextStyle(fontSize: 15, height: 1.45)),
        ],
        ..._credits(m['authors'] as List?),
      ])),
    );
  }

  List<Widget> _credits(List? authors) {
    if (authors == null || authors.isEmpty) return const [];
    final byRole = <String, List<String>>{};
    for (final a in authors) {
      final role = ((a['role'] as String?) ?? 'other').toLowerCase();
      byRole.putIfAbsent(role, () => []).add(a['name'] as String? ?? '');
    }
    final roles = byRole.keys.toList()
      ..sort((a, b) {
        final ia = _roleOrder.indexOf(a), ib = _roleOrder.indexOf(b);
        return (ia < 0 ? 99 : ia).compareTo(ib < 0 ? 99 : ib);
      });
    return [
      const _Heading('Credits'),
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

  static String _roleLabel(String role, int n) {
    final base = role.isEmpty ? 'Other' : role[0].toUpperCase() + role.substring(1);
    return n > 1 && !base.endsWith('s') ? '${base}s' : base;
  }

  static String? _date(String? iso) {
    if (iso == null || iso.isEmpty) return null;
    final d = DateTime.tryParse(iso);
    if (d == null) return iso;
    const months = ['January', 'February', 'March', 'April', 'May', 'June', 'July', 'August', 'September', 'October',
        'November', 'December'];
    return '${d.day} ${months[d.month - 1]} ${d.year}';
  }

  Widget _fact(String label, String? value) => value == null || value.isEmpty
      ? const SizedBox.shrink()
      : Padding(
          padding: const EdgeInsets.only(bottom: 4),
          child: Row(children: [
            SizedBox(width: 90, child: Text(label, style: const TextStyle(color: Color(0xFF9A9A9A)))),
            Expanded(child: Text(value)),
          ]),
        );
}

class _Heading extends StatelessWidget {
  const _Heading(this.text);
  final String text;
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(top: 24, bottom: 8),
        child: Text(text, style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w500)),
      );
}
