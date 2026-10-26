import 'package:flutter/widgets.dart';

import '../api.dart';
import '../paged.dart';
import '../pins.dart';
import '../view_filter.dart';
import '../view_prefs.dart';
import '../view_sort.dart';
import 'filter_panel.dart';

/// A list screen's view - the read filter, the sort and the filter panel's filters - restored as the screen opens
/// (from the pin it was opened from, else as it was left on this device, under [viewKey]) and remembered as it
/// changes, the list starting over each time. One for the series, collection and read list screens (user,
/// 2026-10-22: "knock out that cleanup now" - each had its own copy of all this).
mixin RememberedView<T extends StatefulWidget> on State<T>, ViewFilters<T> {
  ReadFilter readFilter = ReadFilter.all;
  late ViewSort sort = ViewSort.first(sorts); // (the list's own order unless changed)

  /// Where this list's view is kept ("view.series.{id}", ...).
  String get viewKey;

  /// The orders this list offers, its default first.
  List<SortField> get sorts;

  /// The Home pin it was opened from (its view, not the remembered one), if any.
  Pin? get pin;

  /// The list itself: started over when the view changes.
  Paged get paged;

  /// The view restored, then the list's first page - from initState.
  void openView() => _restore().then((_) {
        if (!mounted) return;
        setState(() {});
        paged.more();
      });

  Future<void> _restore() async {
    final p = pin;
    if (p != null) {
      readFilter = p.readFilter;
      sort = ViewSort.fromPin(sorts, p.sort); // (no sort on the pin: the list's own order)
      filters = p.filters;
    } else {
      final v = await ViewPrefs.load(viewKey);
      readFilter = ReadFilterApi.fromName(v['filter']);
      sort = ViewSort.of(sorts, v['sort'], v['desc']);
      filters = ViewPrefs.filtersOf(v);
    }
  }

  void saveView() => ViewPrefs.save(viewKey,
      ViewPrefs.withFilters({'filter': readFilter.name, 'sort': sort.key, 'desc': sort.desc}, filters));

  void setReadFilter(ReadFilter f) => _changed(() => readFilter = f);

  void setViewSort(ViewSort s) => _changed(() => sort = s);

  @override
  void applyFilters(ViewFilter f) => _changed(() => filters = f);

  void _changed(VoidCallback change) {
    setState(change);
    saveView();
    paged.reset();
  }
}
