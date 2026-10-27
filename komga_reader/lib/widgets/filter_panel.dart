import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../view_filter.dart';
import 'focus_style.dart';
import 'setting_rows.dart';
import '../source.dart';

/// The filter panel (user, 2026-10-08; mockups reports\10-08-filter-mockups.html, section 3): the funnel in a view's
/// top bar opens it, the active filters show as chips under the bar. The filters themselves, the requests and the
/// value lists are the engine's (lib/view_filter.dart, Komga.filteredSeries / filteredBooks, authorNames, ...).

/// A view as the filter panel sees it: series or books, where (the narrowest of series, read list, collection,
/// library - null = all shown libraries), what kind of books it holds, and how many it lists with a filter.
class FilterScope {
  const FilterScope({required this.api, required this.seriesView, this.libraryId, this.collectionId, this.seriesId,
      this.readListId, required this.kind, required this.count});
  final Source api;
  final bool seriesView;
  final String? libraryId, collectionId, seriesId, readListId;
  final Future<ViewKind> kind;

  /// The view's listing with [draft] instead of its filters (its read filter as it is): how many.
  final Future<int> Function(ViewFilter draft) count;

  /// Komga's author names in the view, in [roles], containing [search].
  Future<List<String>> names(List<String> roles, {String? search, int size = 50}) => api.authorNames(roles,
      search: search, libraryId: libraryId, collectionId: collectionId, seriesId: seriesId, readListId: readListId,
      size: size);
}

/// Wider than this: a side panel from the right (the grid stays in view); narrower (a phone): a bottom sheet - as
/// the reader's panels (display_panel.dart).
const filterPanelBreakpoint = 700.0;
const _sideWidth = 400.0;

/// Opens the panel on [value]; the filters to apply (Show), or null (Cancel, Back, a tap outside).
Future<ViewFilter?> showFilterPanel(BuildContext context, FilterScope scope, ViewFilter value) {
  if (MediaQuery.sizeOf(context).width < filterPanelBreakpoint) {
    return showModalBottomSheet<ViewFilter>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (context) => ConstrainedBox(
        constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * 0.85),
        child: FilterPanel(scope: scope, value: value, side: false),
      ),
    );
  }
  return showGeneralDialog<ViewFilter>(
    context: context,
    barrierDismissible: true,
    barrierLabel: 'Close',
    barrierColor: Colors.black38,
    transitionDuration: const Duration(milliseconds: 200),
    pageBuilder: (context, _, __) => Align(
      alignment: Alignment.centerRight,
      child: SizedBox(
        width: _sideWidth,
        height: double.infinity,
        child: Material(
          color: Theme.of(context).colorScheme.surfaceContainer,
          child: SafeArea(left: false, child: FilterPanel(scope: scope, value: value, side: true)),
        ),
      ),
    ),
    transitionBuilder: (context, a, _, child) => SlideTransition(
      position: Tween(begin: const Offset(1, 0), end: Offset.zero)
          .animate(CurvedAnimation(parent: a, curve: Curves.easeOut)),
      child: child,
    ),
  );
}

/// What the view offers in each filter (those with too few values are left out of the panel).
class _Values {
  ViewKind kind = ViewKind.mixed;
  bool writers = false, artists = false; // any at all
  List<String> publishers = const [], genres = const [], statuses = const [];
}

Future<_Values> _loadValues(FilterScope s) async {
  Future<T> safe<T>(Future<T> f, T fallback) => f.catchError((Object _) => fallback);
  final v = _Values();
  final kind = safe(s.kind, ViewKind.mixed);
  final writers = safe(s.names(writerRoles, size: 1), const <String>[]);
  Future<List<String>>? publishers, genres;
  if (s.seriesView) {
    publishers = safe(s.api.publishers(libraryId: s.libraryId, collectionId: s.collectionId), const <String>[]);
    genres = safe(s.api.genres(libraryId: s.libraryId, collectionId: s.collectionId), const <String>[]);
    // all four statuses, always - nothing asked (user, 2026-10-22: Komga has no list of a view's statuses, and the
    // four one-series searches that found them were dropped; one with no series here just finds nothing)
    v.statuses = seriesStatuses;
  }
  v.kind = await kind;
  final artists = v.kind.hasArtists ? safe(s.names(artistRoles, size: 1), const <String>[]) : null;
  v.writers = (await writers).isNotEmpty;
  v.artists = artists != null && (await artists).isNotEmpty;
  if (publishers != null) v.publishers = await publishers;
  if (genres != null) v.genres = await genres;
  return v;
}

