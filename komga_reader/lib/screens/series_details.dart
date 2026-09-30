import 'package:flutter/material.dart';

import '../api.dart';
import '../errors.dart';
import '../widgets/fullscreen_exit.dart';
import '../widgets/error_text.dart';
import 'book_details.dart';
import 'library.dart';
import 'series.dart';

/// One series' details (series menu > Details): poster, title, publisher, status, first release, books and how many
/// are read, language, age rating, genres and tags, summary, and the credits of all its books grouped by role -
/// with Open series (hidden when already in it). Fetched fresh from Komga; pull down to refresh.
class SeriesDetailsScreen extends StatefulWidget {
  const SeriesDetailsScreen({super.key, required this.api, required this.series, this.showOpen = true});
  final Komga api;
  final dynamic series;
  final bool showOpen;
  @override
  State<SeriesDetailsScreen> createState() => _SeriesDetailsScreenState();
}

class _SeriesDetailsScreenState extends State<SeriesDetailsScreen> {
  late dynamic _series = widget.series;
  Object? _error; // shown through lib/errors.dart

  Komga get api => widget.api;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final fresh = await api.oneSeries(_series['id'] as String);
      if (mounted) setState(() { if (fresh != null) _series = fresh; _error = null; });
    } catch (e) {
      if (mounted) setState(() => _error = e);
    }
  }

  Future<void> _open() async {
    await Navigator.of(context).push(MaterialPageRoute(builder: (_) => SeriesScreen(api: api, series: _series)));
    _load();
  }

  static String? _status(String? s) => switch (s) {
        'ONGOING' => 'Ongoing',
        'ENDED' => 'Ended',
        'HIATUS' => 'On hiatus',
        'ABANDONED' => 'Abandoned',
        _ => null,
      };

  @override
  Widget build(BuildContext context) {
    final m = _series['metadata'] ?? {};
    final bm = _series['booksMetadata'] ?? {};
    final summary = ((m['summary'] as String?)?.trim().isNotEmpty ?? false)
        ? (m['summary'] as String).trim()
        : ((bm['summary'] as String?)?.trim() ?? '');
    final age = m['ageRating'];
    final wide = MediaQuery.sizeOf(context).width >= 700;
    final chips = [
      for (final g in (m['genres'] as List?) ?? const []) '$g',
      for (final t in (m['tags'] as List?) ?? const []) '$t',
    ];

    final poster = ClipRRect(
      borderRadius: BorderRadius.circular(6),
      child: AspectRatio(
        aspectRatio: 0.66,
        child: Image(image: api.thumbImage(api.seriesThumb(_series['id'] as String)), fit: BoxFit.cover,
            errorBuilder: (_, __, ___) => const ColoredBox(color: Color(0xFF1C1C1F))),
      ),
    );

    final facts = Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text((m['title'] ?? _series['name'] ?? '') as String, style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w500)),
      const SizedBox(height: 12),
      detailsFact('Publisher', m['publisher'] as String?),
      detailsFact('Status', _status(m['status'] as String?)),
      detailsFact('First out', detailsDate(bm['releaseDate'] as String?)),
      detailsFact('Books', seriesStatus(_series)),
      detailsFact('Language', (m['language'] as String?)?.toUpperCase()),
      detailsFact('Age rating', age == null ? null : '$age+'),
      if (widget.showOpen) ...[
        const SizedBox(height: 16),
        FilledButton.icon(autofocus: true, onPressed: _open, icon: const Icon(Icons.collections_bookmark_outlined),
            label: const Text('Open series')),
      ],
    ]);

    return Scaffold(
      appBar: AppBar(title: const Text('Series details'), actions: const [FullscreenExit()]),
      body: RefreshIndicator(onRefresh: _load, child: ListView(
          physics: const AlwaysScrollableScrollPhysics(), padding: const EdgeInsets.fromLTRB(20, 8, 20, 32), children: [
        if (_error != null)
          Padding(padding: const EdgeInsets.only(bottom: 12),
              child: ErrorText(explain(_error!, thing: 'series').message, _error!)),
        wide
            ? Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                SizedBox(width: 220, child: poster),
                const SizedBox(width: 24),
                Expanded(child: facts),
              ])
            : Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Center(child: SizedBox(width: 200, child: poster)),
                const SizedBox(height: 16),
                facts,
              ]),
        if (chips.isNotEmpty) ...[
          const DetailsHeading('Genres and tags'),
          Wrap(spacing: 8, runSpacing: 8, children: [for (final c in chips) Chip(label: Text(c))]),
        ],
        if (summary.isNotEmpty) ...[
          const DetailsHeading('Summary'),
          Text(summary, style: const TextStyle(fontSize: 15, height: 1.45)),
        ],
        ...creditsSection(bm['authors'] as List?),
      ])),
    );
  }
}
