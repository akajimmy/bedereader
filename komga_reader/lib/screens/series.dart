import 'package:flutter/material.dart';

import '../api.dart';
import '../paged.dart';
import '../pins.dart';
import '../view_prefs.dart';
import '../view_sort.dart';
import '../widgets/breadcrumb.dart';
import '../widgets/drawer.dart';
import '../widgets/poster.dart';
import '../widgets/refresh_on_return.dart';
import '../widgets/selection.dart';
import '../widgets/view_bar.dart';
import 'actions.dart';
import 'library.dart';
import 'open_book.dart';

/// Books of one series, in number order (or another sort), filterable by read status.
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
  ViewSort _sort = ViewSort.first(seriesBookSorts); // issue order: oldest first unless changed
  late final Paged _paged = Paged((page, size) => seriesBooksPage(widget.api, widget.series['id'] as String, _sort,
      readStatus: _filter.api, page: page, size: size));
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
      _sort = ViewSort.fromPin(seriesBookSorts, pin.sort); // "number:desc": newest first; none: oldest first
    } else {
      final v = await ViewPrefs.load(_viewKey);
      _filter = ReadFilterApi.fromName(v['filter']);
      _sort = ViewSort.of(seriesBookSorts, v['sort'], v['desc']);
    }
  }

  void _save() => ViewPrefs.save(_viewKey, {'filter': _filter.name, 'sort': _sort.key, 'desc': _sort.desc});

  void _setFilter(ReadFilter f) {
    setState(() => _filter = f);
    _save();
    _paged.reset();
  }

  void _setSort(ViewSort s) {
    setState(() => _sort = s);
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
    final title = (s['metadata']?['title'] ?? s['name']) as String;
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
          builder: (context, lib) => Breadcrumb(parent: lib.data, title: title,
              onParent: () => LibraryScreen.openFromBreadcrumb(context, widget.api,
                  libraryId: s['libraryId'] as String?, mode: BrowseMode.series)),
        ),
        actions: viewBarActions(
          paged: _paged,
          filter: _filter, onFilter: _setFilter,
          sort: SortMenuButton(fields: seriesBookSorts, value: _sort, onChanged: _setSort),
          select: _sel,
          pin: Pin(
            name: [title, if (_filter.shows != null) _filter.shows!, if (_sort.words(seriesBookSorts) != null)
                _sort.words(seriesBookSorts)!].join(' · '),
            kind: 'series', id: s['id'] as String, title: title,
            filter: _filter.name,
            // null = oldest first, as pins made before sorts have; "number:desc" newest first, as it always was
            sort: _sort.isDefault(seriesBookSorts) ? null : _sort.pinValue,
          ),
          onRefresh: _paged.refresh,
          onMore: () => showSeriesActions(context, widget.api, s, onChanged: _paged.refresh, inSeries: true),
          moreTooltip: 'Series actions',
        ),
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
  ViewSort _sort = ViewSort.first(collectionSeriesSorts);
  late final Paged _paged = Paged((page, size) => collectionSeriesPage(widget.api, widget.collectionId, _sort,
      readStatus: _filter.api, page: page, size: size));
  String get _viewKey => 'view.collection.${widget.collectionId}';

  @override
  void initState() {
    super.initState();
    _restore().then((_) { if (mounted) { setState(() {}); _paged.more(); } });
  }

  /// From the pin it was opened from, else this collection's remembered view.
  Future<void> _restore() async {
    final pin = widget.pin;
    if (pin != null) {
      _filter = pin.readFilter;
      _sort = ViewSort.fromPin(collectionSeriesSorts, pin.sort);
    } else {
      final v = await ViewPrefs.load(_viewKey);
      _filter = ReadFilterApi.fromName(v['filter']);
      _sort = ViewSort.of(collectionSeriesSorts, v['sort'], v['desc']);
    }
  }

  void _save() => ViewPrefs.save(_viewKey, {'filter': _filter.name, 'sort': _sort.key, 'desc': _sort.desc});

  void _setFilter(ReadFilter f) {
    setState(() => _filter = f);
    _save();
    _paged.reset();
  }

  void _setSort(ViewSort s) {
    setState(() => _sort = s);
    _save();
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
          actions: viewBarActions(
            paged: _paged,
            filter: _filter, onFilter: _setFilter,
            sort: SortMenuButton(fields: collectionSeriesSorts, value: _sort, onChanged: _setSort),
            pin: Pin(
              name: [widget.title, if (_filter.shows != null) _filter.shows!,
                  if (_sort.words(collectionSeriesSorts) != null) _sort.words(collectionSeriesSorts)!].join(' · '),
              kind: 'collection', id: widget.collectionId, title: widget.title, filter: _filter.name,
              sort: _sort.isDefault(collectionSeriesSorts) ? null : _sort.pinValue, // null: as pins made before sorts
            ),
            onRefresh: _paged.refresh,
          )),
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
