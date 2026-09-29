import 'dart:async';

import 'package:flutter/material.dart';

import '../api.dart';
import '../widgets/fullscreen_exit.dart';
import '../widgets/poster.dart';
import '../widgets/poster_row.dart';
import '../widgets/readlist_tile.dart';
import 'library.dart';
import 'reader.dart';
import 'readlist.dart';
import 'series.dart';

/// Search (Home and library screens' search button): Komga's search across series, books, read lists and collections
/// (offline: titles of the downloaded ones). Results come as you type, in poster rows with their counts. Opened from a
/// library it searches that library first, with a chip to widen to all libraries.
class SearchScreen extends StatefulWidget {
  const SearchScreen({super.key, required this.api, this.libraryId, this.libraryName});
  final Komga api;
  final String? libraryId;
  final String? libraryName;
  @override
  State<SearchScreen> createState() => _SearchScreenState();
}

class _SearchScreenState extends State<SearchScreen> {
  final _text = TextEditingController();
  Timer? _debounce;
  late bool _inLibrary = widget.libraryId != null;
  String _query = '';
  bool _searching = false;
  String? _error;
  Map<String, dynamic> _series = {}, _books = {}, _readLists = {}, _collections = {};
  int _generation = 0; // answers to an older query are dropped

  Komga get api => widget.api;

  @override
  void dispose() {
    _debounce?.cancel();
    _text.dispose();
    super.dispose();
  }

  void _onChanged(String value) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 350), () => _search(value));
  }

  Future<void> _search(String value) async {
    final q = value.trim();
    final gen = ++_generation;
    if (q.isEmpty) {
      setState(() { _query = ''; _series = _books = _readLists = _collections = {}; _error = null; });
      return;
    }
    setState(() { _query = q; _searching = true; _error = null; });
    final lib = _inLibrary ? widget.libraryId : null;
    try {
      final r = await Future.wait([
        api.searchSeries(q, libraryId: lib),
        api.searchBooks(q, libraryId: lib),
        api.searchReadLists(q, libraryId: lib),
        api.searchCollections(q, libraryId: lib),
      ]);
      if (gen != _generation || !mounted) return;
      setState(() { _series = r[0]; _books = r[1]; _readLists = r[2]; _collections = r[3]; _searching = false; });
    } catch (e) {
      if (gen != _generation || !mounted) return;
      setState(() { _error = '$e'; _searching = false; });
    }
  }

  Future<void> _push(Widget w) async {
    await Navigator.of(context).push(MaterialPageRoute(builder: (_) => w));
    if (_query.isNotEmpty) _search(_query); // read state may have changed
  }

  List<dynamic> _items(Map<String, dynamic> r) => (r['content'] as List<dynamic>?) ?? const [];
  String _title(String what, Map<String, dynamic> r) => '$what · ${r['totalElements'] ?? _items(r).length}';

  @override
  Widget build(BuildContext context) {
    final series = _items(_series), books = _items(_books), lists = _items(_readLists), cols = _items(_collections);
    final nothing = _query.isNotEmpty && !_searching && _error == null &&
        series.isEmpty && books.isEmpty && lists.isEmpty && cols.isEmpty;
    return Scaffold(
      appBar: AppBar(
        title: TextField(
          controller: _text,
          autofocus: true,
          textInputAction: TextInputAction.search,
          decoration: const InputDecoration(hintText: 'Search series, books, lists…', border: InputBorder.none),
          onChanged: _onChanged,
          onSubmitted: (v) { _debounce?.cancel(); _search(v); },
        ),
        actions: [
          if (_text.text.isNotEmpty)
            IconButton(tooltip: 'Clear', icon: const Icon(Icons.close), onPressed: () { _text.clear(); _search(''); }),
          const FullscreenExit(),
        ],
        bottom: widget.libraryId == null
            ? null
            : PreferredSize(
                preferredSize: const Size.fromHeight(44),
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(12, 0, 12, 6),
                  child: Row(children: [
                    ChoiceChip(label: Text('In ${widget.libraryName ?? 'this library'}'), selected: _inLibrary,
                        onSelected: (_) { setState(() => _inLibrary = true); _search(_query); }),
                    const SizedBox(width: 8),
                    ChoiceChip(label: const Text('All libraries'), selected: !_inLibrary,
                        onSelected: (_) { setState(() => _inLibrary = false); _search(_query); }),
                  ]),
                ),
              ),
      ),
      body: ListView(padding: const EdgeInsets.only(bottom: 24), children: [
        if (_searching) const LinearProgressIndicator(minHeight: 2),
        if (_error != null)
          Padding(padding: const EdgeInsets.all(16), child: Text(_error!, style: const TextStyle(color: Color(0xFFFF8A80)))),
        if (_query.isEmpty)
          const Padding(padding: EdgeInsets.all(24),
              child: Text('Type to search.', style: TextStyle(color: Color(0xFF9A9A9A)))),
        if (nothing)
          Padding(padding: const EdgeInsets.all(24),
              child: Text('Nothing found for "$_query"', style: const TextStyle(color: Color(0xFF9A9A9A)))),
        if (series.isNotEmpty)
          PosterRow(
            title: _title('Series', _series),
            itemCount: series.length,
            itemBuilder: (context, i) => seriesTile(context, api, series[i],
                onOpen: () => _push(SeriesScreen(api: api, series: series[i]))),
          ),
        if (books.isNotEmpty)
          PosterRow(
            title: _title('Books', _books),
            itemCount: books.length,
            itemBuilder: (context, i) => bookTile(context, api, books[i],
                onOpen: () => _push(ReaderScreen(api: api, book: books[i]))),
          ),
        if (lists.isNotEmpty)
          PosterRow(
            title: _title('Read lists', _readLists),
            itemCount: lists.length,
            itemBuilder: (context, i) => ReadListTile(api: api, readList: lists[i],
                onOpen: () => _push(ReadListScreen(api: api, readList: lists[i]))),
          ),
        if (cols.isNotEmpty)
          PosterRow(
            title: _title('Collections', _collections),
            itemCount: cols.length,
            itemBuilder: (context, i) => PosterTile(
              api: api, imageUrl: api.collectionThumb(cols[i]['id'] as String), title: cols[i]['name'] as String,
              subtitle: '${(cols[i]['seriesIds'] as List?)?.length ?? 0} series',
              onOpen: () => _push(SeriesListScreen(api: api, title: cols[i]['name'] as String,
                  collectionId: cols[i]['id'] as String)),
            ),
          ),
      ]),
    );
  }
}
