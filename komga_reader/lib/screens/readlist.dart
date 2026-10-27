import 'package:flutter/material.dart';

import '../api.dart';
import '../paged.dart';
import '../pins.dart';
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
import '../book_source.dart';

/// A read list (event / era) in its own order, e.g. "only the unread books of Civil War".
/// Books opened from here continue to the next book of the list, not the next of the series.
class ReadListScreen extends StatefulWidget {
  const ReadListScreen({super.key, required this.api, required this.readList, this.pin});
  final Pin? pin;
  final BookSource api;
  final dynamic readList;
  @override
  State<ReadListScreen> createState() => _ReadListScreenState();
}

class _ReadListScreenState extends State<ReadListScreen> with SideMenuHere, RefreshOnReturn, ViewFilters, RememberedView {
  @override
  void refreshView() => _paged.refresh(); // back on top, however it got there (lib/widgets/refresh_on_return.dart)

  @override
  List<SortField> get sorts => readListBookSorts;
  @override
  Pin? get pin => widget.pin;
  @override
  Paged get paged => _paged;
  late final Paged _paged = Paged((page, size) => readListBooksPage(widget.api, _id, sort,
      read: readFilter, filter: filters, page: page, size: size));
  String get _id => widget.readList['id'] as String;
  @override
  String get viewKey => 'view.readlist.${widget.readList['id']}';
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
          readListBooksPage(widget.api, _id, ViewSort.first(readListBookSorts), read: readFilter, filter: draft,
              page: page, size: size)));


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
          filter: readFilter, onFilter: setReadFilter,
          filters: filterButton(),
          sort: SortMenuButton(fields: readListBookSorts, value: sort, onChanged: setViewSort),
          select: _sel,
          pin: Pin(
            name: [name, if (readFilter.shows != null) readFilter.shows!,
                if (sort.words(readListBookSorts) != null) sort.words(readListBookSorts)!,
                ...filterWords()].join(' · '),
            kind: 'readlist', id: rlId, title: name, filter: readFilter.name, filters: activeFilters,
            sort: sort.isDefault(readListBookSorts) ? null : sort.pinValue, // null: as pins made before sorts
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
        empty: readFilter.shows == null ? 'Nothing here' : 'Nothing ${readFilter.shows} in this list',
        itemBuilder: (context, b, i) => bookTile(context, widget.api, b, autofocus: i == 0,
            readListId: rlId, onChanged: _paged.refresh, selection: _sel, onOpen: () async {
          await Navigator.of(context).push(MaterialPageRoute(
              builder: (_) => readerFor(widget.api, b, readListId: rlId,
                  skipRead: readFilter == ReadFilter.hideRead))); // coming back loads afresh: refreshView
        }),
      )),
    )));
  }
}
