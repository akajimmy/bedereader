import 'package:flutter/material.dart';

import '../api.dart';
import '../paged.dart';
import '../pins.dart';
import '../settings.dart';
import '../view_sort.dart';
import 'fullscreen_exit.dart';
import 'poster.dart';
import 'selection.dart';

/// The top-bar actions of a browsing view (library, series, collection, read list), always in one order (user,
/// 2026-10-08, option B):
///   Count · Eye · Filter · Sort · Select · Size · Pin · Search · Refresh · [view actions ⋮] · Full screen exit
/// A button that doesn't apply to a view is left out (null), never greyed. Each button is keyed `bar.<name>`.
/// A phone-width screen (under 600 wide): the top bars fold their rarer buttons into a menu - ten buttons don't fit
/// a 402-wide bar (iPhone; the phone-width round, 2026-11-13).
bool narrowScreen(BuildContext context) => MediaQuery.sizeOf(context).width < 600;

/// On a [narrowScreen], [viewBarActions] keeps Count · Eye · Filter · Sort and puts the rest in one ⋮ menu, keyed
/// `bar.menu`: Select, Pin, Search, Refresh, the view's actions, then the poster sizes.
List<Widget> viewBarActions({
  required BuildContext context,
  required Paged paged,
  required ReadFilter filter,
  required ValueChanged<ReadFilter> onFilter,
  Widget? filters, // the funnel (filter panel) - not built yet
  Widget? sort,
  Selection? select,
  required Pin pin,
  VoidCallback? onSearch,
  required VoidCallback onRefresh,
  VoidCallback? onMore,
  String moreTooltip = 'Actions',
}) {
  Widget k(String name, Widget w) => KeyedSubtree(key: ValueKey('bar.$name'), child: w);
  if (narrowScreen(context)) {
    return [
      k('count', Center(child: CountBadge(paged: paged))),
      k('eye', ReadFilterButton(value: filter, onChanged: onFilter)),
      if (filters != null) k('filter', filters),
      if (sort != null) k('sort', sort),
      k('menu', _NarrowMenu(select: select, pin: pin, onSearch: onSearch, onRefresh: onRefresh, onMore: onMore,
          moreLabel: moreTooltip)),
      k('fullscreen', const FullscreenExit()),
    ];
  }
  return [
    k('count', Center(child: CountBadge(paged: paged))),
    k('eye', ReadFilterButton(value: filter, onChanged: onFilter)),
    if (filters != null) k('filter', filters),
    if (sort != null) k('sort', sort),
    if (select != null) k('select', SelectButton(selection: select)),
    k('size', const PosterSizeButton()),
    k('pin', PinButton(current: pin)),
    if (onSearch != null) k('search', IconButton(tooltip: 'Search', icon: const Icon(Icons.search), onPressed: onSearch)),
    k('refresh', IconButton(tooltip: 'Refresh', icon: const Icon(Icons.refresh), onPressed: onRefresh)),
    if (onMore != null) k('more', IconButton(tooltip: moreTooltip, icon: const Icon(Icons.more_vert), onPressed: onMore)),
    k('fullscreen', const FullscreenExit()),
  ];
}

/// The ⋮ of a [narrowScreen]'s browsing bar: what the wide bar has as its own buttons.
class _NarrowMenu extends StatelessWidget {
  const _NarrowMenu({required this.select, required this.pin, required this.onSearch, required this.onRefresh,
      required this.onMore, required this.moreLabel});
  final Selection? select;
  final Pin pin;
  final VoidCallback? onSearch, onMore;
  final VoidCallback onRefresh;
  final String moreLabel;

