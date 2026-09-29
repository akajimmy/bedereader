import 'package:flutter/material.dart';

/// A row of posters (Home, Search): its title with ‹ › buttons on the right (each scrolls about a screen's width; greyed at the ends),
/// then a horizontal strip of posters. Touch can swipe the strip, the remote's Left/Right move along it too.
class PosterRow extends StatefulWidget {
  const PosterRow({super.key, required this.title, required this.itemCount, required this.itemBuilder});
  final String title;
  final int itemCount;
  final IndexedWidgetBuilder itemBuilder;
  @override
  State<PosterRow> createState() => _PosterRowState();
}

class _PosterRowState extends State<PosterRow> {
  final _scroll = ScrollController();
  bool _canBack = false, _canForward = false;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_update);
    WidgetsBinding.instance.addPostFrameCallback((_) => _update());
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  void _update() {
    if (!mounted || !_scroll.hasClients) return;
    final p = _scroll.position;
    final back = p.pixels > 1, forward = p.pixels < p.maxScrollExtent - 1;
    if (back != _canBack || forward != _canForward) setState(() { _canBack = back; _canForward = forward; });
  }

  void _page(int direction) {
    final p = _scroll.position;
    _scroll.animateTo((p.pixels + direction * p.viewportDimension * 0.9).clamp(0.0, p.maxScrollExtent),
        duration: const Duration(milliseconds: 300), curve: Curves.easeOut);
  }

  @override
  Widget build(BuildContext context) {
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 8, 0),
        child: Row(children: [
          Expanded(child: Text(widget.title, style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w500))),
          IconButton(tooltip: '${widget.title}: back', icon: const Icon(Icons.chevron_left),
              onPressed: _canBack ? () => _page(-1) : null),
          IconButton(tooltip: '${widget.title}: more', icon: const Icon(Icons.chevron_right),
              onPressed: _canForward ? () => _page(1) : null),
        ]),
      ),
      SizedBox(
        height: 290,
        // the strip's size changes (window resized, posters loading) also update the buttons
        child: NotificationListener<ScrollMetricsNotification>(
          onNotification: (_) {
            _update();
            return false;
          },
          child: ListView.separated(
            controller: _scroll,
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 12),
            itemCount: widget.itemCount,
            separatorBuilder: (_, __) => const SizedBox(width: 8),
            itemBuilder: (context, i) => SizedBox(width: 150, child: widget.itemBuilder(context, i)),
          ),
        ),
      ),
    ]);
  }
}
