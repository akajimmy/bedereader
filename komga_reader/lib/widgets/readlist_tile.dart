import 'package:flutter/material.dart';

import '../api.dart';
import 'poster.dart';

/// Read-list tile whose poster is built from the first four UNREAD books of the list (Komga's own read-list
/// thumbnail uses the first four books, read or not). Subtitle: "12 of 40 unread". A finished list falls back to
/// Komga's thumbnail and shows as read.
class ReadListTile extends StatefulWidget {
  const ReadListTile({super.key, required this.api, required this.readList, required this.onOpen, this.onMenu,
      this.autofocus = false});
  final Komga api;
  final dynamic readList;
  final VoidCallback onOpen;
  final VoidCallback? onMenu; // long-press: read-list actions
  final bool autofocus;

  /// Unread lookups, kept while scrolling; cleared when read state may have changed (returning from a list or book).
  static final Map<String, Future<Map<String, dynamic>>> _cache = {};
  static void invalidate() => _cache.clear();

  @override
  State<ReadListTile> createState() => _ReadListTileState();
}

class _ReadListTileState extends State<ReadListTile> {
  late Future<Map<String, dynamic>> _unread;

  String get _id => widget.readList['id'] as String;

  @override
  void initState() {
    super.initState();
    _lookup();
  }

  @override
  void didUpdateWidget(ReadListTile old) {
    super.didUpdateWidget(old);
    _lookup(); // picks up a fresh lookup after invalidate()
  }

  void _lookup() {
    _unread = ReadListTile._cache.putIfAbsent(_id, () {
      final f = widget.api.readListBooks(_id, readStatus: const ['UNREAD'], size: 4);
      f.catchError((Object _) {
        ReadListTile._cache.remove(_id);
        return <String, dynamic>{};
      });
      return f;
    });
  }

  @override
  Widget build(BuildContext context) {
    final total = (widget.readList['bookIds'] as List?)?.length ?? 0;
    return FutureBuilder<Map<String, dynamic>>(
      future: _unread,
      builder: (context, snap) {
        final r = snap.data;
        final books = (r?['content'] as List<dynamic>?) ?? const [];
        final unread = r?['totalElements'] as int?;
        final done = r != null && unread == 0;
        return PosterTile(
          api: widget.api,
          autofocus: widget.autofocus,
          imageUrl: widget.api.readListThumb(_id),
          image: books.isEmpty ? null : _Mosaic(api: widget.api, books: books),
          title: widget.readList['name'] as String,
          subtitle: unread == null ? '$total books' : done ? '$total books · read' : '$unread of $total unread',
          read: done && total > 0,
          onOpen: widget.onOpen,
          onMenu: widget.onMenu,
        );
      },
    );
  }
}

/// 1 book = its cover; 2 = side by side; 3-4 = a 2x2 grid (an empty dark cell for 3).
class _Mosaic extends StatelessWidget {
  const _Mosaic({required this.api, required this.books});
  final Komga api;
  final List<dynamic> books;

  Widget _cover(int i) => i < books.length
      ? Image.network(api.bookThumb(books[i]['id'] as String), headers: api.imageHeaders, fit: BoxFit.cover,
          cacheWidth: 220, errorBuilder: (_, __, ___) => const ColoredBox(color: Color(0xFF1C1C1F)))
      : const ColoredBox(color: Color(0xFF1C1C1F));

  @override
  Widget build(BuildContext context) {
    const gap = SizedBox(width: 2, height: 2);
    if (books.length == 1) return _cover(0);
    if (books.length == 2) {
      return Row(crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [Expanded(child: _cover(0)), gap, Expanded(child: _cover(1))]);
    }
    Widget row(int a) => Expanded(child: Row(crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [Expanded(child: _cover(a)), gap, Expanded(child: _cover(a + 1))]));
    return ColoredBox(color: Colors.black, child: Column(children: [row(0), gap, row(2)]));
  }
}