/// The panel: a section per filter that applies to the view and has values here, then Show with a live count.
/// Remote: Up / Down row to row (lib/widgets/setting_rows.dart's rows), Left / Right within one, OK presses; Show is
/// the last row; Back closes without applying.
class FilterPanel extends StatefulWidget {
  const FilterPanel({super.key, required this.scope, required this.value, required this.side});
  final FilterScope scope;
  final ViewFilter value;
  final bool side;

  @override
  State<FilterPanel> createState() => _FilterPanelState();
}

class _FilterPanelState extends State<FilterPanel> {
  late ViewFilter _draft = widget.value;
  _Values? _values;
  int? _count;
  int _asked = 0; // the count asked for last: an older answer is dropped
  Timer? _countSoon;
  final _expanded = <FilterField>{};

  FilterScope get _scope => widget.scope;

  @override
  void initState() {
    super.initState();
    _loadValues(_scope).then((v) { if (mounted) setState(() => _values = v); });
    _countNow();
  }

  @override
  void dispose() {
    _countSoon?.cancel();
    super.dispose();
  }

  /// The draft changed: the count follows once the changes stop for a moment.
  void _set(ViewFilter f) {
    setState(() {
      _draft = f;
      _count = null;
    });
    _countSoon?.cancel();
    _countSoon = Timer(const Duration(milliseconds: 300), _countNow);
  }

  Future<void> _countNow() async {
    final asked = ++_asked;
    final draft = _draft;
    int? n;
    try {
      n = await _scope.count(draft);
    } catch (_) {
      n = null; // (the Show button goes without a number)
    }
    if (mounted && asked == _asked) setState(() => _count = n);
  }

  void _show() => Navigator.of(context).pop(_draft);
  void _cancel() => Navigator.of(context).pop();

