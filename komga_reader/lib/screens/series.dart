import 'package:flutter/material.dart';

import '../api.dart';
import '../paged.dart';
import '../pins.dart';
import '../settings.dart';
import '../view_filter.dart';
import '../view_sort.dart';
import '../widgets/breadcrumb.dart';
import '../widgets/drawer.dart';
import '../widgets/filter_panel.dart';
import '../widgets/poster.dart';
import '../widgets/refresh_on_return.dart';
import '../widgets/remembered_view.dart';
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

class _SeriesScreenState extends State<SeriesScreen> with SideMenuHere, RefreshOnReturn, ViewFilters, RememberedView {
  @override
  void refreshView() => _paged.refresh(); // back on top, however it got there (lib/widgets/refresh_on_return.dart)

  @override
  List<SortField> get sorts => seriesBookSorts; // issue order: oldest first unless changed
  @override
  Pin? get pin => widget.pin;
  @override
  Paged get paged => _paged;
  late final Paged _paged = Paged((page, size) => seriesBooksPage(widget.api, _id, sort,
      read: readFilter, filter: filters, page: page, size: size));
  String get _id => widget.series['id'] as String;
  @override
  String get viewKey => 'view.series.${widget.series['id']}';

  // ---- the filter panel: book filters
  @override
  bool get filtersSeriesView => false;

  /// The series' books say what they are (their media profiles) once some are listed; else Komga is asked.
  @override
  Future<ViewKind> askFilterKind() => _paged.items.isEmpty
      ? widget.api.viewKind(seriesId: _id)
      : Future.value(ViewKind.ofProfiles([for (final b in _paged.items) (b['media'] as Map?)?['mediaProfile']]));

  @override
  FilterScope filterScope(Future<ViewKind> kind) => FilterScope(api: widget.api, seriesView: false, seriesId: _id,
      kind: kind, count: (draft) => countOf((page, size) =>
          seriesBooksPage(widget.api, _id, sort, read: readFilter, filter: draft, page: page, size: size)));

  final _sel = Selection();
  late final Future<String?> _library = widget.api.libraryName(widget.series['libraryId'] as String?); // breadcrumb

  @override
  void initState() {
    super.initState();
    openView();
    _noteWebtoon();
  }

  /// Whether Komga has this series as a webtoon - its episodes' posters are then its cover (user, 2026-10-22: on
  /// the tablet the episodes showed their first pages - nothing had told the app yet): from the series as it came
  /// (Komga's own always has its metadata), else - opened with only its id and name - Komga is asked.
  Future<void> _noteWebtoon() async {
    final metadata = widget.series['metadata'] as Map?;
    Object? direction = metadata?['readingDirection'];
    if (metadata == null) {
      try {
        direction = (await widget.api.oneSeries(_id))?['metadata']?['readingDirection'];
      } catch (_) {
        return; // (unknown: as it was)
      }
    }
    if (AppSettings.instance.noteDirection(_id, direction) && mounted) setState(() {});
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
        bottom: filterChips(),
        actions: viewBarActions(
          paged: _paged,
          filter: readFilter, onFilter: setReadFilter,
          filters: filterButton(),
          sort: SortMenuButton(fields: seriesBookSorts, value: sort, onChanged: setViewSort),
          select: _sel,
          pin: Pin(
            name: [title, if (readFilter.shows != null) readFilter.shows!, if (sort.words(seriesBookSorts) != null)
                sort.words(seriesBookSorts)!, ...filterWords()].join(' · '),
            kind: 'series', id: s['id'] as String, title: title,
            filter: readFilter.name, filters: activeFilters,
            // null = oldest first, as pins made before sorts have; "number:desc" newest first, as it always was
            sort: sort.isDefault(seriesBookSorts) ? null : sort.pinValue,
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
              skipRead: readFilter == ReadFilter.hideRead))); // coming back loads afresh: refreshView
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

class _SeriesListScreenState extends State<SeriesListScreen> with SideMenuHere, RefreshOnReturn, ViewFilters, RememberedView {
  @override
  void refreshView() => _paged.refresh(); // back on top, however it got there (lib/widgets/refresh_on_return.dart)

  @override
  List<SortField> get sorts => collectionSeriesSorts;
  @override
  Pin? get pin => widget.pin;
  @override
  Paged get paged => _paged;
  late final Paged _paged = Paged((page, size) => collectionSeriesPage(widget.api, widget.collectionId, sort,
      read: readFilter, filter: filters, page: page, size: size));
  @override
  String get viewKey => 'view.collection.${widget.collectionId}';
  final _sel = Selection();

  // ---- the filter panel: series filters
  @override
  bool get filtersSeriesView => true;

  /// A collection can span libraries: the kinds of the libraries its listed series are in (all shown libraries
  /// while none are listed).
  @override
  Future<ViewKind> askFilterKind() async {
    final libraries = {for (final s in _paged.items) (s as Map)['libraryId'] as String?}.whereType<String>();
    if (libraries.isEmpty) return widget.api.viewKind();
    return ViewKind.combine(await Future.wait([for (final l in libraries) widget.api.viewKind(libraryId: l)]));
  }

  @override
  FilterScope filterScope(Future<ViewKind> kind) => FilterScope(api: widget.api, seriesView: true,
      collectionId: widget.collectionId, kind: kind, count: (draft) => countOf((page, size) =>
          // counted by title: the same series, without the whole collection that its own order needs
          collectionSeriesPage(widget.api, widget.collectionId, const ViewSort('title', false), read: readFilter,
              filter: draft, page: page, size: size)));


  @override
  void initState() {
    super.initState();
    openView();
  }

  @override
  void dispose() {
    _paged.dispose();
    _sel.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return withSideMenu(widget.api, (docked) => selectionScope(_sel, (context) => Scaffold(
      key: menuScaffold,
      drawer: menuDrawer(widget.api, docked: docked),
      onDrawerChanged: onMenuChanged,
      appBar: _sel.active
          ? selectionAppBar(context, widget.api, _sel, all: () => _paged.items, onChanged: _paged.refresh, series: true)
          : AppBar(leading: const BackButton(), title: Breadcrumb(parent: 'Collections', title: widget.title,
              onParent: () => LibraryScreen.openFromBreadcrumb(context, widget.api, anyLibrary: true,
                  mode: BrowseMode.collections)),
          bottom: filterChips(),
          actions: viewBarActions(
            paged: _paged,
            filter: readFilter, onFilter: setReadFilter,
            filters: filterButton(),
            sort: SortMenuButton(fields: collectionSeriesSorts, value: sort, onChanged: setViewSort),
            select: _sel,
            pin: Pin(
              name: [widget.title, if (readFilter.shows != null) readFilter.shows!,
                  if (sort.words(collectionSeriesSorts) != null) sort.words(collectionSeriesSorts)!,
                  ...filterWords()].join(' · '),
              kind: 'collection', id: widget.collectionId, title: widget.title, filter: readFilter.name,
              filters: activeFilters,
              sort: sort.isDefault(collectionSeriesSorts) ? null : sort.pinValue, // null: as pins made before sorts
            ),
            onRefresh: _paged.refresh,
          )),
      body: menuEdge(PagedPosterGrid(
        paged: _paged,
        itemBuilder: (context, it, i) => seriesTile(context, widget.api, it, autofocus: i == 0,
            onChanged: _paged.refresh, selection: _sel, onOpen: () async {
          // coming back loads afresh: refreshView
          await Navigator.of(context).push(MaterialPageRoute(builder: (_) => SeriesScreen(api: widget.api, series: it)));
        }),
      )),
    )));
  }
}