  @override
  Widget build(BuildContext context) {
    final s = AppSettings.instance;
    return PopupMenuButton<String>(
      tooltip: 'More',
      icon: const Icon(Icons.more_vert),
      onSelected: (v) {
        final existing = Pins.instance.find(pin);
        switch (v) {
          case 'select': select?.start();
          case 'pin': showPinDialog(context, existing ?? pin, pinned: existing != null);
          case 'search': onSearch?.call();
          case 'refresh': onRefresh();
          case 'more': onMore?.call();
          default:
            final size = PosterSize.values.firstWhere((p) => 'size.${p.name}' == v);
            s.setDisplay(s.display.copyWith(posterSize: size));
        }
      },
      itemBuilder: (_) {
        final existing = Pins.instance.find(pin);
        PopupMenuItem<String> item(String value, IconData icon, String label) => PopupMenuItem(
            key: ValueKey('menu.$value'), value: value,
            child: Row(children: [Icon(icon, size: 20), const SizedBox(width: 12), Flexible(child: Text(label))]));
        return [
          if (select != null) item('select', Icons.checklist, 'Select multiple'),
          item('pin', existing == null ? Icons.push_pin_outlined : Icons.push_pin,
              existing == null ? 'Pin to Home' : 'Pinned as "${existing.name}"'),
          if (onSearch != null) item('search', Icons.search, 'Search'),
          item('refresh', Icons.refresh, 'Refresh'),
          if (onMore != null) item('more', Icons.more_horiz, '$moreLabel…'),
          const PopupMenuDivider(),
          for (final p in PosterSize.values)
            CheckedPopupMenuItem(key: ValueKey('menu.size.${p.name}'), value: 'size.${p.name}',
                checked: p == s.display.posterSize, child: Text('${p.label} posters')),
        ];
      },
    );
  }
}

/// Sort, as a menu (every browsing view): pick a field - it starts in its natural direction - then flip the
/// direction below the divider.
class SortMenuButton extends StatelessWidget {
  const SortMenuButton({super.key, required this.fields, required this.value, required this.onChanged});
  final List<SortField> fields;
  final ViewSort value;
  final ValueChanged<ViewSort> onChanged;

  @override
  Widget build(BuildContext context) {
    final field = fields.firstWhere((f) => f.key == value.key, orElse: () => fields.first);
    String dirLabel(bool desc) => desc ? field.descLabel : field.ascLabel;
    return PopupMenuButton<String>(
      tooltip: 'Sort: ${field.label}, ${dirLabel(value.desc)}',
      icon: Row(mainAxisSize: MainAxisSize.min, children: [
        const Icon(Icons.sort),
        Icon(value.desc ? Icons.arrow_downward : Icons.arrow_upward, size: 14),
      ]),
      onSelected: (s) {
        final v = s.substring(2);
        if (s.startsWith('f:') && v != value.key) {
          onChanged(ViewSort(v, fields.firstWhere((f) => f.key == v).desc));
        } else if (s.startsWith('d:')) {
          onChanged(ViewSort(value.key, v == 'desc'));
        }
      },
      itemBuilder: (_) => [
        for (final f in fields)
          CheckedPopupMenuItem(key: ValueKey('sort.${f.key}'), value: 'f:${f.key}', checked: f.key == value.key,
              child: Text(f.label)),
        const PopupMenuDivider(),
        for (final d in const [false, true])
          CheckedPopupMenuItem(key: ValueKey(d ? 'sort.desc' : 'sort.asc'), value: d ? 'd:desc' : 'd:asc',
              checked: value.desc == d, child: Text(dirLabel(d))),
      ],
    );
  }
}

/// The eye in the app bar, three-way (user, 2026-10-07): each tap goes All -> Hide read -> Hide unread -> All.
/// In-progress books count as unread.
class ReadFilterButton extends StatelessWidget {
  const ReadFilterButton({super.key, required this.value, required this.onChanged});
  final ReadFilter value;
  final ValueChanged<ReadFilter> onChanged;
  @override
  Widget build(BuildContext context) {
    // icon only (user's call): accent-tinted while something is hidden - a crossed-out eye for read hidden, a tick for
    // only read; the state and the next one are the tooltip
    final on = value != ReadFilter.all;
    final accent = Theme.of(context).colorScheme.primary;
    return IconButton(
      tooltip: switch (value) {
        ReadFilter.all => 'Showing all (hide read)',
        ReadFilter.hideRead => 'Read hidden (hide unread)',
        ReadFilter.hideUnread => 'Unread hidden (show all)',
      },
      isSelected: on,
      color: on ? accent : null,
      style: on ? IconButton.styleFrom(backgroundColor: accent.withValues(alpha: 0.16)) : null,
      icon: Icon(switch (value) {
        ReadFilter.all => Icons.visibility,
        ReadFilter.hideRead => Icons.visibility_off,
        ReadFilter.hideUnread => Icons.task_alt,
      }),
      onPressed: () => onChanged(ReadFilter.values[(value.index + 1) % ReadFilter.values.length]),
    );
  }
}