  @override
  Widget build(BuildContext context) {
    final v = _values;
    final sections = v == null ? const <Widget>[] : _sections(v);
    final noun = _scope.seriesView ? 'series' : (_count == 1 ? 'book' : 'books');
    final header = Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 4, 0),
      child: Row(children: [
        const Expanded(child: Text('Filter', style: TextStyle(fontSize: 17, fontWeight: FontWeight.w500))),
        TextButton(key: const ValueKey('filter.clearAll'),
            onPressed: _draft.isEmpty ? null : () => _set(ViewFilter.none), child: const Text('Clear all')),
        IconButton(key: const ValueKey('filter.cancel'), tooltip: 'Cancel', icon: const Icon(Icons.close),
            onPressed: _cancel),
      ]),
    );
    final body = v == null
        ? const Padding(padding: EdgeInsets.all(32), child: Center(child: CircularProgressIndicator()))
        : sections.isEmpty
            ? const Padding(padding: EdgeInsets.all(24), child: Text('Nothing to filter by in this view.',
                style: TextStyle(color: hintColour)))
            : Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: sections);
    final footer = RowNav(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
        child: FilledButton(
          key: const ValueKey('filter.show'),
          autofocus: v != null && sections.isEmpty,
          onPressed: _show,
          child: Text(_count == null ? 'Show $noun' : 'Show $_count $noun'),
        ),
      ),
    );
    return Column(mainAxisSize: widget.side ? MainAxisSize.max : MainAxisSize.min, children: [
      header,
      Flexible(
        fit: widget.side ? FlexFit.tight : FlexFit.loose,
        child: ListView(shrinkWrap: !widget.side, padding: const EdgeInsets.fromLTRB(12, 8, 12, 4), children: [body]),
      ),
      footer,
    ]);
  }

  /// The sections that apply here and have something to choose from; the first one's first control has the focus.
  List<Widget> _sections(_Values v) {
    final d = _draft;
    final seriesView = _scope.seriesView;
    final out = <Widget>[];
    bool first() => out.isEmpty;
    if (v.writers || d.writers.isNotEmpty) {
      out.add(_namesSection(FilterField.writer, v.kind.writerLabel, writerRoles, d.writers,
          (l) => _set(d.copyWith(writers: l)), autofocus: first()));
    }
    if (v.kind.hasArtists && (v.artists || d.artists.isNotEmpty)) {
      out.add(_namesSection(FilterField.artist, 'Artist', artistRoles, d.artists,
          (l) => _set(d.copyWith(artists: l)), autofocus: first()));
    }
    out.add(_yearsSection(autofocus: first())); // always: any year can be asked for
    if (FilterField.publisher.appliesTo(seriesView: seriesView) &&
        (v.publishers.length >= 2 || d.publishers.isNotEmpty)) {
      out.add(_checkSection(FilterField.publisher, 'Publisher', v.publishers, d.publishers,
          (l) => _set(d.copyWith(publishers: l)), autofocus: first()));
    }
    if (FilterField.status.appliesTo(seriesView: seriesView) && (v.statuses.length >= 2 || d.statuses.isNotEmpty)) {
      out.add(_statusSection(v.statuses, autofocus: first()));
    }
    if (FilterField.genre.appliesTo(seriesView: seriesView) && (v.genres.length >= 2 || d.genres.isNotEmpty)) {
      out.add(_checkSection(FilterField.genre, 'Genre', v.genres, d.genres, (l) => _set(d.copyWith(genres: l)),
          autofocus: first()));
    }
    return out;
  }

  /// Writer / Artist: the chosen names as removable chips, and Add (a type-to-search picker of Komga's names).
  Widget _namesSection(FilterField field, String label, List<String> roles, List<String> chosen,
          ValueChanged<List<String>> onChanged, {required bool autofocus}) =>
      SettingsGroup(
        key: ValueKey('filter.section.${field.name}'),
        title: label,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
            child: Wrap(spacing: 6, runSpacing: 6, crossAxisAlignment: WrapCrossAlignment.center, children: [
              for (final n in chosen)
                InputChip(
                  key: ValueKey('filter.name.$n'),
                  label: Text(n),
                  // OK on a chosen name (the remote) removes it, as its cross does
                  onPressed: () => onChanged([...chosen]..remove(n)),
                  onDeleted: () => onChanged([...chosen]..remove(n)),
                ),
              ActionChip(
                key: ValueKey('filter.add.${field.name}'),
                autofocus: autofocus,
                avatar: const Icon(Icons.add, size: 18),
                label: const Text('Add'),
                onPressed: () async {
                  final picked = await showDialog<List<String>>(
                    context: context,
                    builder: (_) => NamePicker(title: label, chosen: chosen,
                        search: (q) => _scope.names(roles, search: q, size: NamePicker.limit + 1)),
                  );
                  if (picked != null) onChanged(picked);
                },
              ),
            ]),
          ),
        ],
      );

  /// Release years: from / to, each Any or a year from this year back to [firstYear] - the same list in every view,
  /// whatever its books' dates (user, 2026-10-08: "just let me pick"). Picking From sets To to the same year, so one
  /// pick is that year only; To can then be moved later, or to Any for "and later".
  Widget _yearsSection({required bool autofocus}) {
    final d = _draft;
    final all = [for (var y = DateTime.now().year; y >= firstYear; y--) y];
    // a saved year outside the list still shows as itself
    List<int> range(int? keep) =>
        ({...all, if (keep != null) keep}.toList()..sort()).reversed.toList();
    DropdownButton<int?> pick(String key, int? value, int? keep, ValueChanged<int?> onChanged, {bool focus = false}) =>
        DropdownButton<int?>(
          key: ValueKey(key),
          autofocus: focus,
          value: value,
          isExpanded: true,
          items: [
            const DropdownMenuItem<int?>(value: null, child: Text('Any')),
            for (final y in range(keep)) DropdownMenuItem<int?>(value: y, child: Text('$y')),
          ],
          onChanged: onChanged,
        );
    return SettingsGroup(
      key: const ValueKey('filter.section.years'),
      title: 'Release years',
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(14, 4, 14, 4),
          child: Row(children: [
            const Text('From'),
            const SizedBox(width: 10),
            Expanded(child: pick('filter.from', d.fromYear, d.fromYear, (y) {
              final to = d.toYear;
              // From fills To: one pick = that year; a To already at or after it stays (a range)
              _set(d.copyWith(years: (y, y != null && (to == null || to < y) ? y : to)));
            }, focus: autofocus)),
            const SizedBox(width: 16),
            const Text('to'),
            const SizedBox(width: 10),
            Expanded(child: pick('filter.to', d.toYear, d.toYear, (y) {
              final from = d.fromYear;
              _set(d.copyWith(years: (y != null && from != null && from > y ? y : from, y)));
            })),
          ]),
        ),
      ],
    );
  }

  /// Publisher / Genre: a checkbox per value - the chosen ones and the first few, "N more..." for the rest.
  Widget _checkSection(FilterField field, String label, List<String> values, List<String> chosen,
      ValueChanged<List<String>> onChanged, {required bool autofocus}) {
    const shown = 5;
    final lower = {for (final c in chosen) c.toLowerCase()};
    final all = [...chosen, for (final v in values) if (!lower.contains(v.toLowerCase())) v];
    final open = _expanded.contains(field) || all.length <= shown + 1;
    final list = open ? all : all.take(chosen.length > shown ? chosen.length : shown).toList();
    return SettingsGroup(
      key: ValueKey('filter.section.${field.name}'),
      title: label,
      children: [
        for (var i = 0; i < list.length; i++)
          CheckboxListTile(
            key: ValueKey('filter.${field.name}.${list[i]}'),
            autofocus: autofocus && i == 0,
            dense: true,
            controlAffinity: ListTileControlAffinity.leading,
            title: Text(list[i]),
            value: lower.contains(list[i].toLowerCase()),
            onChanged: (on) => onChanged(on == true
                ? [...chosen, list[i]]
                : [for (final c in chosen) if (c.toLowerCase() != list[i].toLowerCase()) c]),
          ),
        if (!open)
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton(
              key: ValueKey('filter.more.${field.name}'),
              onPressed: () => setState(() => _expanded.add(field)),
              child: Text('${all.length - list.length} more…'),
            ),
          ),
      ],
    );
  }

  /// Status: a chip each (those in the view, and any chosen).
  Widget _statusSection(List<String> statuses, {required bool autofocus}) {
    final d = _draft;
    final offered = [for (final s in seriesStatuses) if (statuses.contains(s) || d.statuses.contains(s)) s];
    return SettingsGroup(
      key: const ValueKey('filter.section.status'),
      title: 'Status',
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
          child: Wrap(spacing: 6, runSpacing: 6, children: [
            for (var i = 0; i < offered.length; i++)
              FilterChip(
                key: ValueKey('filter.status.${offered[i]}'),
                autofocus: autofocus && i == 0,
                label: Text(ViewFilter.statusLabel(offered[i])),
                selected: d.statuses.contains(offered[i]),
                onSelected: (on) => _set(d.copyWith(statuses: on
                    ? [...d.statuses, offered[i]]
                    : [for (final s in d.statuses) if (s != offered[i]) s])),
              ),
          ]),
        ),
      ],
    );
  }
}

