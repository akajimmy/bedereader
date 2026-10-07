import 'package:flutter/material.dart';

import '../api.dart';
import 'download_badge.dart';
import 'poster.dart';

/// What a read list or a collection holds under a read filter: its first four matching items (for the 2x2 poster)
/// and how many match. One lookup per list and filter, shared by the tiles and by the screens that leave out lists
/// with nothing matching (user, 2026-10-07: the eye on every library screen; the posters follow it).
class ListContents {
  ListContents._();

  /// Lookups kept while scrolling; cleared when read state may have changed (returning from a list or book).
  static final Map<String, Future<Map<String, dynamic>>> _cache = {};
  static void invalidate() => _cache.clear();

  /// {content: the first four matching, matching: how many match, unread: (a read list on All) how many to read}.
  /// Empty if Komga couldn't say (asked again next time).
  static Future<Map<String, dynamic>> of(Komga api,
      {required bool readList, required String id, required ReadFilter filter}) {
    final key = '${readList ? 'readlist' : 'collection'}:$id:${filter.name}';
    return _cache[key] ??= _lookup(api, readList, id, filter).catchError((Object _) {
      _cache.remove(key);
      return <String, dynamic>{};
    });
  }

  static Future<Map<String, dynamic>> _lookup(Komga api, bool readList, String id, ReadFilter filter) async {
    if (!readList) {
      final r = await api.series(collectionId: id, readStatus: filter.api, size: 4);
      return {'content': r['content'], 'matching': r['totalElements']};
    }
    if (filter != ReadFilter.all) {
      final r = await api.readListBooks(id, readStatus: filter.api, size: 4);
      return {'content': r['content'], 'matching': r['totalElements']};
    }
    // All: the first four books, read or not - and how many are still to read, for "12 of 40 unread"
    final r = await Future.wait([
      api.readListBooks(id, size: 4),
      api.readListBooks(id, readStatus: ReadFilter.hideRead.api, size: 1),
    ]);
    return {'content': r[0]['content'], 'matching': r[0]['totalElements'], 'unread': r[1]['totalElements']};
  }

  /// A library's read lists or collections with something matching [filter] - all of them, in one page: Komga can't
  /// filter them by read state, so each is looked at, and a page filtered short would end the paging early.
  static Future<Map<String, dynamic>> matching(Komga api,
      {required bool readLists, String? libraryId, required ReadFilter filter}) async {
    final all = <dynamic>[];
    for (var page = 0;; page++) {
      final r = readLists
          ? await api.readLists(libraryId: libraryId, page: page)
          : await api.collections(libraryId: libraryId, page: page);
      final content = (r['content'] as List?) ?? const [];
      all.addAll(content);
      if (r['last'] != false || content.isEmpty) break;
    }
    final looked = await Future.wait([
      for (final it in all) of(api, readList: readLists, id: it['id'] as String, filter: filter),
    ]);
    // (a list Komga couldn't say about stays: better shown than lost)
    final kept = [for (var i = 0; i < all.length; i++) if (looked[i]['matching'] != 0) all[i]];
    return {'content': kept, 'last': true, 'totalElements': kept.length};
  }
}

/// Read-list tile whose poster is a 2x2 of the list's first four books as the filter shows them - read or not on
/// All, unread on Hide read, read on Hide unread (user, 2026-10-07; it always took the unread ones). Subtitle:
/// "12 of 40 unread" (on All and Hide read), "28 of 40 read" (Hide unread). A finished list shows as read.
class ReadListTile extends StatefulWidget {
  const ReadListTile({super.key, required this.api, required this.readList, required this.onOpen, this.onMenu,
      this.autofocus = false, this.filter = ReadFilter.all});
  final Komga api;
  final dynamic readList;
  final VoidCallback onOpen;
  final VoidCallback? onMenu; // long-press: read-list actions
  final bool autofocus;
  final ReadFilter filter;

  /// Lookups behind the posters: cleared when read state may have changed.
  static void invalidate() => ListContents.invalidate();

  @override
  State<ReadListTile> createState() => _ReadListTileState();
}

class _ReadListTileState extends State<ReadListTile> {
  late Future<Map<String, dynamic>> _contents;

  String get _id => widget.readList['id'] as String;

  @override
  void initState() {
    super.initState();
    _lookup();
  }

  @override
  void didUpdateWidget(ReadListTile old) {
    super.didUpdateWidget(old);
    _lookup(); // a fresh lookup after invalidate(), or for another filter
  }

  void _lookup() => _contents = ListContents.of(widget.api, readList: true, id: _id, filter: widget.filter);

