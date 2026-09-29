import 'package:flutter/material.dart';

import '../api.dart';
import '../home_sections.dart';
import '../offline/connection.dart';
import '../pins.dart';
import '../widgets/drawer.dart';
import 'library.dart';
import 'reader.dart';
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

class _HomeScreenState extends State<HomeScreen> {
  final _scaffold = GlobalKey<ScaffoldState>();
  final _edge = GlobalKey<DrawerEdgeState>(); // Left past the first item opens the side menu
  List<dynamic> _libraries = [];
  List<dynamic> _inProgress = [];
  List<dynamic> _onDeck = [];
  /// Home sections shown or hidden from the ⋮ menu or App settings (lib/home_sections.dart).
  HomeSections get _sections => HomeSections.instance;
  Map<String, bool> get _show => _sections.show;
  bool get _showOnDeck => _sections['ondeck'];
  bool _onDeckWasShown = true;
  bool _loading = true;
  String? _error;

  Komga get api => widget.api;

  @override
  void initState() {
    super.initState();
    _sections.addListener(_onSections);
    Pins.instance.addListener(_checkOfflinePins);
    _sections.load().then((_) {
      _onDeckWasShown = _showOnDeck;
      _load();
    });
  }

  @override
  void dispose() {
    _sections.removeListener(_onSections);
    Pins.instance.removeListener(_checkOfflinePins);
    super.dispose();
  }

  /// A section switched on or off (here or in App settings). On deck is only fetched while shown.
  void _onSections() {
    if (!mounted) return;
    setState(() {});
    if (_showOnDeck && !_onDeckWasShown) _load();
    _onDeckWasShown = _showOnDeck;
  }

  Future<void> _load() async {
    _checkOfflinePins();
    setState(() { _loading = _inProgress.isEmpty && _libraries.isEmpty; _error = null; });
    try {
      final results = await Future.wait([
        api.libraries(),
        api.inProgress(),
        if (_showOnDeck) api.onDeck(),
      ]);
      _libraries = results[0] as List<dynamic>;
      _inProgress = ((results[1] as Map)['content'] as List<dynamic>?) ?? [];
      _onDeck = _showOnDeck ? (((results[2] as Map)['content'] as List<dynamic>?) ?? []) : [];
    } catch (e) {
      _error = '$e';
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
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
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
        final status = p.readFilter.api;
        final Map<String, dynamic> r = switch (p.kind) {
          'series' => await api.seriesBooks(p.id!, readStatus: status, size: 1),
          'readlist' => await api.readListBooks(p.id!, readStatus: status, size: 1),
          'collection' => await api.series(collectionId: p.id, readStatus: status, size: 1),
          _ => switch (p.mode) {
              'books' => await api.books(libraryId: p.id, readStatus: status, size: 1),
              'collections' => await api.collections(libraryId: p.id, size: 1),
              'readLists' => await api.readLists(libraryId: p.id, size: 1),
              _ => await api.series(libraryId: p.id, readStatus: status, size: 1),
            },
        };
        if (((r['totalElements'] as num?) ?? 0) > 0) keep.add(p);
      } catch (_) {
        // can't tell: leave it out rather than show an empty pin
      }
    }
    if (mounted) setState(() => _offlinePins = keep);
  }

  Future<void> _push(Widget w) async {
    await Navigator.of(context).push(MaterialPageRoute(builder: (_) => w));
    _load(); // read state may have changed while away
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      key: _scaffold,
      onDrawerChanged: (open) { if (!open) _edge.currentState?.restore(); },
      drawer: AppDrawer(api: api, onSignOut: widget.onSignOut),
      appBar: AppBar(
        title: const Text('Home'),
        actions: [
          IconButton(tooltip: 'Refresh', icon: const Icon(Icons.refresh), onPressed: _load),
          PopupMenuButton<String>(
            tooltip: 'Show or hide sections',
            onSelected: _toggleSection,
            itemBuilder: (_) => [
              for (final e in HomeSections.names.entries)
                CheckedPopupMenuItem(value: e.key, checked: _show[e.key]!, child: Text(e.value)),
            ],
          ),
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
                      child: Text(_error!, style: const TextStyle(color: Color(0xFFFF8A80)))),
                if (!_show.values.any((v) => v))
                  const _Empty('Every section is hidden - use ⋮ at the top right to show them again.'),
                if (_show['continue']!) ...[
                  _Section('Continue reading'),
                  _inProgress.isEmpty
                      ? const _Empty('Nothing in progress')
                      : _BookRow(books: _inProgress, api: api, autofocusFirst: true, onChanged: _load,
                          onOpen: (b) => _push(ReaderScreen(api: api, book: b))),
                ],
                if (_showOnDeck) ...[
                  _Section('On deck'),
                  _onDeck.isEmpty
                      ? const _Empty('Nothing on deck')
                      : _BookRow(books: _onDeck, api: api, onChanged: _load,
                          onOpen: (b) => _push(ReaderScreen(api: api, book: b))),
                ],
                ListenableBuilder(
                  listenable: Pins.instance,
                  builder: (context, _) {
                    final offlineKeep = _offlinePins;
                    final pins = Connection.instance.offline
                        ? [for (final p in Pins.instance.items) if (offlineKeep?.contains(p) ?? false) p]
                        : Pins.instance.items;
                    if (pins.isEmpty || !_show['pinned']!) return const SizedBox.shrink();
                    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                      _Section('Pinned'),
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 12),
                        child: Wrap(spacing: 10, runSpacing: 10, children: [
                          for (final p in pins)
                            _LibraryButton(label: p.name, icon: Icons.push_pin_outlined,
                                onTap: () => _openPin(p),
                                onLongPress: () => showPinDialog(context, p, pinned: true)),
                        ]),
                      ),
                    ]);
                  },
                ),
                if (_show['libraries']!) ...[
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
                ],
              ]),
            )),
    );
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

