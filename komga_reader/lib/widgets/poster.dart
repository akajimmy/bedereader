import 'package:flutter/material.dart';

import '../api.dart';
import '../paged.dart';

/// One focusable grid item: poster (Komga thumbnail, incl. custom cover crops) + title + small status line.
/// Works with touch and with the remote: D-pad moves focus between tiles, OK activates.
class PosterTile extends StatelessWidget {
  const PosterTile({super.key, required this.api, required this.imageUrl, required this.title,
      this.subtitle, this.read = false, this.progress, required this.onOpen, this.onMenu, this.autofocus = false,
      this.image, this.selected});

  final Komga api;
  final String imageUrl;
  final bool? selected; // multi-select: null = not selecting, else ticked or not
  final Widget? image; // drawn instead of the Komga thumbnail at [imageUrl] (read-list mosaics)
  final String title;
  final String? subtitle;
  final bool read;
  final double? progress; // 0..1 for books in progress
  final VoidCallback onOpen;
  final VoidCallback? onMenu;
  final bool autofocus;

  /// Two title lines (13 px, line height 1.2) + one subtitle line (11 px, 1.3), following the tablet's text size.
  static double textBlockHeight(BuildContext context) {
    final t = MediaQuery.textScalerOf(context);
    return t.scale(13) * 1.2 * 2 + t.scale(11) * 1.3 + 2;
  }

  @override
  Widget build(BuildContext context) {
    final accent = Theme.of(context).colorScheme.primary;
    return Focus(
      canRequestFocus: false,
      skipTraversal: true,
      child: Builder(builder: (context) {
        return InkWell(
          autofocus: autofocus,
          onTap: onOpen,
          onLongPress: onMenu,
          onSecondaryTap: onMenu, // right-click on desktop
          borderRadius: BorderRadius.circular(6),
          focusColor: Colors.transparent,
          child: _FocusFrame(accent: accent, child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Expanded(
              child: ClipRRect(
                borderRadius: BorderRadius.circular(4),
                child: Stack(fit: StackFit.expand, children: [
                  image ?? Image.network(imageUrl, headers: api.imageHeaders, fit: BoxFit.cover, cacheWidth: 400,
                      errorBuilder: (_, __, ___) => Container(color: const Color(0xFF1C1C1F))),
                  if (read) Container(color: Colors.black.withValues(alpha: 0.45)),
                  if (read) const Positioned(right: 6, top: 6, child: _ReadBadge()),
                  if (selected != null) ...[
                    if (selected!)
                      DecoratedBox(decoration: BoxDecoration(
                        color: accent.withValues(alpha: 0.30),
                        border: Border.all(color: accent, width: 4),
                        borderRadius: BorderRadius.circular(4),
                      )),
                    Positioned(left: 6, top: 6, child: Icon(
                      selected! ? Icons.check_box : Icons.check_box_outline_blank,
                      size: 32, color: selected! ? accent : Colors.white,
                      shadows: const [Shadow(color: Colors.black, blurRadius: 6)],
                    )),
                  ],
                  if (progress != null && !read)
                    Positioned(left: 0, right: 0, bottom: 0,
                        child: LinearProgressIndicator(value: progress, minHeight: 3, color: accent, backgroundColor: Colors.black54)),
                ]),
              ),
            ),
            const SizedBox(height: 6),
            // Fixed-height text block (always room for a 2-line title + the subtitle), so a long title never takes
            // height from the cover: every cover in a grid or row stays the same size.
            SizedBox(
              height: textBlockHeight(context),
              child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                Text(title, maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 13, height: 1.2)),
                if (subtitle != null)
                  Text(subtitle!, maxLines: 1, overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 11, height: 1.3, color: Color(0xFF9A9A9A))),
              ]),
            ),
          ])),
        );
      }),
    );
  }
}

/// Draws a clear outline around the tile while it has focus (the remote needs to see where it is).
class _FocusFrame extends StatefulWidget {
  const _FocusFrame({required this.child, required this.accent});
  final Widget child;
  final Color accent;
  @override
  State<_FocusFrame> createState() => _FocusFrameState();
}

class _FocusFrameState extends State<_FocusFrame> {
  // The outline only shows once the remote/keyboard is in use (Flutter's "traditional" highlight mode, entered on the
  // first key press and left again on the next touch), so touch users never see it.
  @override
  void initState() {
    super.initState();
    FocusManager.instance.addHighlightModeListener(_onMode);
  }

  @override
  void dispose() {
    FocusManager.instance.removeHighlightModeListener(_onMode);
    super.dispose();
  }

