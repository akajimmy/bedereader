import 'dart:async';

import 'package:flutter/material.dart';

import '../book_title.dart';
import '../combined_source.dart';
import '../errors.dart';
import '../local/library_fs.dart' show splitUnc;
import '../local/local_source.dart';
import '../offline/downloads.dart';
import '../pins.dart';
import '../widgets/arrow_scroll.dart';
import '../widgets/fullscreen_exit.dart';
import '../widgets/source_badge.dart';
import '../widgets/error_text.dart';
import 'open_book.dart';
import 'series.dart';
import '../book_source.dart';

/// One book's details: cover, title, series and number, publisher, release date, pages, read status, summary and
/// credits (grouped by role), with Read / Mark read or unread / View series. Fetched fresh from Komga.
class BookDetailsScreen extends StatefulWidget {
  const BookDetailsScreen({super.key, required this.api, required this.book, this.readListId, this.showViewSeries = true});
  final BookSource api;
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
  String? _root; // its library's folder (local) or root (Komga): its path shown from there
  bool _gone = false; // its file missing: Not Found

  BookSource get api => widget.api;

  @override
  void initState() {
    super.initState();
    _load();
    _whereItIs();
  }

  /// Where the book's file is - its library's root, for its path - and whether the file is still there (user,
  /// 2026-10-26).
  Future<void> _whereItIs() async {
    final id = _book['id'] as String;
    final from = CombinedSource.of(api, id);
    String? root;
    var gone = false;
    try {
      if (from is LocalSource) {
        root = from.libraryPath(_book['libraryId'] as String? ?? '');
        gone = await from.fileGone(id);
      } else {
        gone = _book['deleted'] == true;
        final libs = await from.keptLibraries();
        root = libs.where((l) => (l as Map)['id'] == _book['libraryId']).firstOrNull?['root'] as String?;
      }
    } catch (_) {
      // (Komga out of reach: the path shown whole)
    }
    if (mounted) setState(() { _root = root; _gone = gone; });
  }

  Future<void> _load() async {
    try {
      // together, not one after the other (code review 2026-10-05, #47)
      // (Future.wait throws the first error as it is: a record's .wait would wrap it, and explain() wouldn't know it)
      final both = await Future.wait([api.book(_book['id'] as String), api.oneSeries(_book['seriesId'] as String)]);
      final fresh = both[0], series = both[1];
      if (mounted) setState(() { if (fresh != null) _book = fresh; _series = series; _error = null; });
      if (fresh?['deleted'] == true && mounted) setState(() => _gone = true); // (Komga: its file gone)
    } catch (e) {
      if (mounted) setState(() => _error = e);
    }
  }

  Future<void> _toggleRead(bool completed) async {
    try {
      completed ? await api.markUnread(_book['id']) : await api.markRead(_book['id']);
      await _load();
    } catch (e, st) {
      final title = bookTitle(_book);
      if (mounted) {
        showErrorSnack(context, couldnt('mark "$title" as ${completed ? 'unread' : 'read'}', e, thing: 'book'), e, st);
      }
    }
  }

  Future<void> _read() async {
    await Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => readerFor(api, _book, readListId: widget.readListId)));
    unawaited(_load()); // back from the reader: read state may have changed
  }

  Future<void> _viewSeries() async {
    final dynamic s;
    try {
      final found = _series ?? await api.oneSeries(_book['seriesId'] as String);
      if (found == null) throw StateError('series not found');
      s = found;
    } catch (e, st) {
      // it said nothing (code review 2026-10-05, #28)
      if (mounted) showErrorSnack(context, couldnt('open the series', e, thing: 'series'), e, st);
      return;
    }
    if (!mounted) return;
    await Navigator.of(context).push(MaterialPageRoute(builder: (_) => SeriesScreen(api: api, series: s)));
    unawaited(_load()); // back from the series: read state may have changed
  }

  @override
  Widget build(BuildContext context) {
    final id = _book['id'] as String;
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
      // above the title: a comic's series and number, an eBook's author (user, 2026-10-18)
      Text(isEbook(_book) ? bookAuthors(_book) : bookSeriesLine(_book),
          style: const TextStyle(fontSize: 15, color: Color(0xFF9A9A9A))),
      const SizedBox(height: 4),
      Text((m['title'] ?? _book['name'] ?? '') as String, style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w500)),
      // Downloaded, Cached (the books opened lately, kept), Not Found (user, 2026-10-26)
      ListenableBuilder(
        listenable: Downloads.instance,
        builder: (context, _) => BookBadges(
            downloaded: Downloads.instance.isDownloaded(id), cached: Downloads.instance.isCached(id), gone: _gone),
      ),
      const SizedBox(height: 12),
      detailsFact('Publisher', _series?['metadata']?['publisher'] as String?),
      detailsFact('Released', detailsDate(m['releaseDate'] as String?, precision: m['releaseDatePrecision'] as String?)),
      detailsFact('Pages', pages == 0 ? null : '$pages'),
      detailsFact('Status', status),
      // where it comes from, where its file is, what kind of file (user, 2026-10-26)
      detailsFactRow('Source', SourceLine(originOf(api, id), url: _book['url'] as String?)),
      if (_book['url'] case final String url when url.isNotEmpty) detailsFact('Path', pathInLibrary(url, _root)),
      detailsFact('Format', bookFormat(_book as Map)),
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
      // pinned to Home from here too (user, 2026-10-16), as a series or a read list from theirs
      appBar: AppBar(title: const Text('Details'),
          actions: [PinButton(current: Pin.book(_book)), const FullscreenExit()]),
      // pull down to refresh (re-reads the book and series from Komga)
      // above Android's navigation bar (the app is drawn edge to edge, under it): the remote's focus was scrolled to an
      // edge behind it (user, 2026-10-07)
      body: SafeArea(top: false, child: RefreshIndicator(onRefresh: _load, child: ListView(controller: scroll,
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
      ]))),
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