/// The oldest year the release-year lists offer (the eBooks reach back to 1818).
const firstYear = 1800;

/// Type to search Komga's names (debounced), tick several; Done gives back the chosen ones (Cancel / Back: null).
class NamePicker extends StatefulWidget {
  const NamePicker({super.key, required this.title, required this.chosen, required this.search});
  final String title;
  final List<String> chosen;
  final Future<List<String>> Function(String query) search;

  /// The most names listed; [search] is asked for one more, so a list that was cut can say so (with nothing typed,
  /// a big library's first 50 used to look like all of them - tablet, build 101).
  static const limit = 50;

  @override
  State<NamePicker> createState() => _NamePickerState();
}

class _NamePickerState extends State<NamePicker> {
  late final List<String> _chosen = [...widget.chosen];
  List<String>? _found;
  bool _more = false; // the search found more than [NamePicker.limit]
  int _asked = 0;
  Timer? _soon;
  final _query = TextEditingController();

  @override
  void initState() {
    super.initState();
    _searchNow();
  }

  @override
  void dispose() {
    _soon?.cancel();
    _query.dispose();
    super.dispose();
  }

  void _typed(String _) {
    _soon?.cancel();
    _soon = Timer(const Duration(milliseconds: 300), _searchNow);
  }

  Future<void> _searchNow() async {
    final asked = ++_asked;
    List<String> found;
    try {
      found = await widget.search(_query.text.trim());
    } catch (_) {
      found = const [];
    }
    if (mounted && asked == _asked) {
      setState(() {
        _more = found.length > NamePicker.limit;
        _found = found.take(NamePicker.limit).toList();
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final lower = {for (final c in _chosen) c.toLowerCase()};
    final names = [..._chosen, for (final n in _found ?? const <String>[]) if (!lower.contains(n.toLowerCase())) n];
    return AlertDialog(
      title: Text('Add ${widget.title.toLowerCase()}'),
      contentPadding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
      content: SizedBox(
        width: 360,
        height: 420,
        child: Column(children: [
          // Down from the search field goes to the names (a text field keeps the arrows otherwise)
          Focus(
            canRequestFocus: false,
            skipTraversal: true,
            onKeyEvent: (node, e) {
              if (e is KeyDownEvent && e.logicalKey == LogicalKeyboardKey.arrowDown) {
                FocusManager.instance.primaryFocus?.nextFocus();
                return KeyEventResult.handled;
              }
              return KeyEventResult.ignored;
            },
            child: TextField(
              key: const ValueKey('filter.search'),
              controller: _query,
              autofocus: true,
              decoration: const InputDecoration(prefixIcon: Icon(Icons.search), hintText: 'Search'),
              onChanged: _typed,
              onSubmitted: (_) => _searchNow(),
            ),
          ),
          const SizedBox(height: 8),
          Expanded(
            child: _found == null && names.isEmpty
                ? const Center(child: CircularProgressIndicator())
                : ListView(children: [
                    for (final n in names)
                      CheckboxListTile(
                        key: ValueKey('filter.pick.$n'),
                        dense: true,
                        controlAffinity: ListTileControlAffinity.leading,
                        title: Text(n),
                        value: lower.contains(n.toLowerCase()),
                        onChanged: (on) => setState(() => on == true
                            ? _chosen.add(n)
                            : _chosen.removeWhere((c) => c.toLowerCase() == n.toLowerCase())),
                      ),
                    if (_more)
                      Padding(
                        key: const ValueKey('filter.pickMore'),
                        padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
                        child: Text(
                          'Only the first ${NamePicker.limit} are listed - type a name to find the others.',
                          style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant),
                        ),
                      ),
                  ]),
          ),
        ]),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Cancel')),
        FilledButton(key: const ValueKey('filter.pickDone'), onPressed: () => Navigator.of(context).pop(_chosen),
            child: const Text('Done')),
      ],
    );
  }
}

// ---- in the view: the funnel, the chips -------------------------------------------------------------------------

/// The funnel in the top bar: filled with the accent while filters are on (user, 2026-10-08: "when there are active
/// filters, the filter button should be highlighted" - the faint tint the eye has wasn't enough), a small badge
/// counting them.
class FilterButton extends StatelessWidget {
  const FilterButton({super.key, required this.active, required this.onPressed});
  final int active;
  final VoidCallback onPressed;
  @override
  Widget build(BuildContext context) {
    final on = active > 0;
    final scheme = Theme.of(context).colorScheme;
    // filled while filters are on - except under the remote's focus, whose outline (the accent too) would vanish
    // into the fill: the theme's focus look shows instead (tablet, build 101)
    WidgetStateProperty<Color?> unlessFocused(Color c) =>
        WidgetStateProperty.resolveWith((s) => remoteFocused(s) ? null : c);
    return IconButton(
      tooltip: on ? 'Filter ($active on)' : 'Filter',
      isSelected: on,
      style: on
          ? ButtonStyle(
              backgroundColor: unlessFocused(scheme.primary),
              foregroundColor: unlessFocused(scheme.onPrimary),
              iconColor: unlessFocused(scheme.onPrimary))
          : null,
      icon: Badge(
        key: const ValueKey('filter.badge'),
        isLabelVisible: on,
        label: Text('$active'),
        child: const Icon(Icons.filter_alt),
      ),
      onPressed: onPressed,
    );
  }
}

/// A filter's fields that are set, each with its chip text ([ViewFilter.summary]'s, one by one).
List<(FilterField, String)> filterParts(ViewFilter f, ViewKind kind) {
  String text(ViewFilter one) => one.summary(writerLabel: kind.writerLabel).single;
  return [
    if (f.writers.isNotEmpty) (FilterField.writer, text(ViewFilter(writers: f.writers))),
    if (f.artists.isNotEmpty) (FilterField.artist, text(ViewFilter(artists: f.artists))),
    if (f.fromYear != null || f.toYear != null)
      (FilterField.years, text(ViewFilter(fromYear: f.fromYear, toYear: f.toYear))),
    if (f.publishers.isNotEmpty) (FilterField.publisher, text(ViewFilter(publishers: f.publishers))),
    if (f.genres.isNotEmpty) (FilterField.genre, text(ViewFilter(genres: f.genres))),
    if (f.statuses.isNotEmpty) (FilterField.status, text(ViewFilter(statuses: f.statuses))),
  ];
}

/// [f] without one of its filters.
ViewFilter withoutField(ViewFilter f, FilterField field) => switch (field) {
      FilterField.writer => f.copyWith(writers: const []),
      FilterField.artist => f.copyWith(artists: const []),
      FilterField.years => f.copyWith(years: (null, null)),
      FilterField.publisher => f.copyWith(publishers: const []),
      FilterField.genre => f.copyWith(genres: const []),
      FilterField.status => f.copyWith(statuses: const []),
    };

/// The active filters under the top bar: a chip each (OK or its cross removes it), and Clear for all of them.
class ActiveFilters extends StatelessWidget implements PreferredSizeWidget {
  const ActiveFilters({super.key, required this.filter, required this.kind, required this.onChanged});
  final ViewFilter filter; // the filters that apply to the view
  final ViewKind kind;
  final ValueChanged<ViewFilter> onChanged;

  static const height = 44.0;
  @override
  Size get preferredSize => const Size.fromHeight(height);

  @override
  Widget build(BuildContext context) => SizedBox(
        height: height,
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Row(children: [
            for (final (field, text) in filterParts(filter, kind))
              Padding(
                padding: const EdgeInsets.only(right: 8, bottom: 6),
                child: InputChip(
                  key: ValueKey('filter.chip.${field.name}'),
                  label: Text(text),
                  onPressed: () => onChanged(withoutField(filter, field)),
                  onDeleted: () => onChanged(withoutField(filter, field)),
                ),
              ),
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: ActionChip(
                key: const ValueKey('filter.chip.clear'),
                avatar: const Icon(Icons.filter_alt_off, size: 18),
                label: const Text('Clear'),
                onPressed: () => onChanged(ViewFilter.none),
              ),
            ),
          ]),
        ),
      );
}

