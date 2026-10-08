import 'dart:async';

import 'package:flutter/material.dart';

import '../api.dart';
import '../book_title.dart';
import '../paged.dart';
import '../pins.dart';
import '../settings.dart';
import '../view_filter.dart';
import '../view_prefs.dart';
import '../view_sort.dart';
import '../widgets/download_badge.dart';
import '../widgets/drawer.dart';
import '../widgets/filter_panel.dart';
import '../widgets/poster.dart';
import '../widgets/readlist_tile.dart';
import '../widgets/refresh_on_return.dart';
import '../widgets/selection.dart';
import '../widgets/view_bar.dart';
import 'actions.dart';
import 'book_details.dart' show posterDate;
import 'open_book.dart';
import 'search.dart';
import 'readlist.dart';
import 'series.dart';

enum BrowseMode { series, books, collections, readLists }

/// One library (or all of them) browsed four ways: series, books, collections, read lists.
class LibraryScreen extends StatefulWidget {
  const LibraryScreen({super.key, required this.api, required this.onSignOut, this.libraryId, this.pin,
      this.startMode});
  final Komga api;
  final VoidCallback onSignOut;
  final String? libraryId; // null = all libraries
  final Pin? pin; // opened from a Home pin: start in that view instead of the remembered one
  final BrowseMode? startMode; // opened from a breadcrumb: this way of browsing (filter and sort as remembered)
  @override
  State<LibraryScreen> createState() => _LibraryScreenState();

  /// A breadcrumb's parent (user, 2026-10-02): the library screen the user came through, if one is open under this
  /// screen, gone back to and shown [mode]; else a new one opened. [libraryId]: a library screen showing that one
  /// ([anyLibrary]: whichever it shows - read lists and collections span libraries).
  static Future<void> openFromBreadcrumb(BuildContext context, Komga api,
      {String? libraryId, bool anyLibrary = false, required BrowseMode mode}) async {
    for (final s in _LibraryScreenState._open.reversed) {
      final route = s.mounted ? ModalRoute.of(s.context) : null;
      if (route == null || !route.isActive || route.isCurrent) continue;
      if (!anyLibrary && s._libraryId != libraryId) continue;
      Navigator.of(context).popUntil((r) => r == route);
      s._show(mode);
      return;
    }
    await Navigator.of(context).push(MaterialPageRoute(builder: (_) => LibraryScreen(
        api: api, onSignOut: AppDrawer.appSignOut, libraryId: libraryId, startMode: mode)));
  }
}

class _LibraryScreenState extends State<LibraryScreen> with RefreshOnReturn, ViewFilters {
  static final List<_LibraryScreenState> _open = []; // library screens in the app now, oldest first

  /// Shows [m] (a breadcrumb back to this screen), as picking its chip would.
  void _show(BrowseMode m) {
    if (_mode == m) return;
    _sel.end(); _mode = m; _sort = _defaultSort(m); _load();
  }
  @override
  void refreshView() => _refresh(); // back on top, however it got there (lib/widgets/refresh_on_return.dart)

  final _scaffold = GlobalKey<ScaffoldState>();
  final _edge = GlobalKey<DrawerEdgeState>(); // Left past the first item opens the side menu
  List<dynamic> _libraries = [];
  late String? _libraryId = widget.libraryId; // null = all libraries
  BrowseMode _mode = BrowseMode.series;
  ReadFilter _filter = ReadFilter.all;
  ViewSort _sort = const ViewSort('title', false);
  late final Paged _paged = Paged(_fetch);
  final _sel = Selection(); // multi-select, in Books mode

  /// The mode's sort fields (each starts in its natural direction: titles A -> Z, dates newest first).
  static List<SortField> _fieldsOf(BrowseMode m) => switch (m) {
        BrowseMode.series => librarySeriesSorts,
        BrowseMode.books => libraryBookSorts,
        BrowseMode.collections || BrowseMode.readLists => listSorts,
      };
  List<SortField> get _fields => _fieldsOf(_mode);