  void _onMode(FocusHighlightMode _) { if (mounted) setState(() {}); }

  @override
  Widget build(BuildContext context) {
    final focused = Focus.of(context).hasFocus &&
        FocusManager.instance.highlightMode == FocusHighlightMode.traditional;
    return AnimatedContainer(
      duration: const Duration(milliseconds: 120),
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: focused ? widget.accent : Colors.transparent, width: 2),
      ),
      child: widget.child,
    );
  }
}

/// Grid that sizes columns for phone / tablet / desktop.
class PosterGrid extends StatelessWidget {
  const PosterGrid({super.key, required this.itemCount, required this.itemBuilder, this.controller});
  final int itemCount;
  final IndexedWidgetBuilder itemBuilder;
  final ScrollController? controller;

  @override
  Widget build(BuildContext context) {
    return GridView.builder(
      controller: controller,
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 24),
      gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
          maxCrossAxisExtent: 170, childAspectRatio: 0.52, mainAxisSpacing: 10, crossAxisSpacing: 8),
      itemCount: itemCount,
      itemBuilder: itemBuilder,
    );
  }
}

/// A [PosterGrid] over a [Paged] listing: asks for the next page when the grid gets within ~2 screens of the end
/// (scrolling by touch, or by moving focus down with the remote), with a spinner row while it loads.
class PagedPosterGrid extends StatelessWidget {
  const PagedPosterGrid({super.key, required this.paged, required this.itemBuilder, this.empty = 'Nothing here'});
  final Paged paged;
  final Widget Function(BuildContext context, dynamic item, int index) itemBuilder;
  final String empty;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: paged,
      builder: (context, _) {
        if (paged.firstLoad) return const Center(child: CircularProgressIndicator());
        if (paged.items.isEmpty) {
          return Center(child: Text(paged.error != null ? '${paged.error}' : empty,
              style: TextStyle(color: paged.error != null ? const Color(0xFFFF8A80) : const Color(0xFF9A9A9A))));
        }
        return CustomScrollView(slivers: [
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
            sliver: SliverGrid.builder(
              gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                  maxCrossAxisExtent: 170, childAspectRatio: 0.52, mainAxisSpacing: 10, crossAxisSpacing: 8),
              itemCount: paged.items.length,
              itemBuilder: (context, i) {
                if (i >= paged.items.length - 30 && paged.hasMore && !paged.loading && paged.error == null) {
                  WidgetsBinding.instance.addPostFrameCallback((_) => paged.more());
                }
                return itemBuilder(context, paged.items[i], i);
              },
            ),
          ),
          SliverToBoxAdapter(
            child: SizedBox(
              height: 56,
              child: paged.error != null
                  ? Center(child: TextButton(onPressed: paged.more, child: const Text("Couldn't load more - retry")))
                  : paged.hasMore
                  ? const Center(child: SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2)))
                  : Center(child: Text('${paged.items.length} shown', style: const TextStyle(color: Color(0xFF6A6A6A), fontSize: 12))),
            ),
          ),
        ]);
      },
    );
  }
}

/// "Read" mark on a poster: a bright green tick on a white disc with a shadow, so it stands out on any cover.
class _ReadBadge extends StatelessWidget {
  const _ReadBadge();
  @override
  Widget build(BuildContext context) => Container(
        decoration: const BoxDecoration(
          shape: BoxShape.circle,
          color: Colors.white,
          boxShadow: [BoxShadow(color: Colors.black54, blurRadius: 6, offset: Offset(0, 2))],
        ),
        child: const Icon(Icons.check_circle, size: 40, color: Color(0xFF16C75F)),
      );
}

/// The number of items in the current view (the server's total for the active filter), in a small box - shown in
/// the header next to the Hide read button. "…" until the first page arrives.
class CountBadge extends StatelessWidget {
  const CountBadge({super.key, required this.paged});
  final Paged paged;
  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: paged,
        builder: (context, _) {
          final n = paged.total ?? (paged.firstLoad ? null : paged.items.length);
          return Semantics(
            label: n == null ? 'counting' : '$n items',
            child: Container(
              margin: const EdgeInsets.symmetric(horizontal: 4),
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(6),
                border: Border.all(color: const Color(0xFF4A4D55)),
                color: const Color(0xFF17181C),
              ),
              child: Text(n == null ? '…' : '$n',
                  style: const TextStyle(fontSize: 13, fontFeatures: [FontFeature.tabularFigures()])),
            ),
          );
        },
      );
}