/// [precision]: how much of the date is known - 'year' ("2012"), 'month' ("March 2012"), else the whole date. Local
/// books say (their ComicInfo, their file's name); Komga's don't (shown as Komga gives them).
String? detailsDate(String? iso, {String? precision}) {
  if (iso == null || iso.isEmpty) return null;
  final d = DateTime.tryParse(iso);
  if (d == null) return iso;
  const months = ['January', 'February', 'March', 'April', 'May', 'June', 'July', 'August', 'September', 'October',
      'November', 'December'];
  return switch (precision) {
    'year' => '${d.year}',
    'month' => '${months[d.month - 1]} ${d.year}',
    _ => '${d.day} ${months[d.month - 1]} ${d.year}',
  };
}

/// A release date for a poster: "13 Mar 2024" (user, 2026-10-06); null if there's none.
String? posterDate(String? iso, {String? precision}) {
  if (iso == null || iso.isEmpty) return null;
  final d = DateTime.tryParse(iso);
  if (d == null) return null;
  const months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
  return switch (precision) { // ([detailsDate]'s)
    'year' => '${d.year}',
    'month' => '${months[d.month - 1]} ${d.year}',
    _ => '${d.day} ${months[d.month - 1]} ${d.year}',
  };
}

Widget detailsFact(String label, String? value) =>
    value == null || value.isEmpty ? const SizedBox.shrink() : detailsFactRow(label, Text(value));

Widget detailsFactRow(String label, Widget value) => Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        SizedBox(width: 90, child: Text(label, style: const TextStyle(color: Color(0xFF9A9A9A)))),
        Expanded(child: value),
      ]),
    );

/// A book's file format, as its file name says ("CBZ", "CBR", "EPUB", "PDF"), else its media type's.
String? bookFormat(Map book) {
  final m = RegExp(r'\.([A-Za-z0-9]{2,5})$').firstMatch(((book['url'] as String?) ?? '').trim());
  if (m != null) return m[1]!.toUpperCase();
  final type = '${(book['media'] as Map?)?['mediaType'] ?? ''}';
  return type.contains('epub')
      ? 'EPUB'
      : type.contains('rar')
          ? 'CBR'
          : type.contains('pdf')
              ? 'PDF'
              : type.contains('zip')
                  ? 'CBZ'
                  : null;
}

/// [url] from its library's [root] on, with forward slashes ("Saga (2012)/Saga #10 (2014).cbz"); the whole of it when
/// the root isn't known or doesn't hold it.
String pathInLibrary(String url, String? root) {
  final u = url.replaceAll(r'\', '/');
  final r = root?.replaceAll(r'\', '/').replaceAll(RegExp(r'/+$'), '');
  if (r != null && r.isNotEmpty && u.toLowerCase().startsWith('${r.toLowerCase()}/')) return u.substring(r.length + 1);
  return u;
}

/// Where a book comes from, after its icon: Local, Network (and its server), Komga.
class SourceLine extends StatelessWidget {
  const SourceLine(this.origin, {super.key, this.url});
  final Origin origin;
  final String? url; // (a network book's: its server named)

  @override
  Widget build(BuildContext context) {
    final host = url == null ? null : splitUnc(url!)?.$1;
    return Row(children: [
      SourceIcon(origin, size: 18),
      const SizedBox(width: 6),
      Flexible(child: Text(switch (origin) {
        Origin.local => 'Local',
        Origin.network => host == null ? 'Network' : 'Network · $host',
        Origin.komga => 'Komga',
      })),
    ]);
  }
}

/// A book's badges: Downloaded (on purpose), Cached (opened lately, kept: lib/offline/downloads.dart's cache), Not
/// Found (its file gone - from Komga's disk, or from a local or network library) - user, 2026-10-26.
class BookBadges extends StatelessWidget {
  const BookBadges({super.key, required this.downloaded, required this.cached, required this.gone});
  final bool downloaded, cached, gone;

  @override
  Widget build(BuildContext context) {
    final badges = [
      if (downloaded) ('Downloaded', Icons.download_done, const Color(0xFF60A5FA)),
      if (cached) ('Cached', Icons.history, const Color(0xFF9A9A9A)),
      if (gone) ('Not Found', Icons.error_outline, const Color(0xFFFACC15)),
    ];
    if (badges.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Wrap(spacing: 8, runSpacing: 6, children: [
        for (final (label, icon, colour) in badges)
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
            decoration: BoxDecoration(
                border: Border.all(color: colour.withValues(alpha: 0.7)), borderRadius: BorderRadius.circular(12)),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              Icon(icon, size: 14, color: colour),
              const SizedBox(width: 4),
              Text(label, style: TextStyle(fontSize: 12.5, color: colour)),
            ]),
          ),
      ]),
    );
  }
}
