import 'package:flutter/material.dart';

import '../api.dart';
import '../paged.dart';
import '../pins.dart';
import '../view_prefs.dart';
import '../widgets/drawer.dart';
import '../widgets/poster.dart';
import '../widgets/readlist_tile.dart';
import '../widgets/selection.dart';
import 'actions.dart';
import 'reader.dart';
import 'readlist.dart';
import 'series.dart';

enum BrowseMode { series, books, collections, readLists }

/// One library (or all of them) browsed four ways: series, books, collections, read lists.
class LibraryScreen extends StatefulWidget {
  const LibraryScreen({super.key, required this.api, required this.onSignOut, this.libraryId, this.pin});
  final Komga api;
  final VoidCallback onSignOut;
  final String? libraryId; // null = all libraries
  final Pin? pin; // opened from a Home pin: start in that view instead of the remembered one
  @override
  State<LibraryScreen> createState() => _LibraryScreenState();
}

class _LibraryScreenState extends State<LibraryScreen> {
  final _scaffold = GlobalKey<ScaffoldState>();
  final _edge = GlobalKey<DrawerEdgeState>(); // Left past the first item opens the side menu
  List<dynamic> _libraries = [];
  late String? _libraryId = widget.libraryId; // null = all libraries
  BrowseMode _mode = BrowseMode.series;
  ReadFilter _filter = ReadFilter.all;
  String _sortKey = 'title';
  late final Paged _paged = Paged(_fetch);
  final _sel = Selection(); // multi-select, in Books mode

  static const _seriesSorts = {'title': 'metadata.titleSort,asc', 'added': 'createdDate,desc', 'updated': 'lastModifiedDate,desc'};
  static const _bookSorts = {'title': 'metadata.title,asc', 'added': 'createdDate,desc', 'release': 'metadata.releaseDate,desc'};

  Komga get api => widget.api;

  @override
  void initState() {
    super.initState();
    _init();
  }

  @override
  void dispose() {
    _paged.dispose();
    _sel.dispose();
    super.dispose();
  }

  static String _defaultSort(BrowseMode m) => m == BrowseMode.books ? 'added' : 'title';
  String get _viewKey => 'view.library.${_libraryId ?? 'all'}';
  bool get _filtered => _filter != ReadFilter.all || _sortKey != _defaultSort(_mode);

  /// This library's remembered mode / filter / sort.
  Future<void> _restoreView() async {
    final v = await ViewPrefs.load(_viewKey);
    _mode = BrowseMode.values.firstWhere((m) => m.name == v['mode'], orElse: () => BrowseMode.series);
    _filter = ReadFilterApi.fromName(v['filter']);
    final sorts = _mode == BrowseMode.series ? _seriesSorts : _bookSorts;
    _sortKey = sorts.containsKey(v['sort']) ? v['sort'] as String : _defaultSort(_mode);
  }

  Future<void> _init() async {
    final pin = widget.pin;
    if (pin != null) {
      _mode = BrowseMode.values.firstWhere((m) => m.name == pin.mode, orElse: () => BrowseMode.series);
      _filter = pin.readFilter;
      _sortKey = pin.sort ?? _defaultSort(_mode);
    } else {
      await _restoreView();
    }
    if (!mounted) return;
    setState(() {});
    _paged.more();
    try {
      final libs = await api.libraries();
      if (mounted) setState(() => _libraries = libs);
    } catch (_) {
      // the grid shows the error if the server is unreachable
    }
  }

  Future<Map<String, dynamic>> _fetch(int page, int size) => switch (_mode) {
        BrowseMode.series => api.series(libraryId: _libraryId, readStatus: _filter.api,
            sort: _seriesSorts[_sortKey] ?? _seriesSorts['title']!, page: page, size: size),
        BrowseMode.books => api.books(libraryId: _libraryId, readStatus: _filter.api,
            sort: _bookSorts[_sortKey] ?? _bookSorts['added']!, page: page, size: size),
        BrowseMode.collections => api.collections(libraryId: _libraryId, page: page, size: size),
        BrowseMode.readLists => api.readLists(libraryId: _libraryId, page: page, size: size),
      };

