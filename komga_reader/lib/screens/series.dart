import 'package:flutter/material.dart';

import '../api.dart';
import '../paged.dart';
import '../pins.dart';
import '../view_prefs.dart';
import '../widgets/breadcrumb.dart';
import '../widgets/fullscreen_exit.dart';
import '../widgets/poster.dart';
import '../widgets/selection.dart';
import 'actions.dart';
import 'library.dart';
import 'reader.dart';

/// Books of one series, in number order, filterable by read status.
class SeriesScreen extends StatefulWidget {
  const SeriesScreen({super.key, required this.api, required this.series, this.pin});
  final Pin? pin;
  final Komga api;
  final dynamic series;
  @override
  State<SeriesScreen> createState() => _SeriesScreenState();
}

class _SeriesScreenState extends State<SeriesScreen> {
  ReadFilter _filter = ReadFilter.all;
  bool _newestFirst = false; // issue order: oldest first (number ascending) unless flipped
  late final Paged _paged = Paged((page, size) => widget.api.seriesBooks(widget.series['id'],
      readStatus: _filter.api, sort: 'metadata.numberSort,${_newestFirst ? 'desc' : 'asc'}', page: page, size: size));
  String get _viewKey => 'view.series.${widget.series['id']}';
  final _sel = Selection();
  late final Future<String?> _library = widget.api.libraryName(widget.series['libraryId'] as String?); // breadcrumb

  @override
  void initState() {
    super.initState();
    _restore().then((_) { if (mounted) { setState(() {}); _paged.more(); } });
  }

  /// From the pin it was opened from, else this series' remembered view.
  Future<void> _restore() async {
    final pin = widget.pin;
    if (pin != null) {
      _filter = pin.readFilter;
      _newestFirst = pin.sort == 'number:desc';
    } else {
      final v = await ViewPrefs.load(_viewKey);
      _filter = ReadFilterApi.fromName(v['filter']);
      _newestFirst = v['newestFirst'] == true;
    }
  }

  void _save() => ViewPrefs.save(_viewKey, {'filter': _filter.name, 'newestFirst': _newestFirst});

  void _setFilter(ReadFilter f) {
    setState(() => _filter = f);
    _save();
    _paged.reset();
  }

  void _toggleOrder() {
    setState(() => _newestFirst = !_newestFirst);
    _save();
    _paged.reset();
  }

  @override
  void dispose() {
    _paged.dispose();
    _sel.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.series;
    return selectionScope(_sel, (context) => Scaffold(
      appBar: _sel.active
          ? selectionAppBar(context, widget.api, _sel, all: () => _paged.items, onChanged: _paged.refresh)
          : AppBar(
        title: FutureBuilder<String?>(
          future: _library,
          builder: (context, lib) => Breadcrumb(parent: lib.data, title: (s['metadata']?['title'] ?? s['name']) as String),
        ),
        actions: [
          Center(child: CountBadge(paged: _paged)),
          HideReadButton(value: _filter, onChanged: _setFilter),
          // issue order toggle: oldest first <-> newest first
          IconButton(
            tooltip: _newestFirst ? 'Newest first (switch to oldest first)' : 'Oldest first (switch to newest first)',
            onPressed: _toggleOrder,
            icon: Row(mainAxisSize: MainAxisSize.min, children: [
              const Icon(Icons.sort),
              Icon(_newestFirst ? Icons.arrow_downward : Icons.arrow_upward, size: 14),
            ]),
          ),
          const PosterSizeButton(),
          PinButton(current: Pin(
            name: [(s['metadata']?['title'] ?? s['name']) as String, if (_filter == ReadFilter.hideRead) 'unread',
                if (_newestFirst) 'newest first'].join(' · '),
            kind: 'series', id: s['id'] as String, title: (s['metadata']?['title'] ?? s['name']) as String,
            filter: _filter.name,
            sort: _newestFirst ? 'number:desc' : null, // null = oldest first, as pins made before this have
          )),
          SelectButton(selection: _sel),
          IconButton(tooltip: 'Series actions', icon: const Icon(Icons.more_vert),
              onPressed: () => showSeriesActions(context, widget.api, s, onChanged: _paged.refresh, inSeries: true)),
          const FullscreenExit(),
        ],
      ),
      body: PagedPosterGrid(
        paged: _paged,
        itemBuilder: (context, b, i) => bookTile(context, widget.api, b, autofocus: i == 0, onChanged: _paged.refresh,
            selection: _sel, showViewSeries: false, onOpen: () async {
          await Navigator.of(context).push(MaterialPageRoute(builder: (_) => ReaderScreen(api: widget.api, book: b,
              skipRead: _filter == ReadFilter.hideRead)));
          _paged.refresh();
        }),
      ),
    ));
  }
}

