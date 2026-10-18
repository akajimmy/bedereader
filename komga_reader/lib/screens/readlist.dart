import 'package:flutter/material.dart';

import '../api.dart';
import '../paged.dart';
import '../pins.dart';
import '../view_filter.dart';
import '../view_prefs.dart';
import '../view_sort.dart';
import '../widgets/breadcrumb.dart';
import '../widgets/drawer.dart';
import '../widgets/filter_panel.dart';
import '../widgets/poster.dart';
import '../widgets/refresh_on_return.dart';
import '../widgets/selection.dart';
import '../widgets/view_bar.dart';
import 'actions.dart';
import 'library.dart';
import 'open_book.dart';

/// A read list (event / era) in its own order, e.g. "only the unread books of Civil War".
/// Books opened from here continue to the next book of the list, not the next of the series.
class ReadListScreen extends StatefulWidget {
  const ReadListScreen({super.key, required this.api, required this.readList, this.pin});
  final Pin? pin;
  final Komga api;
  final dynamic readList;
  @override
  State<ReadListScreen> createState() => _ReadListScreenState();
}

class _ReadListScreenState extends State<ReadListScreen> with SideMenuHere, RefreshOnReturn, ViewFilters {
  @override
  void refreshView() => _paged.refresh(); // back on top, however it got there (lib/widgets/refresh_on_return.dart)

  ReadFilter _filter = ReadFilter.all;
  ViewSort _sort = ViewSort.first(readListBookSorts);
  late final Paged _paged = Paged((page, size) => readListBooksPage(widget.api, _id, _sort,
      read: _filter, filter: filters, page: page, size: size));
  String get _id => widget.readList['id'] as String;
  String get _viewKey => 'view.readlist.${widget.readList['id']}';
  final _sel = Selection();

  // ---- the filter panel: book filters
  @override
  bool get filtersSeriesView => false;

  @override
  Future<ViewKind> askFilterKind() => widget.api.viewKind(readListId: _id);

  @override
  FilterScope filterScope(Future<ViewKind> kind) => FilterScope(api: widget.api, seriesView: false, readListId: _id,
      kind: kind, count: (draft) => countOf((page, size) =>
          // counted in list order, first to last: one page, never the whole list turned round
          readListBooksPage(widget.api, _id, ViewSort.first(readListBookSorts), read: _filter, filter: draft,
              page: page, size: size)));

  @override
  void applyFilters(ViewFilter f) {
    setState(() => filters = f);
    _save();
    _paged.reset();
  }

  @override
  void initState() {
    super.initState();
    _restore().then((_) { if (mounted) { setState(() {}); _paged.more(); } });
  }

  /// From the pin it was opened from, else this list's remembered view.
  Future<void> _restore() async {
    final pin = widget.pin;
    if (pin != null) {
      _filter = pin.readFilter;
      _sort = ViewSort.fromPin(readListBookSorts, pin.sort);
      filters = pin.filters;
    } else {
      final v = await ViewPrefs.load(_viewKey);
      _filter = ReadFilterApi.fromName(v['filter']);
      _sort = ViewSort.of(readListBookSorts, v['sort'], v['desc']);
      filters = ViewPrefs.filtersOf(v);
    }
  }

  void _save() => ViewPrefs.save(_viewKey,
      ViewPrefs.withFilters({'filter': _filter.name, 'sort': _sort.key, 'desc': _sort.desc}, filters));

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
    final rlId = widget.readList['id'] as String;
    final name = widget.readList['name'] as String;
    return withSideMenu(widget.api, (docked) => selectionScope(_sel, (context) => Scaffold(
      key: menuScaffold,
      drawer: menuDrawer(widget.api, docked: docked),
      onDrawerChanged: onMenuChanged,
      appBar: _sel.active
          ? selectionAppBar(context, widget.api, _sel, all: () => _paged.items, onChanged: _paged.refresh)
          : AppBar(
        leading: const BackButton(),
        title: Breadcrumb(parent: 'Read lists', title: name,
            onParent: () => LibraryScreen.openFromBreadcrumb(context, widget.api, anyLibrary: true,
                mode: BrowseMode.readLists)),
        bottom: filterChips(),
        actions: viewBarActions(
          paged: _paged,
          filter: _filter, onFilter: _setFilter,
          filters: filterButton(),
          sort: SortMenuButton(fields: readListBookSorts, value: _sort, onChanged: _setSort),
          select: _sel,
          pin: Pin(
            name: [name, if (_filter.shows != null) _filter.shows!,
                if (_sort.words(readListBookSorts) != null) _sort.words(readListBookSorts)!,
                ...filterWords()].join(' · '),
            kind: 'readlist', id: rlId, title: name, filter: _filter.name, filters: activeFilters,
            sort: _sort.isDefault(readListBookSorts) ? null : _sort.pinValue, // null: as pins made before sorts
          ),
          onRefresh: _paged.refresh,
          onMore: () => showReadListActions(context, widget.api, widget.readList, onChanged: () {
            setState(() {}); // renamed: the title and the pin button's name
            _paged.refresh();
          }),
          moreTooltip: 'Read list actions',
        ),
      ),
      body: menuEdge(PagedPosterGrid(
        paged: _paged,
        empty: _filter.shows == null ? 'Nothing here' : 'Nothing ${_filter.shows} in this list',
        itemBuilder: (context, b, i) => bookTile(context, widget.api, b, autofocus: i == 0,
            readListId: rlId, onChanged: _paged.refresh, selection: _sel, onOpen: () async {
          await Navigator.of(context).push(MaterialPageRoute(
              builder: (_) => readerFor(widget.api, b, readListId: rlId,
                  skipRead: _filter == ReadFilter.hideRead))); // coming back loads afresh: refreshView
        }),
      )),
    )));
  }
}
