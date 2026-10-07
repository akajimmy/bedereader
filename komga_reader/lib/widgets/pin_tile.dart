import 'package:flutter/material.dart';

import '../api.dart';
import '../pins.dart';
import 'poster.dart';
import 'readlist_tile.dart';

/// The pinned view's own query (its filter, mode and sort) - [size] items of it. Used for the pin's poster and
/// count, and offline to hide pins with nothing downloaded.
Future<Map<String, dynamic>> pinView(Komga api, Pin p, {int size = 4}) async {
  final status = p.readFilter.api;
  final parts = (p.sort ?? '').split(':');
  final desc = parts.length > 1 && parts[1] == 'desc';
  String? sortParam(Map<String, String> fields) =>
      fields[parts.first] == null ? null : '${fields[parts.first]},${desc ? 'desc' : 'asc'}';
  switch (p.kind) {
    case 'series':
      return api.seriesBooks(p.id!, readStatus: status,
          sort: p.sort == 'number:desc' ? 'metadata.numberSort,desc' : 'metadata.numberSort,asc', size: size);
    case 'readlist':
      return api.readListBooks(p.id!, readStatus: status, size: size);
    case 'collection':
      return api.series(collectionId: p.id, readStatus: status, size: size);
  }
  switch (p.mode) {
    case 'books':
      final s = sortParam(const {'title': 'metadata.title', 'added': 'createdDate', 'release': 'metadata.releaseDate'});
      return s == null
          ? api.books(libraryId: p.id, readStatus: status, size: size)
          : api.books(libraryId: p.id, readStatus: status, sort: s, size: size);
    case 'collections' || 'readLists' when p.readFilter != ReadFilter.all:
      // the lists with something matching, as the library screen shows them (Komga can't filter lists itself)
      final r = await ListContents.matching(api, readLists: p.mode == 'readLists', libraryId: p.id,
          filter: p.readFilter);
      return {...r, 'content': (r['content'] as List).take(size).toList()};
    case 'collections':
      return api.collections(libraryId: p.id, size: size);
    case 'readLists':
      return api.readLists(libraryId: p.id, size: size);
  }
  final s = sortParam(const {'title': 'metadata.titleSort', 'added': 'createdDate', 'updated': 'lastModifiedDate'});
  return s == null
      ? api.series(libraryId: p.id, readStatus: status, size: size)
      : api.series(libraryId: p.id, readStatus: status, sort: s, size: size);
}

/// What a pinned view lists, for its count: "12 books", "3 series", ...
String _noun(Pin p, int n) {
  final what = switch (p.kind) {
    'series' || 'readlist' => 'book',
    'collection' => 'series',
    _ => switch (p.mode) { 'books' => 'book', 'collections' => 'collection', 'readLists' => 'read list', _ => 'series' },
  };
  return what == 'series' ? '$n series' : '$n $what${n == 1 ? '' : 's'}';
}

/// Thumbnail references for the items of a pinned view.
List<String> _thumbs(Komga api, Pin p, List<dynamic> items) {
  String Function(String) thumb = switch (p.kind) {
    'series' || 'readlist' => api.bookThumb,
    'collection' => api.seriesThumb,
    _ => switch (p.mode) {
        'books' => api.bookThumb,
        'collections' => api.collectionThumb,
        'readLists' => api.readListThumb,
        _ => api.seriesThumb,
      },
  };
  return [for (final i in items) thumb(i['id'] as String)];
}

/// A pin on Home as a poster: a 2x2 of the first four items of its view, the pin's name, and the view's count.
/// Tap opens the view; long-press (or right-click) renames or unpins.
class PinTile extends StatefulWidget {
  const PinTile({super.key, required this.api, required this.pin, required this.onOpen, this.autofocus = false});
  final Komga api;
  final Pin pin;
  final VoidCallback onOpen;
  final bool autofocus;

  /// Looked-up views, kept while Home is shown; cleared when Home refreshes.
  static final Map<String, Future<Map<String, dynamic>>> _cache = {};
  static void invalidate() => _cache.clear();

  @override
  State<PinTile> createState() => _PinTileState();
}

class _PinTileState extends State<PinTile> {
  late Future<Map<String, dynamic>> _view;

  String get _key => '${widget.api.runtimeType}|${widget.pin.toJson()}';

  @override
  void initState() {
    super.initState();
    _lookup();
  }

  @override
  void didUpdateWidget(PinTile old) {
    super.didUpdateWidget(old);
    _lookup();
  }

  void _lookup() {
    _view = PinTile._cache.putIfAbsent(_key, () {
      final f = pinView(widget.api, widget.pin);
      f.catchError((Object _) {
        PinTile._cache.remove(_key);
        return <String, dynamic>{};
      });
      return f;
    });
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<Map<String, dynamic>>(
      future: _view,
      builder: (context, snap) {
        final items = (snap.data?['content'] as List<dynamic>?) ?? const [];
        final total = snap.data?['totalElements'] as int?;
        return PosterTile(
          api: widget.api,
          autofocus: widget.autofocus,
          imageUrl: '',
          image: items.isEmpty
              ? const ColoredBox(color: Color(0xFF1C1C1F), child: Center(child: Icon(Icons.push_pin_outlined, color: Color(0xFF6A6A6A))))
              : PosterMosaic(api: widget.api, refs: _thumbs(widget.api, widget.pin, items.take(4).toList())),
          title: widget.pin.name,
          subtitle: total == null ? null : _noun(widget.pin, total),
          onOpen: widget.onOpen,
          onMenu: () => showPinDialog(context, widget.pin, pinned: true),
        );
      },
    );
  }
}
