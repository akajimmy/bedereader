import 'dart:async';

import 'package:flutter/material.dart';

import '../api.dart';
import '../hidden_libraries.dart';
import '../errors.dart';
import '../home_sections.dart';
import '../offline/connection.dart';
import '../ondeck_hidden.dart';
import '../pins.dart';
import '../widgets/drawer.dart';
import '../widgets/fullscreen_exit.dart';
import '../widgets/home_sections_editor.dart';
import '../widgets/pin_tile.dart';
import '../widgets/poster.dart' show PosterSizeButton;
import '../widgets/poster_row.dart';
import '../widgets/refresh_on_return.dart';
import '../widgets/error_text.dart';
import 'library.dart';
import 'reader.dart';
import 'search.dart';
import 'readlist.dart';
import 'series.dart';

/// Start screen: Continue reading, On deck, Pinned views (long-press to rename or unpin) and a button per library;
/// each section can be shown or hidden from the ⋮ menu. The side menu (☰) has the same library links.
class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key, required this.api, required this.onSignOut});
  final Komga api;
  final VoidCallback onSignOut;
  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> with RefreshOnReturn {
  @override
  void refreshView() => _load(); // back on top, however it got there (lib/widgets/refresh_on_return.dart)

  final _scaffold = GlobalKey<ScaffoldState>();
  final _edge = GlobalKey<DrawerEdgeState>(); // Left past the first item opens the side menu
  List<dynamic> _libraries = [];
  List<dynamic> _inProgress = [];
  List<dynamic> _onDeck = [];
  List<dynamic> _recentlyRead = [], _recentBooks = [], _recentSeries = [], _releases = [];
  /// Home sections shown or hidden from the ⋮ menu or Settings (lib/home_sections.dart).
  HomeSections get _sections => HomeSections.instance;
  Map<String, bool> get _show => _sections.show;
  Set<String> _fetched = {}; // sections loaded with the last _load (optional rows are only fetched while shown)
  bool _loading = true;
  Object? _error; // shown through lib/errors.dart

  Komga get api => widget.api;

  @override
  void initState() {
    super.initState();
    _sections.addListener(_onSections);
    Pins.instance.addListener(_checkOfflinePins);
    OnDeckHidden.instance.addListener(_onHiddenChanged);
    HiddenLibraries.instance.addListener(_load); // a library shown or hidden on this device: every row changes
    _sections.load().then((_) => _load());
  }

  @override
  void dispose() {
    _sections.removeListener(_onSections);
    Pins.instance.removeListener(_checkOfflinePins);
    OnDeckHidden.instance.removeListener(_onHiddenChanged);
    HiddenLibraries.instance.removeListener(_load);
    super.dispose();
  }

  /// Hidden from On deck (here or on another screen): filter again now; fetch again if showing it back needs more.
  void _onHiddenChanged() {
    if (!mounted) return;
    setState(() {});
    if (_sections['ondeck']) _load();
  }

  /// A section switched on or off, or moved (here or in Settings). Rows fetched only while shown load now.
  void _onSections() {
    if (!mounted) return;
    setState(() {});
    if (_optional.any((k) => _sections[k] && !_fetched.contains(k))) _load();
  }

  static const _optional = ['ondeck', 'recentlyRead', 'recentBooks', 'recentSeries', 'releases'];

  Future<void> _load() async {
    PinTile.invalidate(); // pin posters show the current first items
    // the pins from Komga again: ones made on another device arrive (user, 2026-10-05) - not while offline
    if (!Connection.instance.offline) unawaited(Pins.instance.refresh());
    unawaited(_checkOfflinePins()); // offline: which pins have something downloaded (runs alongside)
    setState(() { _loading = _inProgress.isEmpty && _libraries.isEmpty; _error = null; });
    try {
      final want = {for (final k in _optional) if (_sections[k]) k};
      List<dynamic> content(Object r) => ((r as Map)['content'] as List<dynamic>?) ?? [];
      final results = await Future.wait([
        api.visibleLibraries(), // those hidden on this device left out
        api.inProgress(),
        // extra, to still fill the row after the hidden ones are left out
        if (want.contains('ondeck')) api.onDeck(size: 30 + OnDeckHidden.instance.count) else Future.value({}),
        if (want.contains('recentlyRead'))
          api.books(readStatus: const ['READ'], sort: 'readProgress.readDate,desc', size: 30)
        else
          Future.value({}),
        if (want.contains('recentBooks')) api.books(sort: 'createdDate,desc', size: 30) else Future.value({}),
        if (want.contains('recentSeries')) api.series(sort: 'createdDate,desc', size: 30) else Future.value({}),
        if (want.contains('releases')) api.books(sort: 'metadata.releaseDate,desc', size: 30) else Future.value({}),
      ]);
      _libraries = results[0] as List<dynamic>;
      _inProgress = content(results[1]);
      _onDeck = content(results[2]);
      _recentlyRead = content(results[3]);
      _recentBooks = content(results[4]);
      _recentSeries = content(results[5]);
      _releases = content(results[6]);
      _fetched = want;
    } catch (e) {
      _error = e;
    }
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _toggleSection(String k) => _sections.toggle(k);

  /// Open a pinned view. Series and read lists are fetched fresh (their tiles need the full object).
  Future<void> _openPin(Pin p) async {
    try {
      final Widget screen;
      switch (p.kind) {
        case 'series':
          final s = await api.oneSeries(p.id!);
          if (s == null) return _gone(p);
          screen = SeriesScreen(api: api, series: s, pin: p);
        case 'readlist':
          final rl = await api.readList(p.id!);
          if (rl == null) return _gone(p);
          screen = ReadListScreen(api: api, readList: rl, pin: p);
        case 'collection':
          screen = SeriesListScreen(api: api, title: p.title, collectionId: p.id!, pin: p);
        default:
          screen = LibraryScreen(api: api, onSignOut: widget.onSignOut, libraryId: p.id, pin: p);
      }
      if (mounted) await _push(screen);
    } catch (e, st) {
      if (mounted) showErrorSnack(context, couldnt('open "${p.title}"', e), e, st);
    }
  }

  void _gone(Pin p) {
    if (!mounted) return;
    if (Connection.instance.offline) {
      // offline this only means nothing from it is downloaded - not that it's gone
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Nothing from "${p.title}" is downloaded')));
      return;
    }
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text('"${p.title}" no longer exists on the server'),
      showCloseIcon: true, // always dismissable, whatever you decide about the pin
      action: SnackBarAction(label: 'Unpin', onPressed: () => Pins.instance.remove(p)),
    ));
  }

  /// Offline: the pins whose view has something downloaded (null = not worked out yet, or online: show all).
  Set<Pin>? _offlinePins;

  /// Offline, a pin leading to an empty view is hidden (user's call). Each pin's own view is asked - the same query
  /// its screen would run, filter included - against the downloaded books.
  Future<void> _checkOfflinePins() async {
    if (!Connection.instance.offline) {
      if (_offlinePins != null && mounted) setState(() => _offlinePins = null);
      return;
    }
    final keep = <Pin>{};
    for (final p in Pins.instance.items) {
      try {
          final r = await pinView(api, p, size: 1);
        if (((r['totalElements'] as num?) ?? 0) > 0) keep.add(p);
      } catch (_) {
        // can't tell: leave it out rather than show an empty pin
      }
    }
    if (mounted) setState(() => _offlinePins = keep);
  }

  /// The widgets for one Home section (drawn in the order chosen in the ⋮ menu / Settings).
  List<Widget> _sectionWidgets(String key) {
    final offline = Connection.instance.offline;
    // a row of book posters, or - when empty - its title and what's missing (online / offline wording)
    List<Widget> books(String title, List<dynamic> list, String empty, String emptyOffline, {bool autofocus = false}) =>
        list.isEmpty
            ? [_Section(title), _Empty(offline ? emptyOffline : empty)]
            : [
                PosterRow(
                  title: title,
                  itemCount: list.length,
                  itemBuilder: (context, i) => bookTile(context, api, list[i], autofocus: autofocus && i == 0,
                      onChanged: _load, onOpen: () => _push(ReaderScreen(api: api, book: list[i]))),
                ),
              ];
    switch (key) {
      case 'continue':
        return books('Continue reading', _inProgress, 'Nothing in progress', 'Nothing downloaded in progress', autofocus: true);
      case 'ondeck':
        final hidden = OnDeckHidden.instance;
        return books('On deck', [for (final b in _onDeck) if (!hidden.hides(b)) b].take(30).toList(), 'Nothing on deck',
            'Nothing downloaded on deck');
      case 'recentlyRead':
        return books('Recently read', _recentlyRead, 'Nothing read yet', 'No downloaded books read yet');
      case 'recentBooks':
        return books('Recently added books', _recentBooks, 'Nothing added yet', 'No downloaded books');
      case 'recentSeries':
        return _recentSeries.isEmpty
            ? [_Section('Recently added series'), _Empty(offline ? 'No downloaded series' : 'Nothing added yet')]
            : [
                PosterRow(
                  title: 'Recently added series',
                  itemCount: _recentSeries.length,
                  itemBuilder: (context, i) => seriesTile(context, api, _recentSeries[i], onChanged: _load,
                      onOpen: () => _push(SeriesScreen(api: api, series: _recentSeries[i]))),
                ),
              ];
      case 'releases':
        return books('Recent releases', _releases, 'No releases yet', 'No downloaded books');
      case 'pinned':
        return [
          ListenableBuilder(
            listenable: Pins.instance,
            builder: (context, _) {
              final offlineKeep = _offlinePins;
              final pins = Connection.instance.offline
                  ? [for (final p in Pins.instance.items) if (offlineKeep?.contains(p) ?? false) p]
                  : Pins.instance.items;
              if (pins.isEmpty) return const SizedBox.shrink();
              // posters: each a 2x2 of its view's first items (lib/widgets/pin_tile.dart)
              return PosterRow(
                title: 'Pinned',
                itemCount: pins.length,
                itemBuilder: (context, i) => PinTile(api: api, pin: pins[i], onOpen: () => _openPin(pins[i])),
              );
            },
          ),
        ];
      case 'libraries':
        return [
          _Section('Libraries'),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  child: Wrap(spacing: 10, runSpacing: 10, children: [
                    for (final l in _libraries)
                      _LibraryButton(label: l['name'] as String, autofocus: (_inProgress.isEmpty || !_show['continue']!) && l == _libraries.first,
                          onTap: () => _push(LibraryScreen(api: api, onSignOut: widget.onSignOut, libraryId: l['id'] as String))),
                    _LibraryButton(label: 'All libraries', icon: Icons.collections_bookmark_outlined,
                        onTap: () => _push(LibraryScreen(api: api, onSignOut: widget.onSignOut))),
                  ]),
                ),
        ];
    }
    return const [];
  }

  // coming back loads afresh: refreshView
  Future<void> _push(Widget w) => Navigator.of(context).push(MaterialPageRoute(builder: (_) => w));

  @override
  Widget build(BuildContext context) {
    return SideMenuFrame(api: api, onSignOut: widget.onSignOut, page: (context, docked) => Scaffold(
      key: _scaffold,
      onDrawerChanged: (open) { if (!open) _edge.currentState?.restore(); },
      drawer: docked ? null : AppDrawer(api: api, onSignOut: widget.onSignOut), // docked: beside the page instead
      appBar: AppBar(
        title: const Text('Home'),
        actions: [
          IconButton(tooltip: 'Search', icon: const Icon(Icons.search),
              onPressed: () => _push(SearchScreen(api: api))),
          IconButton(tooltip: 'Refresh', icon: const Icon(Icons.refresh), onPressed: _load),
          const PosterSizeButton(),
          PopupMenuButton<String>(
            tooltip: 'Show or hide sections',
            onSelected: (k) => k == '_arrange' ? showHomeSectionsEditor(context) : _toggleSection(k),
            itemBuilder: (_) => [
              for (final k in _sections.order)
                CheckedPopupMenuItem(value: k, checked: _sections[k], child: Text(HomeSections.names[k]!)),
              const PopupMenuDivider(),
              const PopupMenuItem(value: '_arrange', child: ListTile(
                  contentPadding: EdgeInsets.zero, leading: Icon(Icons.reorder), title: Text('Arrange sections…'))),
            ],
          ),
          const FullscreenExit(),
        ],
      ),
      body: DrawerEdge(key: _edge, scaffoldKey: _scaffold, child: _loading
          ? const Center(child: CircularProgressIndicator())
          : RefreshIndicator(
              onRefresh: _load,
              child: ListView(physics: const AlwaysScrollableScrollPhysics(), padding: const EdgeInsets.only(bottom: 24), children: [
                if (Connection.instance.offline) const _OfflineBanner(),
                if (_error != null)
                  Padding(padding: const EdgeInsets.all(16),
                      child: ErrorText(explain(_error!).message, _error!)),
                if (!_show.values.any((v) => v))
                  const _Empty('Every section is hidden - use ⋮ at the top right to show them again.'),
                for (final k in _sections.order)
                  if (_sections[k]) ..._sectionWidgets(k),
              ]),
            )),
    ));
  }
}

