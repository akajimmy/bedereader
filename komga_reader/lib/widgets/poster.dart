import 'dart:async';

import 'package:flutter/gestures.dart' show kSecondaryButton;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';

import '../errors.dart';
import '../paged.dart';
import '../reader/reader_bars.dart' show isOkKey;
import '../reader_keys.dart';
import '../settings.dart';
import 'error_text.dart';
import '../book_source.dart';

/// Poster size in a screen's top bar (Home and the grids; user, 2026-09-30): a grid icon with S, M or L, opening
/// Small / Medium / Large. The same setting as Settings > Library & Home.
class PosterSizeButton extends StatelessWidget {
  const PosterSizeButton({super.key});
  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: AppSettings.instance,
        builder: (context, _) {
          final s = AppSettings.instance, size = s.display.posterSize;
          return PopupMenuButton<PosterSize>(
            tooltip: 'Poster size: ${size.label.toLowerCase()}',
            icon: Row(mainAxisSize: MainAxisSize.min, children: [
              const Icon(Icons.grid_view),
              const SizedBox(width: 2),
              Text(size.label[0], style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600)),
            ]),
            onSelected: (p) => s.setDisplay(s.display.copyWith(posterSize: p)),
            itemBuilder: (_) => [
              for (final p in PosterSize.values) CheckedPopupMenuItem(value: p, checked: p == size, child: Text(p.label)),
            ],
          );
        },
      );
}

/// Grid columns for the chosen poster size (Settings > Library & Home): about 170 px wide at Medium. Each row as tall
/// as a tile of that width needs ([PosterTile.heightFor]) - a fixed shape let a larger text size take its room from
/// the cover, cropped top and bottom (user, 2026-10-25).
SliverGridDelegate posterGridDelegate(BuildContext context) => _PosterGridDelegate(
    170 * AppSettings.instance.display.posterSize.scale, PosterTile.textBlockHeight(context, caption: true));

class _PosterGridDelegate extends SliverGridDelegate {
  const _PosterGridDelegate(this.maxWidth, this.text);
  final double maxWidth, text;
  static const _across = 8.0, _down = 10.0;

  @override
  SliverGridLayout getLayout(SliverConstraints constraints) {
    // the columns as SliverGridDelegateWithMaxCrossAxisExtent counts them
    final n = (constraints.crossAxisExtent / (maxWidth + _across)).ceil().clamp(1, 1 << 20);
    final width = ((constraints.crossAxisExtent - _across * (n - 1)) / n).clamp(0.0, double.infinity);
    final height = PosterTile.heightOf(width, text);
    return SliverGridRegularTileLayout(crossAxisCount: n, mainAxisStride: height + _down,
        crossAxisStride: width + _across, childMainAxisExtent: height, childCrossAxisExtent: width,
        reverseCrossAxis: axisDirectionIsReversed(constraints.crossAxisDirection));
  }

  @override
  bool shouldRelayout(_PosterGridDelegate old) => old.maxWidth != maxWidth || old.text != text;
}

/// One focusable grid item: poster (Komga thumbnail, incl. custom cover crops) + title + small status line.
/// Works with touch and with the remote: D-pad moves focus between tiles, OK activates.
class PosterTile extends StatelessWidget {
  const PosterTile({super.key, required this.api, required this.imageUrl, required this.title,
      this.subtitle, this.read = false, this.progress, required this.onOpen, this.onMenu, this.autofocus = false,
      this.image, this.selected, this.badge, this.caption, this.corner});

  final BookSource api;
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
  final Widget? badge; // bottom-right corner (what of it is downloaded)
  final String? corner; // top-left, on the cover: a webtoon episode's number ("Ep. 12")
  /// A last small line (book posters: the release date). Not null = the line is there, even empty (a book with no
  /// date), so every poster in a grid keeps the same cover size.
  final String? caption;

  /// Two title lines (13 px, line height 1.2) + one subtitle line (11 px, 1.3), and one more small line with a
  /// [caption], following the tablet's text size.
  static double textBlockHeight(BuildContext context, {bool caption = false}) {
    final t = MediaQuery.textScalerOf(context);
    return t.scale(13) * 1.2 * 2 + t.scale(11) * 1.3 * (caption ? 2 : 1) + 2;
  }

  /// The cover's shape, width to height: a comic page's (6.625 x 10.25 in print, 1988 x 3056 digital).
  static const coverAspect = 0.65;

  /// How tall a tile [width] wide is, the cover at [coverAspect] with room for every text line (a caption too) at the
  /// text size now: rows and grids are sized by it, so the text never takes height from the cover.
  static double heightFor(BuildContext context, double width) =>
      heightOf(width, textBlockHeight(context, caption: true));

