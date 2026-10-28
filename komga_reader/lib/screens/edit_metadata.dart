import 'package:flutter/material.dart';

import '../book_source.dart';
import '../errors.dart';
import '../local/book_names.dart' show isLocalId;
import '../widgets/error_text.dart';

// Metadata editing (user, 2026-10-27; reports\10-27-metadata-plan.md): a book's title, number, sort number, release
// date, series, summary, credits and tags; a series' title, sort title, reading direction, status, publisher, summary,
// genres and tags. Saved through the book's source - Komga's own metadata (admin accounts), or a local or network
// library's files.

/// The sort number a number gives: its leading figures ("12", "12.5", "3a" -> 3); null for none ("Annual").
num? numberSortOf(String number) {
  final m = RegExp(r'^\s*(\d+(?:\.\d+)?)').firstMatch(number);
  return m == null ? null : num.parse(m.group(1)!);
}

/// A date as Komga writes it ('2024-03-01').
String isoDate(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

/// The credit roles edited, by Komga's names, with the words shown for them (others a book has - editor, translator -
/// are kept as they are).
const editedRoles = {
  'writer': 'Writers', 'penciller': 'Pencillers', 'inker': 'Inkers', 'colorist': 'Colorists', 'letterer': 'Letterers',
  'cover': 'Cover artists',
};

/// Names typed separated by commas: trimmed, empty ones left out, each once.
List<String> namesIn(String text) => {for (final n in text.split(',')) if (n.trim().isNotEmpty) n.trim()}.toList();

/// A list of names as text to edit.
String namesText(Object? list) => [for (final n in (list as List?) ?? const []) '$n'].join(', ');

/// A book's credits of [role] as text to edit.
String creditsText(Map book, String role) => namesText([
      for (final a in ((book['metadata'] as Map?)?['authors'] as List?) ?? const [])
        if ((a as Map)['role'] == role) a['name'],
    ]);

bool _sameNames(Iterable<String> a, Iterable<String> b) {
  final x = [...a]..sort(), y = [...b]..sort();
  return x.length == y.length && Iterable.generate(x.length).every((i) => x[i] == y[i]);
}

/// The changes made to a book's fields, by Komga's names - only what differs from [book] ([series]: the series name
/// typed, local and network books only); [sort]: the sort number in its field; [credits]: names typed for each of
/// [editedRoles]; [tags]: typed separated by commas. Null: not shown.
Map<String, Object?> bookChanges(Map book, {required String title, required String number, required DateTime? date,
    String? series, String? sort, String? summary, Map<String, String>? credits, String? tags}) {
  final m = (book['metadata'] as Map?) ?? const {};
  final out = <String, Object?>{};
  if (title.trim() != '${m['title'] ?? ''}') out['title'] = title.trim();
  if (number.trim() != '${m['number'] ?? ''}') out['number'] = number.trim();
  if (sort != null) {
    final n = num.tryParse(sort.trim());
    if (n != null && n != m['numberSort']) out['numberSort'] = n;
  }
  if (summary != null && summary.trim() != '${m['summary'] ?? ''}'.trim()) out['summary'] = summary.trim();
  if (credits != null) {
    final was = [for (final a in (m['authors'] as List?) ?? const []) ((a as Map)['name'] as String, a['role'] as String)];
    final now = [
      for (final MapEntry(key: role, value: text) in credits.entries)
        for (final n in namesIn(text)) (n, role),
      for (final a in was) if (!credits.containsKey(a.$2)) a,
    ];
    if (!_sameNames([for (final (n, r) in was) '$r|$n'], [for (final (n, r) in now) '$r|$n'])) {
      out['authors'] = [for (final (n, r) in now) {'name': n, 'role': r}];
    }
  }
  if (tags != null && !_sameNames(namesIn(tags), [for (final t in (m['tags'] as List?) ?? const []) '$t'])) {
    out['tags'] = namesIn(tags);
  }
  final was = m['releaseDate'] as String?;
  final now = date == null ? null : isoDate(date);
  if (now != was) out['releaseDate'] = now;
  if (series != null && series.trim().isNotEmpty &&
      series.trim().toLowerCase() != '${book['seriesTitle'] ?? ''}'.trim().toLowerCase()) {
    out['seriesName'] = series.trim();
  }
  return out;
}

/// Whether a book's or series' ([id]) metadata can be edited (Edit offered): asked of its source - Komga's answer is
/// kept after the first ask, so a menu waits at most a moment, once.
Future<bool> canEditIn(BookSource api, String id) => api
    .canEditMetadata(id)
    .timeout(const Duration(seconds: 2), onTimeout: () => false)
    .catchError((Object _) => false);

/// Edits a book's metadata; true once something was saved.
Future<bool> editBook(BuildContext context, BookSource api, Map book) async =>
    await showDialog<bool>(context: context, builder: (_) => _BookEditor(api: api, book: book)) ?? false;

/// Edits a series' metadata; true once something was saved.
Future<bool> editSeries(BuildContext context, BookSource api, Map series) async =>
    await showDialog<bool>(context: context, builder: (_) => _SeriesEditor(api: api, series: series)) ?? false;

class _BookEditor extends StatefulWidget {
  const _BookEditor({required this.api, required this.book});
  final BookSource api;
  final Map book;
  @override
  State<_BookEditor> createState() => _BookEditorState();
}

class _BookEditorState extends State<_BookEditor> {
  Map get _m => (widget.book['metadata'] as Map?) ?? const {};
  late final _title = TextEditingController(text: '${_m['title'] ?? ''}');
  late final _number = TextEditingController(text: '${_m['number'] ?? ''}');
  late final _sort = TextEditingController(text: _sortText(_m['numberSort']));
  bool _sortTyped = false; // the sort number changed by hand: it no longer follows the number
  late final _summary = TextEditingController(text: '${_m['summary'] ?? ''}');
  late final _credits = {for (final r in editedRoles.keys) r: TextEditingController(text: creditsText(widget.book, r))};
  late final _tags = TextEditingController(text: namesText(_m['tags']));
  late DateTime? _date = DateTime.tryParse('${_m['releaseDate'] ?? ''}');
  late final bool _local = isLocalId(widget.book['id'] as String?);
  String _series = '';
  List<String> _seriesNames = const [];
  bool _saving = false;

  static String _sortText(Object? n) => n is num ? (n == n.roundToDouble() ? '${n.toInt()}' : '$n') : '';

  @override
  void initState() {
    super.initState();
    _series = '${widget.book['seriesTitle'] ?? ''}';
    if (_local) _loadSeries();
    // the sort number follows the number as it's typed, until it's changed by hand
    _number.addListener(() {
      if (_sortTyped) return;
      final n = numberSortOf(_number.text);
      if (n != null) _sort.text = _sortText(n);
    });
  }

  /// The library's series, to pick from.
  Future<void> _loadSeries() async {
    try {
      final page = await widget.api.series(libraryId: widget.book['libraryId'] as String?, size: 5000);
      final names = {
        for (final s in (page['content'] as List? ?? const []))
          '${(s as Map)['metadata']?['title'] ?? s['name'] ?? ''}',
      }..remove('');
      if (mounted) setState(() => _seriesNames = names.toList()..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase())));
    } catch (_) {
      // (typed by hand then)
    }
  }

  Future<void> _pickDate() async {
    final picked = await showDatePicker(context: context, initialDate: _date ?? DateTime.now(),
        firstDate: DateTime(1800), lastDate: DateTime(2200));
    if (picked != null) setState(() => _date = picked);
  }

  Future<void> _save() async {
    if (_title.text.trim().isEmpty) return;
    final changes = bookChanges(widget.book, title: _title.text, number: _number.text, date: _date,
        series: _local ? _series : null, sort: _sort.text, summary: _summary.text,
        credits: {for (final MapEntry(:key, :value) in _credits.entries) key: value.text}, tags: _tags.text);
    if (changes.isEmpty) return Navigator.pop(context, false);
    setState(() => _saving = true);
    try {
      await widget.api.editBookMetadata(widget.book['id'] as String, changes);
      if (mounted) Navigator.pop(context, true);
    } catch (e, st) {
      if (!mounted) return;
      setState(() => _saving = false);
      showErrorSnack(context, couldnt('save the book', e, thing: 'book', forbidden: editNeedsAdmin), e, st);
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: const Text('Edit book'),
        content: SizedBox(width: 420, child: SingleChildScrollView(child: Column(mainAxisSize: MainAxisSize.min, children: [
          TextField(key: const ValueKey('edit-title'), controller: _title, autofocus: true,
              decoration: const InputDecoration(labelText: 'Title')),
          const SizedBox(height: 8),
          if (_local)
            Autocomplete<String>(
              initialValue: TextEditingValue(text: _series),
              optionsBuilder: (v) => v.text.isEmpty
                  ? _seriesNames
                  : _seriesNames.where((n) => n.toLowerCase().contains(v.text.toLowerCase())),
              onSelected: (v) => _series = v,
              fieldViewBuilder: (context, controller, focus, onSubmit) => TextField(
                key: const ValueKey('edit-series'), controller: controller, focusNode: focus,
                onChanged: (v) => _series = v,
                decoration: const InputDecoration(labelText: 'Series',
                    helperText: 'Pick one of the library\'s series, or type a new name'),
              ),
            )
          else
            InputDecorator(
              decoration: const InputDecoration(labelText: 'Series',
                  helperText: 'Komga makes series from folders: a book can\'t be moved to another one here',
                  helperMaxLines: 2),
              child: Text(_series),
            ),
          const SizedBox(height: 8),
          Row(children: [
            Expanded(child: TextField(key: const ValueKey('edit-number'), controller: _number,
                decoration: const InputDecoration(labelText: 'Number'))),
            const SizedBox(width: 16),
            Expanded(child: TextField(key: const ValueKey('edit-sort-number'), controller: _sort,
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                onChanged: (_) => _sortTyped = true,
                decoration: const InputDecoration(labelText: 'Sort number',
                    helperText: 'Where it sorts (an Annual: 12.5)', helperMaxLines: 2))),
          ]),
          const SizedBox(height: 8),
          Row(children: [
            Expanded(child: InputDecorator(decoration: const InputDecoration(labelText: 'Release date'),
                child: Text(_date == null ? 'None' : isoDate(_date!)))),
            IconButton(key: const ValueKey('edit-date'), tooltip: 'Pick a date', icon: const Icon(Icons.event),
                onPressed: _pickDate),
            if (_date != null)
              IconButton(key: const ValueKey('edit-date-clear'), tooltip: 'No date', icon: const Icon(Icons.clear),
                  onPressed: () => setState(() => _date = null)),
          ]),
          const SizedBox(height: 8),
          TextField(key: const ValueKey('edit-summary'), controller: _summary, minLines: 2, maxLines: 6,
              decoration: const InputDecoration(labelText: 'Summary')),
          for (final MapEntry(key: role, value: label) in editedRoles.entries) ...[
            const SizedBox(height: 8),
            TextField(key: ValueKey('edit-credits-$role'), controller: _credits[role],
                decoration: InputDecoration(labelText: label, helperText: role == 'writer' ? 'Names separated by commas' : null)),
          ],
          const SizedBox(height: 8),
          TextField(key: const ValueKey('edit-tags'), controller: _tags,
              decoration: const InputDecoration(labelText: 'Tags', helperText: 'Separated by commas')),
        ]))),
        actions: [
          TextButton(onPressed: _saving ? null : () => Navigator.pop(context, false), child: const Text('Cancel')),
          FilledButton(key: const ValueKey('edit-save'), onPressed: _saving ? null : _save,
              child: _saving
                  ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                  : const Text('Save')),
        ],
      );
}

