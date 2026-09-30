import 'package:flutter/material.dart';

import '../api.dart';
import '../paged.dart';
import '../pins.dart';
import '../view_prefs.dart';
import '../widgets/breadcrumb.dart';
import '../widgets/fullscreen_exit.dart';
import '../widgets/poster.dart';
import '../widgets/selection.dart';
import 'actions.dart';
import 'library.dart';
import 'reader.dart';
import 'series.dart';

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

class _ReadListScreenState extends State<ReadListScreen> {
  ReadFilter _filter = ReadFilter.all;
  late final Paged _paged = Paged((page, size) =>
      widget.api.readListBooks(widget.readList['id'], readStatus: _filter.api, page: page, size: size));
  String get _viewKey => 'view.readlist.${widget.readList['id']}';
  final _sel = Selection();

  @override
  void initState() {
    super.initState();
    (widget.pin != null ? Future.value(widget.pin!.readFilter) : restoreFilter(_viewKey))
        .then((f) { if (mounted) { setState(() => _filter = f); _paged.more(); } });
  }

  void _setFilter(ReadFilter f) {
    setState(() => _filter = f);
    ViewPrefs.save(_viewKey, {'filter': f.name});
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
    return selectionScope(_sel, (context) => Scaffold(
      appBar: _sel.active
          ? selectionAppBar(context, widget.api, _sel, all: () => _paged.items, onChanged: _paged.refresh)
          : AppBar(
        title: Breadcrumb(parent: 'Read lists', title: widget.readList['name'] as String),
        actions: [
          Center(child: CountBadge(paged: _paged)),
          HideReadButton(value: _filter, onChanged: _setFilter),
          const PosterSizeButton(),
          PinButton(current: Pin(
            name: [widget.readList['name'] as String, if (_filter == ReadFilter.hideRead) 'unread'].join(' · '),
            kind: 'readlist', id: rlId, title: widget.readList['name'] as String, filter: _filter.name,
          )),
          SelectButton(selection: _sel),
          IconButton(tooltip: 'Read list actions', icon: const Icon(Icons.more_vert),
              onPressed: () => showReadListActions(context, widget.api, widget.readList, onChanged: _paged.refresh)),
          const FullscreenExit(),
        ],
      ),
      body: PagedPosterGrid(
        paged: _paged,
        empty: _filter == ReadFilter.hideRead ? 'Nothing unread in this list' : 'Nothing here',
        itemBuilder: (context, b, i) => bookTile(context, widget.api, b, autofocus: i == 0,
            readListId: rlId, onChanged: _paged.refresh, selection: _sel, onOpen: () async {
          await Navigator.of(context).push(MaterialPageRoute(
              builder: (_) => ReaderScreen(api: widget.api, book: b, readListId: rlId)));
          _paged.refresh();
        }),
      ),
    ));
  }
}