  static double heightOf(double width, double text) => _frame + (width - _frame) / coverAspect + 6 + text;
  static const _frame = 12.0; // the focus frame: 4 padding and a 2 border, each side

  @override
  Widget build(BuildContext context) {
    final accent = Theme.of(context).colorScheme.primary;
    return HoldOkForMenu(
      onTap: onOpen,
      onHold: onMenu,
      child: Builder(builder: (context) {
        return _RightClick(
          onClick: onMenu, // the menu, on desktop
          child: InkWell(
            autofocus: autofocus,
            onTap: onOpen,
            onLongPress: onMenu,
            borderRadius: BorderRadius.circular(6),
            focusColor: Colors.transparent,
            child: _FocusFrame(accent: accent, child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              // the cover keeps its shape: the full width, unless the tile is too short (then narrower, never
              // cropped); any spare height goes under the text
              Flexible(
                child: Align(alignment: Alignment.topCenter, heightFactor: 1, child: AspectRatio(
                aspectRatio: coverAspect,
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(4),
                  child: Stack(fit: StackFit.expand, children: [
                    image ?? Image(image: ResizeImage(api.thumbImage(imageUrl), width: 400), fit: BoxFit.cover,
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
                    if (corner != null && selected == null)
                      Positioned(
                        left: 6,
                        top: 6,
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                          decoration: BoxDecoration(color: Colors.black.withValues(alpha: 0.72),
                              borderRadius: BorderRadius.circular(10)),
                          child: Text(corner!, style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600,
                              color: Colors.white)),
                        ),
                      ),
                    if (badge != null) Positioned(right: 6, bottom: 9, child: badge!), // clear of the progress bar
                    if (progress != null && !read)
                      Positioned(left: 0, right: 0, bottom: 0,
                          child: LinearProgressIndicator(value: progress, minHeight: 3, color: accent, backgroundColor: Colors.black54)),
                  ]),
                ),
              ))),
              const SizedBox(height: 6),
              // Fixed-height text block (always room for a 2-line title + the subtitle), so a long title never takes
              // height from the cover: every cover in a grid or row stays the same size.
              SizedBox(
                height: textBlockHeight(context, caption: caption != null),
                child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                  Text(title, maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 13, height: 1.2)),
                  if (subtitle != null)
                    Text(subtitle!, maxLines: 1, overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 11, height: 1.3, color: Color(0xFF9A9A9A))),
                  if (caption != null && caption!.isNotEmpty)
                    Text(caption!, maxLines: 1, overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 11, height: 1.3, color: Color(0xFF7A7A7A))),
                ]),
              ),
            ])),
          ),
        );
      }),
    );
  }
}

/// A right-click on [child] (a mouse, or a pen's side button): [onClick] when the button is let go, however far the
/// pointer moved meanwhile - as a gesture a right-click moved past 18 px was lost, and nothing is dragged with the
/// right button (user, build 108: "right clicks get missed if the mouse moves").
class _RightClick extends StatefulWidget {
  const _RightClick({required this.onClick, required this.child});
  final VoidCallback? onClick;
  final Widget child;
  @override
  State<_RightClick> createState() => _RightClickState();
}

class _RightClickState extends State<_RightClick> {
  bool _down = false;

  @override
  Widget build(BuildContext context) => widget.onClick == null
      ? widget.child
      : Listener(
          onPointerDown: (e) => _down = e.buttons == kSecondaryButton,
          onPointerCancel: (_) => _down = false,
          onPointerUp: (_) {
            if (!_down) return;
            _down = false;
            widget.onClick!();
          },
          child: widget.child,
        );
}

/// The remote's OK on a focused tile: a press opens it (as a tap), holding it for half a second opens its menu (as a
/// long press or a right-click) - otherwise a remote couldn't reach the menu (user, 2026-09-30). OK is Enter / Select,
/// and any keys given "Show the controls" in Remote and keys.
class HoldOkForMenu extends StatefulWidget {
  const HoldOkForMenu({super.key, required this.onTap, required this.onHold, required this.child});
  final VoidCallback onTap;
  final VoidCallback? onHold; // nothing to hold for: OK is left to the tile (a plain press)
  final Widget child;

  static const holdTime = Duration(milliseconds: 500);

  @override
  State<HoldOkForMenu> createState() => _HoldOkForMenuState();
}

class _HoldOkForMenuState extends State<HoldOkForMenu> {
  Timer? _timer;
  bool _down = false; // an OK press that started here, not yet let go (and not yet a hold)

  bool _isOk(LogicalKeyboardKey k) => isOkKey(k) || ReaderKeys.instance.actionFor(k) == ReaderAction.controls;