  /// Library, mode, filter or sort changed: start the listing over.
  void _load() {
    setState(() {});
    _paged.reset();
    ViewPrefs.save(_viewKey, {'mode': _mode.name, 'filter': _filter.name, 'sort': _sortKey});
  }

  Future<void> _switchLibrary(String? id) async {
    _libraryId = id;
    await _restoreView();
    if (!mounted) return;
    setState(() {});
    _paged.reset();
  }

  void _clearFilters() {
    _filter = ReadFilter.all;
    _sortKey = _defaultSort(_mode);
    _load();
  }

  /// Read state may have changed: reload what is loaded, keeping the scroll position.
  void _refresh() {
    ReadListTile.invalidate(); // unread books behind the read-list posters may have changed
    _paged.refresh();
  }

  String get _libraryName => _libraryId == null
      ? 'All libraries'
      : (_libraries.firstWhere((l) => l['id'] == _libraryId, orElse: () => {'name': 'Library'})['name'] as String);

  @override
  Widget build(BuildContext context) {
    final filterable = _mode == BrowseMode.series || _mode == BrowseMode.books;
    return selectionScope(_sel, (context) => Scaffold(
      key: _scaffold,
      onDrawerChanged: (open) { if (!open) _edge.currentState?.restore(); },
      drawer: AppDrawer(api: api, onSignOut: widget.onSignOut),
      appBar: _sel.active
          ? selectionAppBar(context, api, _sel, all: () => _paged.items, onChanged: _refresh)
          : AppBar(
        title: PopupMenuButton<String?>(
          tooltip: 'Library',
          onSelected: _switchLibrary,
          itemBuilder: (_) => [
            const PopupMenuItem(value: null, child: Text('All libraries')),
            for (final l in _libraries) PopupMenuItem(value: l['id'] as String, child: Text(l['name'] as String)),
          ],
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Text(_libraryName), const Icon(Icons.arrow_drop_down),
          ]),
        ),
        actions: [
          if (filterable)
            HideReadButton(value: _filter, onChanged: (f) { _filter = f; _load(); }),
          if (filterable)
            PopupMenuButton<String>(
              tooltip: 'Sort',
              icon: const Icon(Icons.sort),
              onSelected: (s) { _sortKey = s; _load(); },
              itemBuilder: (_) => [
                for (final e in (_mode == BrowseMode.series ? _seriesSorts : _bookSorts).keys)
                  CheckedPopupMenuItem(value: e, checked: e == _sortKey, child: Text(_sortLabel(e))),
              ],
            ),
          if (filterable && _filtered) ClearFiltersButton(onPressed: _clearFilters),
          if (_mode == BrowseMode.books) SelectButton(selection: _sel),
          PinButton(current: Pin(
            name: [_libraryName, _modeLabel(_mode), if (filterable && _filter == ReadFilter.hideRead) 'unread'].join(' · '),
            kind: 'library', id: _libraryId, title: _libraryName,
            filter: filterable ? _filter.name : 'all', mode: _mode.name, sort: filterable ? _sortKey : null,
          )),
          IconButton(tooltip: 'Refresh', icon: const Icon(Icons.refresh), onPressed: _refresh),
        ],
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(44),
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Row(children: [
              for (final m in BrowseMode.values)
                Padding(
                  padding: const EdgeInsets.only(right: 8, bottom: 6),
                  child: ChoiceChip(
                    label: Text(_modeLabel(m)),
                    selected: _mode == m,
                    onSelected: (_) { _sel.end(); _mode = m; _sortKey = _defaultSort(m); _load(); },
                  ),
                ),
            ]),
          ),
        ),
      ),
      body: DrawerEdge(key: _edge, scaffoldKey: _scaffold, child: _body()),
    ));
  }

  Widget _body() => PagedPosterGrid(paged: _paged, itemBuilder: (context, it, i) => _tile(it, i == 0));

  Widget _tile(dynamic it, bool first) {
    switch (_mode) {
      case BrowseMode.series:
        return seriesTile(context, api, it, autofocus: first, onChanged: _refresh,
            onOpen: () => _push(SeriesScreen(api: api, series: it)));
      case BrowseMode.books:
        return bookTile(context, api, it, autofocus: first, onChanged: _refresh, selection: _sel,
            onOpen: () => _push(ReaderScreen(api: api, book: it)));
      case BrowseMode.collections:
        return PosterTile(
          api: api, autofocus: first, imageUrl: api.collectionThumb(it['id']), title: it['name'] as String,
          subtitle: '${(it['seriesIds'] as List?)?.length ?? 0} series',
          onOpen: () => _push(SeriesListScreen(api: api, title: it['name'] as String, collectionId: it['id'] as String)),
        );
      case BrowseMode.readLists:
        return ReadListTile(api: api, readList: it, autofocus: first,
            onOpen: () => _push(ReadListScreen(api: api, readList: it)),
            onMenu: () => showReadListActions(context, api, it, onChanged: _refresh));
    }
  }

  Future<void> _push(Widget w) async {
    await Navigator.of(context).push(MaterialPageRoute(builder: (_) => w));
    _refresh(); // read state may have changed while away
  }

  static String _modeLabel(BrowseMode m) => switch (m) {
        BrowseMode.series => 'Series', BrowseMode.books => 'Books',
        BrowseMode.collections => 'Collections', BrowseMode.readLists => 'Read lists',
      };
  static String _sortLabel(String k) =>
      {'title': 'Title', 'added': 'Recently added', 'updated': 'Recently updated', 'release': 'Release date'}[k] ?? k;
}