/// Komga's reading directions and statuses, with the words shown for them.
const readingDirections = {
  'LEFT_TO_RIGHT': 'Left to right', 'RIGHT_TO_LEFT': 'Right to left (manga)', 'VERTICAL': 'Vertical',
  'WEBTOON': 'Webtoon',
};
const seriesStatuses = {'ONGOING': 'Ongoing', 'ENDED': 'Ended', 'HIATUS': 'Hiatus', 'ABANDONED': 'Abandoned'};

/// The changes made to a series' fields, by Komga's names - only what differs from [series].
Map<String, Object?> seriesChanges(Map series, {required String title, required String titleSort,
    required String? readingDirection, required String? status, required String publisher, String? summary,
    String? genres, String? tags}) {
  final m = (series['metadata'] as Map?) ?? const {};
  final out = <String, Object?>{};
  if (title.trim() != '${m['title'] ?? series['name'] ?? ''}') out['title'] = title.trim();
  if (titleSort.trim() != '${m['titleSort'] ?? ''}') out['titleSort'] = titleSort.trim();
  final dir = m['readingDirection'] as String?;
  if (readingDirection != dir) out['readingDirection'] = readingDirection; // (null: not set)
  if (status != null && status != m['status']) out['status'] = status;
  if (publisher.trim() != '${m['publisher'] ?? ''}') out['publisher'] = publisher.trim();
  if (summary != null && summary.trim() != '${m['summary'] ?? ''}'.trim()) out['summary'] = summary.trim();
  if (genres != null && !_sameNames(namesIn(genres), [for (final g in (m['genres'] as List?) ?? const []) '$g'])) {
    out['genres'] = namesIn(genres);
  }
  if (tags != null && !_sameNames(namesIn(tags), [for (final t in (m['tags'] as List?) ?? const []) '$t'])) {
    out['tags'] = namesIn(tags);
  }
  return out;
}