  @override
  Widget build(BuildContext context) {
    final total = (widget.readList['bookIds'] as List?)?.length ?? 0;
    return FutureBuilder<Map<String, dynamic>>(
      future: _contents,
      builder: (context, snap) {
        final r = snap.data;
        final books = (r?['content'] as List<dynamic>?) ?? const [];
        final matching = r?['matching'] as int?;
        final unread = widget.filter == ReadFilter.all ? (r?['unread'] as int?) : null;
        final (subtitle, done) = switch (widget.filter) {
          ReadFilter.all => unread == null
              ? ('$total books', false)
              : unread == 0
                  ? ('$total books · read', true)
                  : ('$unread of $total unread', false),
          ReadFilter.hideRead => matching == null ? ('$total books', false) : ('$matching of $total unread', false),
          ReadFilter.hideUnread => matching == null
              ? ('$total books', false)
              : matching == total
                  ? ('$total books · read', true)
                  : ('$matching of $total read', false),
        };
        return PosterTile(
          api: widget.api,
          autofocus: widget.autofocus,
          imageUrl: widget.api.readListThumb(_id),
          image: books.isEmpty
              ? null
              : PosterMosaic(api: widget.api, refs: [for (final b in books) widget.api.bookThumb(b['id'] as String)]),
          title: widget.readList['name'] as String,
          subtitle: subtitle,
          read: done && total > 0,
          badge: DownloadBadge.readList(_id, total: total),
          onOpen: widget.onOpen,
          onMenu: widget.onMenu,
        );
      },
    );
  }
}

/// Collection tile: Komga's own poster on All; under a filter, a 2x2 of its first four matching series and "3 of 8
/// series unread" / "read" (user, 2026-10-07).
class CollectionTile extends StatelessWidget {
  const CollectionTile({super.key, required this.api, required this.collection, required this.onOpen,
      this.autofocus = false, this.filter = ReadFilter.all});
  final Komga api;
  final dynamic collection;
  final VoidCallback onOpen;
  final bool autofocus;
  final ReadFilter filter;

  @override
  Widget build(BuildContext context) {
    final id = collection['id'] as String;
    final total = (collection['seriesIds'] as List?)?.length ?? 0;
    PosterTile tile({Widget? image, String? subtitle}) => PosterTile(
          api: api,
          autofocus: autofocus,
          imageUrl: api.collectionThumb(id),
          image: image,
          title: collection['name'] as String,
          subtitle: subtitle ?? '$total series',
          onOpen: onOpen,
        );
    if (filter == ReadFilter.all) return tile();
    return FutureBuilder<Map<String, dynamic>>(
      future: ListContents.of(api, readList: false, id: id, filter: filter),
      builder: (context, snap) {
        final series = (snap.data?['content'] as List<dynamic>?) ?? const [];
        final matching = snap.data?['matching'] as int?;
        return tile(
          image: series.isEmpty
              ? null
              : PosterMosaic(api: api, refs: [for (final s in series) api.seriesThumb(s['id'] as String)]),
          subtitle: matching == null ? null : '$matching of $total series ${filter.shows}',
        );
      },
    );
  }
}

/// A poster made of up to four other posters: 1 = that poster; 2 = side by side; 3-4 = a 2x2 grid (an empty dark
/// cell for 3). [refs] are thumbnail references from the api (bookThumb / seriesThumb / ...). Used by read lists and
/// collections (their first matching items) and pins (first items of the pinned view).
class PosterMosaic extends StatelessWidget {
  const PosterMosaic({super.key, required this.api, required this.refs});
  final Komga api;
  final List<String> refs;

  Widget _cover(int i) => i < refs.length
      ? Image(image: ResizeImage(api.thumbImage(refs[i]), width: 220), fit: BoxFit.cover,
          errorBuilder: (_, __, ___) => const ColoredBox(color: Color(0xFF1C1C1F)))
      : const ColoredBox(color: Color(0xFF1C1C1F));

  @override
  Widget build(BuildContext context) {
    const gap = SizedBox(width: 2, height: 2);
    if (refs.length == 1) return _cover(0);
    if (refs.length == 2) {
      return Row(crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [Expanded(child: _cover(0)), gap, Expanded(child: _cover(1))]);
    }
    Widget row(int a) => Expanded(child: Row(crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [Expanded(child: _cover(a)), gap, Expanded(child: _cover(a + 1))]));
    return ColoredBox(color: Colors.black, child: Column(children: [row(0), gap, row(2)]));
  }
}