/// "12 books · 3 unread · 1 in progress", or "12 books · read" once every book is finished.
String seriesStatus(dynamic s) {
  final total = (s['booksCount'] ?? 0) as int;
  final unread = (s['booksUnreadCount'] ?? 0) as int, inProgress = (s['booksInProgressCount'] ?? 0) as int;
  final books = total == 1 ? '1 book' : '$total books';
  if (total > 0 && unread == 0 && inProgress == 0) return '$books · read';
  return [books, if (unread > 0) '$unread unread', if (inProgress > 0) '$inProgress in progress'].join(' · ');
}

/// Series tile used in every series grid (libraries, collections). Long-press = series actions.
Widget seriesTile(BuildContext context, Komga api, dynamic s,
    {required VoidCallback onOpen, VoidCallback? onChanged, bool autofocus = false}) {
  final total = (s['booksCount'] ?? 0) as int;
  return PosterTile(
    api: api, autofocus: autofocus, imageUrl: api.seriesThumb(s['id']),
    title: (s['metadata']?['title'] ?? s['name']) as String,
    subtitle: seriesStatus(s),
    read: total > 0 && s['booksUnreadCount'] == 0 && s['booksInProgressCount'] == 0,
    onOpen: onOpen,
    onMenu: () => showSeriesActions(context, api, s, onChanged: onChanged ?? () {}),
  );
}

/// Book tile used in every book grid (home, series, read lists). With a [selection], long-press offers "Select
/// multiple", and while selecting a tap toggles the book instead of opening it.
Widget bookTile(BuildContext context, Komga api, dynamic b,
    {required VoidCallback onOpen, VoidCallback? onChanged, bool autofocus = false, String? readListId,
    Selection? selection, bool showViewSeries = true}) {
  final selecting = selection != null && selection.active;
  final rp = b['readProgress'];
  final pagesCount = (b['media']?['pagesCount'] ?? 0) as int;
  final completed = rp != null && rp['completed'] == true;
  final number = b['metadata']?['number'] ?? b['number'];
  final title = (b['metadata']?['title'] ?? b['name']) as String;
  return PosterTile(
    api: api, autofocus: autofocus, imageUrl: api.bookThumb(b['id']),
    title: '${b['seriesTitle'] ?? ''} #$number',
    subtitle: title,
    read: completed,
    progress: rp != null && !completed && pagesCount > 0 ? (rp['page'] as int) / pagesCount : null,
    selected: selecting ? selection.isSelected(b) : null,
    onOpen: selecting ? () => selection.toggle(b) : onOpen,
    onMenu: selecting
        ? () => selection.toggle(b)
        : () => showBookActions(context, api, b, onChanged: onChanged ?? () {}, readListId: readListId,
            showViewSeries: showViewSeries, onSelectMultiple: selection == null ? null : () => selection.start(b)),
  );
}