/// A horizontal strip of book posters (D-pad left/right moves along it).
class _BookRow extends StatelessWidget {
  const _BookRow({required this.books, required this.api, required this.onOpen, required this.onChanged,
      this.autofocusFirst = false});
  final List<dynamic> books;
  final Komga api;
  final void Function(dynamic book) onOpen;
  final VoidCallback onChanged;
  final bool autofocusFirst;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 290,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        itemCount: books.length,
        separatorBuilder: (_, __) => const SizedBox(width: 8),
        itemBuilder: (context, i) => SizedBox(
          width: 150,
          child: bookTile(context, api, books[i], autofocus: autofocusFirst && i == 0,
              onChanged: onChanged, onOpen: () => onOpen(books[i])),
        ),
      ),
    );
  }
}

class _LibraryButton extends StatelessWidget {
  const _LibraryButton({required this.label, required this.onTap, this.icon = Icons.folder_outlined, this.autofocus = false,
      this.onLongPress});
  final String label;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;
  final IconData icon;
  final bool autofocus;
  @override
  Widget build(BuildContext context) => GestureDetector(
        onSecondaryTap: onLongPress, // right-click on desktop
        child: _button(),
      );

  Widget _button() => FilledButton.tonalIcon(
        autofocus: autofocus,
        style: FilledButton.styleFrom(padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 16)),
        onPressed: onTap,
        onLongPress: onLongPress,
        icon: Icon(icon),
        label: Text(label),
      );
}

/// Shown on Home while offline: what you're looking at, and the way back.
class _OfflineBanner extends StatelessWidget {
  const _OfflineBanner();
  @override
  Widget build(BuildContext context) => Container(
        margin: const EdgeInsets.fromLTRB(12, 8, 12, 0),
        padding: const EdgeInsets.fromLTRB(14, 8, 8, 8),
        decoration: BoxDecoration(
          color: const Color(0xFF2A2410),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: const Color(0xFF6B5A1E)),
        ),
        child: Row(children: [
          const Icon(Icons.cloud_off, color: Color(0xFFFACC15)),
          const SizedBox(width: 10),
          const Expanded(child: Text('Offline mode - showing downloaded books')),
          TextButton(onPressed: () => Connection.instance.setForcedOffline(false), child: const Text('Go online')),
        ]),
      );
}