/// A browsing view's filters (library Series / Books, a series, a collection, a read list): the filters, the kind of
/// books it holds (asked once, when first needed), the funnel and the chips. The view says what it lists and how to
/// apply a change (set, save with its prefs, list again).
mixin ViewFilters<T extends StatefulWidget> on State<T> {
  /// The view's filters as saved (a book view keeps the series filters it can't use; [activeFilters] leaves them out).
  ViewFilter filters = ViewFilter.none;

  /// The view's books, as far as known (Writer / Author, Artist).
  ViewKind filterKind = ViewKind.mixed;
  Future<ViewKind>? _kind;

  /// Whether the view lists series (the series filters apply).
  bool get filtersSeriesView;

  /// What the view's books are: asked when the panel opens or chips are shown.
  Future<ViewKind> askFilterKind();

  /// The panel's view of this view; [kind] is [askFilterKind]'s answer.
  FilterScope filterScope(Future<ViewKind> kind);

  /// Applies new filters: set them, save them with the view, list again.
  void applyFilters(ViewFilter f);

  ViewFilter get activeFilters => filters.forView(seriesView: filtersSeriesView);

  Future<ViewKind> _learnKind() => _kind ??= askFilterKind().then((k) {
        if (mounted && k != filterKind) setState(() => filterKind = k);
        return k;
      }, onError: (Object _) {
        _kind = null;
        return ViewKind.mixed;
      });

  /// The view now holds other books (another library): their kind is asked again.
  void forgetFilterKind() {
    _kind = null;
    filterKind = ViewKind.mixed;
  }

  Future<void> openFilterPanel() async {
    final r = await showFilterPanel(context, filterScope(_learnKind()), filters);
    if (r != null && mounted && r != filters) applyFilters(r);
  }

  /// The funnel for the view bar.
  Widget filterButton() => FilterButton(active: filterParts(activeFilters, filterKind).length, onPressed: openFilterPanel);

  /// The chips row under the top bar, or null while no filter applies.
  ActiveFilters? filterChips() {
    final f = activeFilters;
    if (f.isEmpty) return null;
    if (f.writers.isNotEmpty) _learnKind(); // (the chip says Writer or Author)
    return ActiveFilters(filter: f, kind: filterKind, onChanged: (n) => applyFilters(_merge(n)));
  }

  /// A change made on [activeFilters] applied to the whole saved filter: Clear clears it all.
  ViewFilter _merge(ViewFilter active) => active.isEmpty
      ? ViewFilter.none
      : filters.copyWith(writers: active.writers, artists: active.artists, years: (active.fromYear, active.toYear),
          publishers: filtersSeriesView ? active.publishers : null, genres: filtersSeriesView ? active.genres : null,
          statuses: filtersSeriesView ? active.statuses : null);

  /// The filters' words for a pin's name.
  List<String> filterWords() => [for (final (_, t) in filterParts(activeFilters, filterKind)) t];
}