class _SeriesEditor extends StatefulWidget {
  const _SeriesEditor({required this.api, required this.series});
  final BookSource api;
  final Map series;
  @override
  State<_SeriesEditor> createState() => _SeriesEditorState();
}

class _SeriesEditorState extends State<_SeriesEditor> {
  Map get _m => (widget.series['metadata'] as Map?) ?? const {};
  late final _title = TextEditingController(text: '${_m['title'] ?? widget.series['name'] ?? ''}');
  late final _sort = TextEditingController(text: '${_m['titleSort'] ?? ''}');
  late String? _direction = readingDirections.containsKey(_m['readingDirection']) ? _m['readingDirection'] as String : null;
  late String? _status = seriesStatuses.containsKey(_m['status']) ? _m['status'] as String : null;
  String _publisher = '';
  List<String> _publishers = const [];
  late final _summary = TextEditingController(text: '${_m['summary'] ?? ''}');
  late final _genres = TextEditingController(text: namesText(_m['genres']));
  late final _tags = TextEditingController(text: namesText(_m['tags']));
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _publisher = '${_m['publisher'] ?? ''}';
    widget.api.publishers(libraryId: widget.series['libraryId'] as String?).then((p) {
      if (mounted) setState(() => _publishers = p);
    }, onError: (Object _) {});
  }

  Future<void> _save() async {
    if (_title.text.trim().isEmpty) return;
    final changes = seriesChanges(widget.series, title: _title.text, titleSort: _sort.text,
        readingDirection: _direction, status: _status, publisher: _publisher, summary: _summary.text,
        genres: _genres.text, tags: _tags.text);
    if (changes.isEmpty) return Navigator.pop(context, false);
    setState(() => _saving = true);
    try {
      await widget.api.editSeriesMetadata(widget.series['id'] as String, changes);
      if (mounted) Navigator.pop(context, true);
    } catch (e, st) {
      if (!mounted) return;
      setState(() => _saving = false);
      showErrorSnack(context, couldnt('save the series', e, thing: 'series', forbidden: editNeedsAdmin), e, st);
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: const Text('Edit series'),
        content: SizedBox(width: 420, child: SingleChildScrollView(child: Column(mainAxisSize: MainAxisSize.min, children: [
          TextField(key: const ValueKey('edit-title'), controller: _title, autofocus: true,
              decoration: const InputDecoration(labelText: 'Title')),
          const SizedBox(height: 8),
          TextField(key: const ValueKey('edit-sort'), controller: _sort,
              decoration: const InputDecoration(labelText: 'Sort title', helperText: 'Empty: sorted by its title')),
          const SizedBox(height: 8),
          DropdownButtonFormField<String?>(
            key: const ValueKey('edit-direction'),
            initialValue: _direction,
            decoration: const InputDecoration(labelText: 'Reading direction'),
            items: [
              const DropdownMenuItem(value: null, child: Text('Not set')),
              for (final MapEntry(:key, :value) in readingDirections.entries) DropdownMenuItem(value: key, child: Text(value)),
            ],
            onChanged: (v) => setState(() => _direction = v),
          ),
          const SizedBox(height: 8),
          DropdownButtonFormField<String?>(
            key: const ValueKey('edit-status'),
            initialValue: _status,
            decoration: const InputDecoration(labelText: 'Status'),
            items: [
              for (final MapEntry(:key, :value) in seriesStatuses.entries) DropdownMenuItem(value: key, child: Text(value)),
            ],
            onChanged: (v) => setState(() => _status = v),
          ),
          const SizedBox(height: 8),
          Autocomplete<String>(
            initialValue: TextEditingValue(text: _publisher),
            optionsBuilder: (v) => v.text.isEmpty
                ? const <String>[]
                : _publishers.where((n) => n.toLowerCase().contains(v.text.toLowerCase())),
            onSelected: (v) => _publisher = v,
            fieldViewBuilder: (context, controller, focus, onSubmit) => TextField(
              key: const ValueKey('edit-publisher'), controller: controller, focusNode: focus,
              onChanged: (v) => _publisher = v,
              decoration: const InputDecoration(labelText: 'Publisher'),
            ),
          ),
          const SizedBox(height: 8),
          TextField(key: const ValueKey('edit-summary'), controller: _summary, minLines: 2, maxLines: 6,
              decoration: const InputDecoration(labelText: 'Summary')),
          const SizedBox(height: 8),
          TextField(key: const ValueKey('edit-genres'), controller: _genres,
              decoration: const InputDecoration(labelText: 'Genres', helperText: 'Separated by commas')),
          const SizedBox(height: 8),
          TextField(key: const ValueKey('edit-tags'), controller: _tags,
              decoration: const InputDecoration(labelText: 'Tags', helperText: 'Separated by commas')),
        ]))),
        actions: [
          TextButton(onPressed: _saving ? null : () => Navigator.pop(context, false), child: const Text('Cancel')),
          FilledButton(key: const ValueKey('edit-save'), onPressed: _saving ? null : _save,
              child: _saving
                  ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                  : const Text('Save')),
        ],
      );
}
