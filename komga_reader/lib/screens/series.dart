import 'package:flutter/material.dart';

import '../api.dart';
import '../paged.dart';
import '../pins.dart';
import '../view_prefs.dart';
import '../widgets/breadcrumb.dart';
import '../widgets/drawer.dart';
import '../widgets/fullscreen_exit.dart';
import '../widgets/poster.dart';
import '../widgets/refresh_on_return.dart';
import '../widgets/selection.dart';
import 'actions.dart';
import 'library.dart';
import 'open_book.dart';

/// Books of one series, in number order, filterable by read status.
class SeriesScreen extends StatefulWidget {
  const SeriesScreen({super.key, required this.api, required this.series, this.pin});
  final Pin? pin;
  final Komga api;
  final dynamic series;
  @override
  State<SeriesScreen> createState() => _SeriesScreenState();
}

class _SeriesScreenState extends State<SeriesScreen> with SideMenuHere, RefreshOnReturn {
  @override
  void refreshView() => _paged.refresh(); // back on top, however it got there (lib/widgets/refresh_on_return.dart)

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
    return withSideMenu(widget.api, (docked) => selectionScope(_sel, (context) => Scaffold(
      key: menuScaffold,
      drawer: menuDrawer(widget.api, docked: docked),
      onDrawerChanged: onMenuChanged,
      appBar: _sel.active
          ? selectionAppBar(context, widget.api, _sel, all: () => _paged.items, onChanged: _paged.refresh)
          : AppBar(
        leading: const BackButton(),
        title: FutureBuilder<String?>(
          future: _library,
          builder: (context, lib) => Breadcrumb(parent: lib.data, title: (s['metadata']?['title'] ?? s['name']) as String,
              onParent: () => LibraryScreen.openFromBreadcrumb(context, widget.api,
                  libraryId: s['libraryId'] as String?, mode: BrowseMode.series)),
        ),
        actions: [
          Center(child: CountBadge(paged: _paged)),
          ReadFilterButton(value: _filter, onChanged: _setFilter),
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
            name: [(s['metadata']?['title'] ?? s['name']) as String, if (_filter.shows != null) _filter.shows!,
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
      body: menuEdge(PagedPosterGrid(
        paged: _paged,
        itemBuilder: (context, b, i) => bookTile(context, widget.api, b, autofocus: i == 0, onChanged: _paged.refresh,
            selection: _sel, showViewSeries: false, onOpen: () async {
          await Navigator.of(context).push(MaterialPageRoute(builder: (_) => readerFor(widget.api, b,
              skipRead: _filter == ReadFilter.hideRead))); // coming back loads afresh: refreshView
        }),
      )),
    )));
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

class _SeriesListScreenState extends State<SeriesListScreen> with SideMenuHere, RefreshOnReturn {
  @override
  void refreshView() => _paged.refresh(); // back on top, however it got there (lib/widgets/refresh_on_return.dart)

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
    return withSideMenu(widget.api, (docked) => Scaffold(
      key: menuScaffold,
      drawer: menuDrawer(widget.api, docked: docked),
      onDrawerChanged: onMenuChanged,
      appBar: AppBar(leading: const BackButton(), title: Breadcrumb(parent: 'Collections', title: widget.title,
              onParent: () => LibraryScreen.openFromBreadcrumb(context, widget.api, anyLibrary: true,
                  mode: BrowseMode.collections)),
          actions: [
            Center(child: CountBadge(paged: _paged)),
            ReadFilterButton(value: _filter, onChanged: _setFilter),
            const PosterSizeButton(),
            PinButton(current: Pin(
              name: [widget.title, if (_filter.shows != null) _filter.shows!].join(' · '),
              kind: 'collection', id: widget.collectionId, title: widget.title, filter: _filter.name,
            )),
            const FullscreenExit(),
          ]),
      body: menuEdge(PagedPosterGrid(
        paged: _paged,
        itemBuilder: (context, it, i) => seriesTile(context, widget.api, it, autofocus: i == 0,
            onChanged: _paged.refresh, onOpen: () async {
          // coming back loads afresh: refreshView
          await Navigator.of(context).push(MaterialPageRoute(builder: (_) => SeriesScreen(api: widget.api, series: it)));
        }),
      )),
    ));
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

/// The eye in the app bar, three-way (user, 2026-10-07): each tap goes All -> Hide read -> Hide unread -> All.
/// In-progress books count as unread.
class ReadFilterButton extends StatelessWidget {
  const ReadFilterButton({super.key, required this.value, required this.onChanged});
  final ReadFilter value;
  final ValueChanged<ReadFilter> onChanged;
  @override
  Widget build(BuildContext context) {
    // icon only (user's call): accent-tinted while something is hidden - a crossed-out eye for read hidden, a tick for
    // only read; the state and the next one are the tooltip
    final on = value != ReadFilter.all;
    final accent = Theme.of(context).colorScheme.primary;
    return IconButton(
      tooltip: switch (value) {
        ReadFilter.all => 'Showing all (hide read)',
        ReadFilter.hideRead => 'Read hidden (hide unread)',
        ReadFilter.hideUnread => 'Unread hidden (show all)',
      },
      isSelected: on,
      color: on ? accent : null,
      style: on ? IconButton.styleFrom(backgroundColor: accent.withValues(alpha: 0.16)) : null,
      icon: Icon(switch (value) {
        ReadFilter.all => Icons.visibility,
        ReadFilter.hideRead => Icons.visibility_off,
        ReadFilter.hideUnread => Icons.task_alt,
      }),
      onPressed: () => onChanged(ReadFilter.values[(value.index + 1) % ReadFilter.values.length]),
    );
  }
}
