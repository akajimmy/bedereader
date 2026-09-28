import 'package:flutter/material.dart';

import '../api.dart';
import '../paged.dart';
import '../pins.dart';
import '../view_prefs.dart';
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
  late final Paged _paged = Paged((page, size) =>
      widget.api.seriesBooks(widget.series['id'], readStatus: _filter.api, page: page, size: size));
  String get _viewKey => 'view.series.${widget.series['id']}';
  final _sel = Selection();

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
        title: Text((s['metadata']?['title'] ?? s['name']) as String),
        actions: [
          HideReadButton(value: _filter, onChanged: _setFilter),
          PinButton(current: Pin(
            name: [(s['metadata']?['title'] ?? s['name']) as String, if (_filter == ReadFilter.hideRead) 'unread'].join(' · '),
            kind: 'series', id: s['id'] as String, title: (s['metadata']?['title'] ?? s['name']) as String,
            filter: _filter.name,
          )),
          SelectButton(selection: _sel),
          IconButton(tooltip: 'Series actions', icon: const Icon(Icons.more_vert),
              onPressed: () => showSeriesActions(context, widget.api, s, onChanged: _paged.refresh)),
        ],
      ),
      body: PagedPosterGrid(
        paged: _paged,
        itemBuilder: (context, b, i) => bookTile(context, widget.api, b, autofocus: i == 0, onChanged: _paged.refresh,
            selection: _sel, showViewSeries: false, onOpen: () async {
          await Navigator.of(context).push(MaterialPageRoute(builder: (_) => ReaderScreen(api: widget.api, book: b)));
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
      appBar: AppBar(title: Text(widget.title),
          actions: [
            HideReadButton(value: _filter, onChanged: _setFilter),
            PinButton(current: Pin(
              name: [widget.title, if (_filter == ReadFilter.hideRead) 'unread'].join(' · '),
              kind: 'collection', id: widget.collectionId, title: widget.title, filter: _filter.name,
            )),
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
    final hiding = value == ReadFilter.hideRead;
    final accent = Theme.of(context).colorScheme.primary;
    if (MediaQuery.sizeOf(context).width < 600) {
      // narrow screens: icon only, highlighted while read books are hidden
      return IconButton(
        tooltip: hiding ? 'Show read' : 'Hide read',
        isSelected: hiding,
        color: hiding ? accent : null,
        icon: Icon(hiding ? Icons.visibility_off : Icons.visibility),
        onPressed: () => onChanged(hiding ? ReadFilter.all : ReadFilter.hideRead),
      );
    }
    return TextButton.icon(
      onPressed: () => onChanged(hiding ? ReadFilter.all : ReadFilter.hideRead),
      style: TextButton.styleFrom(
        foregroundColor: hiding ? accent : const Color(0xFFBDBDBD),
        backgroundColor: hiding ? accent.withValues(alpha: 0.14) : null,
      ),
      icon: Icon(hiding ? Icons.visibility_off : Icons.visibility),
      label: Text(hiding ? 'Read hidden' : 'Hide read'),
    );
  }
}
