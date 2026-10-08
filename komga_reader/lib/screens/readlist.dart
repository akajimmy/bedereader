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

class _ReadListScreenState extends State<ReadListScreen> with SideMenuHere, RefreshOnReturn {
  @override
  void refreshView() => _paged.refresh(); // back on top, however it got there (lib/widgets/refresh_on_return.dart)

  ReadFilter _filter = ReadFilter.all;
  ViewSort _sort = ViewSort.first(readListBookSorts);
  late final Paged _paged = Paged((page, size) => readListBooksPage(widget.api, widget.readList['id'] as String, _sort,
      readStatus: _filter.api, page: page, size: size));
  String get _viewKey => 'view.readlist.${widget.readList['id']}';
  final _sel = Selection();

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
    } else {
      final v = await ViewPrefs.load(_viewKey);
      _filter = ReadFilterApi.fromName(v['filter']);
      _sort = ViewSort.of(readListBookSorts, v['sort'], v['desc']);
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
        actions: viewBarActions(
          paged: _paged,
          filter: _filter, onFilter: _setFilter,
          sort: SortMenuButton(fields: readListBookSorts, value: _sort, onChanged: _setSort),
          select: _sel,
          pin: Pin(
            name: [name, if (_filter.shows != null) _filter.shows!,
                if (_sort.words(readListBookSorts) != null) _sort.words(readListBookSorts)!].join(' · '),
            kind: 'readlist', id: rlId, title: name, filter: _filter.name,
            sort: _sort.isDefault(readListBookSorts) ? null : _sort.pinValue, // null: as pins made before sorts
          ),
          onRefresh: _paged.refresh,
          onMore: () => showReadListActions(context, widget.api, widget.readList, onChanged: _paged.refresh),
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