  // sort key -> Komga field (shared with pins, pins.dart); the direction is separate
  Map<String, String> get _komgaFields => _mode == BrowseMode.series ? seriesSortFields : bookSortFields;
  String get _sortParam => '${_komgaFields[_sort.key] ?? _komgaFields.values.first},${_sort.dir}';

  Komga get api => widget.api;

  @override
  void initState() {
    super.initState();
    _open.add(this);
    _init();
  }

  @override
  void dispose() {
    _open.remove(this);
    _paged.dispose();
    _sel.dispose();
    super.dispose();
  }

  /// A mode's default sort: books newest added first, the others by title / name.
  static ViewSort _defaultSort(BrowseMode m) =>
      m == BrowseMode.books ? const ViewSort('added', true) : ViewSort.first(_fieldsOf(m));
  String get _viewKey => 'view.library.${_libraryId ?? 'all'}';
  bool get _filtered =>
      _filter != ReadFilter.all || _sort != _defaultSort(_mode) || (!_listMode && activeFilters.isNotEmpty);
  bool get _listMode => _mode == BrowseMode.collections || _mode == BrowseMode.readLists;

  // ---- the filter panel (Series and Books modes; collections / read lists have the eye only)
  @override
  bool get filtersSeriesView => _mode == BrowseMode.series;

  @override
  Future<ViewKind> askFilterKind() => api.viewKind(libraryId: _libraryId);

  @override
  FilterScope filterScope(Future<ViewKind> kind) => FilterScope(api: api, seriesView: filtersSeriesView,
      libraryId: _libraryId, kind: kind, count: (draft) => countOf((page, size) => _fetchWith(draft, page, size)));

  @override
  void applyFilters(ViewFilter f) {
    filters = f;
    _load();
  }

  /// A saved or pinned sort in this mode: an unknown key is the mode's default field; no direction, the field's
  /// natural one.
  ViewSort _sortOf(Object? key, Object? desc) {
    final f = _fields.where((f) => f.key == key).firstOrNull;
    final k = f?.key ?? _defaultSort(_mode).key;
    return ViewSort(k, desc is bool ? desc : _fields.firstWhere((f) => f.key == k).desc);
  }

  /// This library's remembered mode / filter / sort.
  Future<void> _restoreView() async {
    final v = await ViewPrefs.load(_viewKey);
    _mode = BrowseMode.values.firstWhere((m) => m.name == v['mode'], orElse: () => BrowseMode.series);
    _filter = ReadFilterApi.fromName(v['filter']);
    _sort = _sortOf(v['sort'], v['desc']);
    filters = ViewPrefs.filtersOf(v);
  }

  Future<void> _init() async {
    final pin = widget.pin;
    if (pin != null) {
      _mode = BrowseMode.values.firstWhere((m) => m.name == pin.mode, orElse: () => BrowseMode.series);
      _filter = pin.readFilter;
      // pin.sort is "key:asc" / "key:desc" (just "key": the sort's natural direction; none: the mode's default)
      final parts = (pin.sort ?? '').split(':');
      _sort = _sortOf(parts.first, parts.length > 1 ? parts[1] == 'desc' : null);
      filters = pin.filters;
    } else {
      await _restoreView();
      final m = widget.startMode;
      if (m != null && m != _mode) { _mode = m; _sort = _defaultSort(m); }
    }
    if (!mounted) return;
    setState(() {});
    unawaited(_paged.more()); // Paged shows its own errors
    try {
      final libs = await api.visibleLibraries(); // the picker: those hidden on this device left out
      if (mounted) setState(() => _libraries = libs);
    } catch (_) {
      // the grid shows the error if the server is unreachable
    }
  }

  Future<Map<String, dynamic>> _fetch(int page, int size) => _fetchWith(filters, page, size);