class _Section extends StatelessWidget {
  const _Section(this.title);
  final String title;
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 20, 16, 8),
        child: Text(title, style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w500)),
      );
}

class _Empty extends StatelessWidget {
  const _Empty(this.text);
  final String text;
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        child: Text(text, style: const TextStyle(color: Color(0xFF9A9A9A))),
      );
}

class _LibraryButton extends StatelessWidget {
  const _LibraryButton({required this.label, required this.onTap, this.icon = Icons.folder_outlined, this.autofocus = false});
  final String label;
  final VoidCallback onTap;
  final IconData icon;
  final bool autofocus;
  @override
  Widget build(BuildContext context) => FilledButton.tonalIcon(
        autofocus: autofocus,
        style: FilledButton.styleFrom(padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 16)),
        onPressed: onTap,
        icon: Icon(icon),
        label: Text(label),
      );
}

/// Shown on Home while offline: what you're looking at, and the way back - offline by hand ("Go online"), because
/// Komga couldn't be reached ("Retry"), or Komga answers again ("Go online", in green).
class _OfflineBanner extends StatelessWidget {
  const _OfflineBanner();
  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: Connection.instance,
        builder: (context, _) {
          final c = Connection.instance;
          final back = c.reachableAgain && !c.forcedOffline;
          final (text, button, action) = c.forcedOffline
              ? ('Offline mode - showing downloaded books', 'Go online', c.goOnline)
              : back
                  ? ('Komga is reachable again', 'Go online', c.goOnline)
                  : ("Can't reach Komga - showing downloaded books", 'Retry', () { c.check(); });
          final color = back ? const Color(0xFF4ADE80) : const Color(0xFFFACC15);
          return Container(
            margin: const EdgeInsets.fromLTRB(12, 8, 12, 0),
            padding: const EdgeInsets.fromLTRB(14, 8, 8, 8),
            decoration: BoxDecoration(
              color: back ? const Color(0xFF10261A) : const Color(0xFF2A2410),
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: back ? const Color(0xFF1E6B3E) : const Color(0xFF6B5A1E)),
            ),
            child: Row(children: [
              Icon(back ? Icons.cloud_done : Icons.cloud_off, color: color),
              const SizedBox(width: 10),
              Expanded(child: Text(text)),
              TextButton(onPressed: action, child: Text(button)),
            ]),
          );
        },
      );
}