/// Series of a collection.
class SeriesListScreen extends StatefulWidget {
  const SeriesListScreen({super.key, required this.api, required this.title, required this.collectionId, this.pin});
  final Pin? pin;
  final Komga api;
  final String title;
  final String collectionId;
  @override
  State<SeriesListScreen> createState() => _SeriesListScreenState();
}

class _SeriesListScreenState extends State<SeriesListScreen> {
  ReadFilter _filter = ReadFilter.all;
  late final Paged _paged = Paged((page, size) =>
      widget.api.series(collectionId: widget.collectionId, readStatus: _filter.api, page: page, size: size));
  String get _viewKey => 'view.collection.${widget.collectionId}';

  @override
  void initState() {
    super.initState();
    (widget.pin != null ? Future.value(widget.pin!.readFilter) : restoreFilter(_viewKey))
        .then((f) { if (mounted) { setState(() => _filter = f); _paged.more(); } });
  }

  void _setFilter(ReadFilter f) {
    setState(() => _filter = f);
    ViewPrefs.save(_viewKey, {'filter': f.name});
    _paged.reset();
  }

  @override
  void dispose() {
    _paged.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Breadcrumb(parent: 'Collections', title: widget.title),
          actions: [
            Center(child: CountBadge(paged: _paged)),
            HideReadButton(value: _filter, onChanged: _setFilter),
            const PosterSizeButton(),
            PinButton(current: Pin(
              name: [widget.title, if (_filter == ReadFilter.hideRead) 'unread'].join(' · '),
              kind: 'collection', id: widget.collectionId, title: widget.title, filter: _filter.name,
            )),
            const FullscreenExit(),
          ]),
      body: PagedPosterGrid(
        paged: _paged,
        itemBuilder: (context, it, i) => seriesTile(context, widget.api, it, autofocus: i == 0,
            onChanged: _paged.refresh, onOpen: () async {
          await Navigator.of(context).push(MaterialPageRoute(builder: (_) => SeriesScreen(api: widget.api, series: it)));
          _paged.refresh();
        }),
      ),
    );
  }
}

/// A screen's remembered read-status filter.
Future<ReadFilter> restoreFilter(String key) async {
  final v = await ViewPrefs.load(key);
  return ReadFilterApi.fromName(v['filter']);
}

/// Shown next to the filter/sort buttons only while something other than the default is active.
class ClearFiltersButton extends StatelessWidget {
  const ClearFiltersButton({super.key, required this.onPressed});
  final VoidCallback onPressed;
  @override
  Widget build(BuildContext context) =>
      IconButton(tooltip: 'Clear filters', icon: const Icon(Icons.filter_alt_off), onPressed: onPressed);
}

/// One-tap toggle in the app bar: "Hide read" (then highlighted as "Showing unread") / back to everything.
/// In-progress books count as unread.
class HideReadButton extends StatelessWidget {
  const HideReadButton({super.key, required this.value, required this.onChanged});
  final ReadFilter value;
  final ValueChanged<ReadFilter> onChanged;
  @override
  Widget build(BuildContext context) {
    // icon only (user's call): crossed-out eye + accent tint while read items are hidden; the name is the tooltip
    final hiding = value == ReadFilter.hideRead;
    final accent = Theme.of(context).colorScheme.primary;
    return IconButton(
      tooltip: hiding ? 'Read hidden (show read)' : 'Hide read',
      isSelected: hiding,
      color: hiding ? accent : null,
      style: hiding ? IconButton.styleFrom(backgroundColor: accent.withValues(alpha: 0.16)) : null,
      icon: Icon(hiding ? Icons.visibility_off : Icons.visibility),
      onPressed: () => onChanged(hiding ? ReadFilter.all : ReadFilter.hideRead),
    );
  }
}