  /// The listing with [filter] (the view's own, or the panel's draft for its count).
  Future<Map<String, dynamic>> _fetchWith(ViewFilter filter, int page, int size) => switch (_mode) {
        BrowseMode.series => api.filteredSeries(libraryId: _libraryId, read: _filter, filter: filter,
            sort: _sortParam, page: page, size: size),
        BrowseMode.books => api.filteredBooks(libraryId: _libraryId, read: _filter, filter: filter,
            sort: _sortParam, page: page, size: size),
        BrowseMode.collections || BrowseMode.readLists when _filter != ReadFilter.all || _sort != _defaultSort(_mode) =>
          page > 0
            ? Future.value(const {'content': [], 'last': true}) // (all of them came as the first page)
            : ListContents.matching(api, readLists: _mode == BrowseMode.readLists, libraryId: _libraryId,
                filter: _filter, sort: _sort),
        BrowseMode.collections => api.collections(libraryId: _libraryId, page: page, size: size),
        BrowseMode.readLists => api.readLists(libraryId: _libraryId, page: page, size: size),
      };

  /// Library, mode, filter or sort changed: start the listing over.
  void _load() {
    setState(() {});
    _paged.reset();
    ViewPrefs.save(_viewKey, ViewPrefs.withFilters(
        {'mode': _mode.name, 'filter': _filter.name, 'sort': _sort.key, 'desc': _sort.desc}, filters));
  }

  Future<void> _switchLibrary(String? id) async {
    _libraryId = id;
    forgetFilterKind();
    await _restoreView();
    if (!mounted) return;
    setState(() {});
    unawaited(_paged.reset()); // Paged shows its own errors
  }