  KeyEventResult _onKey(FocusNode node, KeyEvent e) {
    final hold = widget.onHold;
    if (hold == null || !_isOk(e.logicalKey)) return KeyEventResult.ignored;
    if (e is KeyDownEvent) {
      _down = true;
      _timer?.cancel();
      _timer = Timer(HoldOkForMenu.holdTime, () {
        _down = false; // held: the menu, and the release that follows does nothing more
        if (!mounted) return;
        HoldOkGuard.swallowRestOf(e.logicalKey); // the menu takes focus: the key's repeats mustn't press in it
        hold();
      });
    } else if (e is KeyUpEvent) {
      _timer?.cancel();
      if (_down) widget.onTap(); // let go before the hold time: a plain press
      _down = false;
    }
    return KeyEventResult.handled; // (repeats while held: swallowed)
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) =>
      Focus(canRequestFocus: false, skipTraversal: true, onKeyEvent: _onKey, child: widget.child);
}

/// Once a held OK has opened a menu, the rest of that press - the key's repeats while it's still held, and its
/// release - is swallowed here, wherever focus has gone. The menu takes focus on its first item, and Flutter's OK
/// shortcut acts on repeats too: holding OK opened the menu and at once pressed Details in it (tablet, build 55).
/// Goes in MaterialApp.builder: under the app's shortcuts, over every screen and menu.
class HoldOkGuard extends StatelessWidget {
  const HoldOkGuard({super.key, required this.child});
  final Widget child;

  static LogicalKeyboardKey? _held;

  static void swallowRestOf(LogicalKeyboardKey key) => _held = key;

  /// Tests: nothing held (the held key is static, so it would carry from one test to the next).
  @visibleForTesting
  static void debugReset() => _held = null;

  static KeyEventResult _onKey(FocusNode _, KeyEvent e) {
    final k = _held;
    if (k == null || e.logicalKey != k) return KeyEventResult.ignored;
    if (e is KeyDownEvent) {
      _held = null; // a fresh press (the release was missed): not ours to swallow
      return KeyEventResult.ignored;
    }
    if (e is KeyUpEvent) _held = null;
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) =>
      Focus(canRequestFocus: false, skipTraversal: true, onKeyEvent: _onKey, child: child);
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
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: AppSettings.instance.posterLook, // poster size (only: not every setting - #44)
        builder: (context, _) => GridView.builder(
          controller: controller,
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 24),
          gridDelegate: posterGridDelegate(context),
          itemCount: itemCount,
          itemBuilder: itemBuilder,
        ),
      );
}

/// A [PosterGrid] over a [Paged] listing: asks for the next page when the grid gets within ~2 screens of the end
/// (scrolling by touch, or by moving focus down with the remote), with a spinner row while it loads.
class PagedPosterGrid extends StatelessWidget {
  const PagedPosterGrid({super.key, required this.paged, required this.itemBuilder, this.empty = 'Nothing here',
      this.onRefresh});
  final Paged paged;
  final Widget Function(BuildContext context, dynamic item, int index) itemBuilder;
  final String empty;

  /// Pull down to refresh (every grid has it). Default: re-fetch what's loaded, keeping the scroll position.
  final Future<void> Function()? onRefresh;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([paged, AppSettings.instance.posterLook]), // poster size (#44)
      builder: (context, _) {
        if (paged.firstLoad) return const Center(child: CircularProgressIndicator());
        final refresh = onRefresh ?? paged.refresh;
        if (paged.items.isEmpty) {
          // still pullable, so an empty list or an error can be retried by pulling down
          return RefreshIndicator(
            onRefresh: refresh,
            child: LayoutBuilder(builder: (context, box) => ListView(
                  physics: const AlwaysScrollableScrollPhysics(),
                  children: [
                    SizedBox(
                      height: box.maxHeight,
                      child: Center(child: paged.error != null
                          ? Padding(padding: const EdgeInsets.symmetric(horizontal: 24),
                              child: ErrorText(explain(paged.error!).message, paged.error!, centre: true))
                          : Text(empty, style: const TextStyle(color: Color(0xFF9A9A9A)))),
                    ),
                  ],
                )),
          );
        }
        return RefreshIndicator(
          onRefresh: refresh,
          child: CustomScrollView(physics: const AlwaysScrollableScrollPhysics(), slivers: [
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
            sliver: SliverGrid.builder(
              gridDelegate: posterGridDelegate(context),
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
                  ? Center(child: TextButton(onPressed: paged.more,
                      child: Text("Couldn't load more: ${explain(paged.error!).reason}. Retry")))
                  : paged.hasMore
                  ? const Center(child: SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2)))
                  : Center(child: Text('${paged.items.length} shown', style: const TextStyle(color: Color(0xFF6A6A6A), fontSize: 12))),
            ),
          ),
        ]),
        );
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