  void _clearFilters() {
    _filter = ReadFilter.all;
    _sort = _defaultSort(_mode);
    if (!_listMode) filters = ViewFilter.none; // (collections / read lists: the panel's filters aren't theirs)
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
    // the eye and Sort in every mode (user, 2026-10-07 / 2026-10-08)
    final chips = _listMode ? null : filterChips();
    return SideMenuFrame(api: api, onSignOut: widget.onSignOut, page: (context, docked) =>
        selectionScope(_sel, (context) => Scaffold(
      key: _scaffold,
      onDrawerChanged: (open) { if (!open) _edge.currentState?.restore(); },
      drawer: docked ? null : AppDrawer(api: api, onSignOut: widget.onSignOut), // docked: beside the page instead
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
        actions: viewBarActions(
          paged: _paged,
          filter: _filter, onFilter: (f) { _filter = f; _load(); },
          filters: _listMode ? null : filterButton(),
          sort: SortMenuButton(fields: _fields, value: _sort, onChanged: (s) { _sort = s; _load(); }),
          onClear: _filtered ? _clearFilters : null,
          select: _mode == BrowseMode.books ? _sel : null,
          pin: Pin(
            name: [_libraryName, _modeLabel(_mode), if (_filter.shows != null) _filter.shows!,
                if (!_listMode) ...filterWords()].join(' · '),
            kind: 'library', id: _libraryId, title: _libraryName,
            filter: _filter.name, mode: _mode.name,
            filters: _listMode ? ViewFilter.none : activeFilters,
            // collections / read lists: none for the default, as pins made before they could be sorted
            sort: _listMode && _sort == _defaultSort(_mode) ? null : _sort.pinValue,
          ),
          onSearch: () => _push(SearchScreen(api: api, libraryId: _libraryId,
              libraryName: _libraryId == null ? null : _libraryName)),
          onRefresh: _refresh,
        ),
        bottom: PreferredSize(
          // the mode chips, then the active filters' chips (Series / Books modes)
          preferredSize: Size.fromHeight(44 + (chips == null ? 0 : ActiveFilters.height)),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Row(children: [
                for (final m in BrowseMode.values)
                  Padding(
                    padding: const EdgeInsets.only(right: 8, bottom: 6),
                    child: ChoiceChip(
                      label: Text(_modeLabel(m)),
                      selected: _mode == m,
                      onSelected: (_) {
                        _sel.end(); _mode = m; _sort = _defaultSort(m); _load();
                      },
                    ),
                  ),
              ]),
            ),
            if (chips != null) Align(alignment: Alignment.centerLeft, child: chips),
          ]),
        ),
      ),
      // above Android's navigation bar (the app is drawn edge to edge, under it): the remote's focus was scrolled to an
      // edge behind it (user, 2026-10-07)
      body: SafeArea(top: false, child: DrawerEdge(key: _edge, scaffoldKey: _scaffold, child: _body())),
    )));
  }

  Widget _body() => PagedPosterGrid(
        paged: _paged,
        itemBuilder: (context, it, i) => _tile(it, i == 0),
        onRefresh: () {
          ReadListTile.invalidate(); // read-list posters show the first unread books
          return _paged.refresh();
        },
      );

  Widget _tile(dynamic it, bool first) {
    switch (_mode) {
      case BrowseMode.series:
        return seriesTile(context, api, it, autofocus: first, onChanged: _refresh,
            onOpen: () => _push(SeriesScreen(api: api, series: it)));
      case BrowseMode.books:
        return bookTile(context, api, it, autofocus: first, onChanged: _refresh, selection: _sel,
            onOpen: () => _push(readerFor(api, it, skipRead: _filter == ReadFilter.hideRead)));
      case BrowseMode.collections:
        return CollectionTile(api: api, collection: it, autofocus: first, filter: _filter,
          onOpen: () => _push(SeriesListScreen(api: api, title: it['name'] as String, collectionId: it['id'] as String)),
        );
      case BrowseMode.readLists:
        return ReadListTile(api: api, readList: it, autofocus: first, filter: _filter,
            onOpen: () => _push(ReadListScreen(api: api, readList: it)),
            onMenu: () => showReadListActions(context, api, it, onChanged: _refresh));
    }
  }

  // coming back loads afresh: refreshView
  Future<void> _push(Widget w) => Navigator.of(context).push(MaterialPageRoute(builder: (_) => w));

  static String _modeLabel(BrowseMode m) => switch (m) {
        BrowseMode.series => 'Series', BrowseMode.books => 'Books',
        BrowseMode.collections => 'Collections', BrowseMode.readLists => 'Read lists',
      };
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
    badge: DownloadBadge.series(s['id'] as String, total: total),
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
  final title = (b['metadata']?['title'] ?? b['name']) as String;
  final display = AppSettings.instance.display;
  // Settings > Library & Home: any of the three lines, always in this order (user, 2026-10-07) - the first is the
  // tile's title, the next its subtitle, the third its caption ('' keeps a book's date line when it has none)
  final lines = [
    if (display.posterSeries) bookTitle(b),
    if (display.posterTitle) title,
    if (display.posterDate) posterDate(b['metadata']?['releaseDate'] as String?) ?? '',
  ];
  return PosterTile(
    api: api, autofocus: autofocus, imageUrl: api.bookThumb(b['id']),
    title: lines.isEmpty ? '' : lines[0],
    subtitle: lines.length > 1 ? lines[1] : null,
    caption: lines.length > 2 ? lines[2] : null,
    read: completed,
    progress: rp != null && !completed && pagesCount > 0 ? (rp['page'] as int) / pagesCount : null,
    selected: selecting ? selection.isSelected(b) : null,
    badge: DownloadBadge.book(b['id'] as String),
    onOpen: selecting ? () => selection.toggle(b) : onOpen,
    onMenu: selecting
        ? () => selection.toggle(b)
        : () => showBookActions(context, api, b, onChanged: onChanged ?? () {}, readListId: readListId,
            showViewSeries: showViewSeries, onSelectMultiple: selection == null ? null : () => selection.start(b)),
  );
}
