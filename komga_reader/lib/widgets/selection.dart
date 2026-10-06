import 'package:flutter/material.dart';

import '../api.dart';
import '../errors.dart';
import '../offline/downloads.dart';
import '../screens/actions.dart';
import 'error_text.dart';
import 'fullscreen_exit.dart';

/// Multi-select state for a book grid. While [active], tapping (or OK on) a book toggles it instead of opening it.
class Selection extends ChangeNotifier {
  bool active = false;
  final Map<String, dynamic> _books = {}; // id -> book, in the order picked

  int get count => _books.length;
  List<dynamic> get books => _books.values.toList();
  bool isSelected(dynamic b) => _books.containsKey(b['id']);

  void start([dynamic first]) {
    active = true;
    if (first != null) _books[first['id'] as String] = first;
    notifyListeners();
  }

  void toggle(dynamic b) {
    final id = b['id'] as String;
    _books.containsKey(id) ? _books.remove(id) : _books[id] = b;
    notifyListeners();
  }

  void selectAll(Iterable<dynamic> all) {
    for (final b in all) {
      _books[b['id'] as String] = b;
    }
    notifyListeners();
  }

  void end() {
    active = false;
    _books.clear();
    notifyListeners();
  }
}

/// Top bar while selecting: close, "N selected", select all (everything loaded), mark read, mark unread, delete.
/// [all] gives the books currently loaded in the grid; [onChanged] refreshes the grid after an action.
PreferredSizeWidget selectionAppBar(BuildContext context, Komga api, Selection sel,
    {required List<dynamic> Function() all, required VoidCallback onChanged}) {
  final none = sel.count == 0;
  Future<void> run(Future<void> Function() action) async {
    await action();
    sel.end();
    onChanged();
  }

  return AppBar(
    leading: IconButton(tooltip: 'Stop selecting', icon: const Icon(Icons.close), onPressed: sel.end),
    title: Text(none ? 'Select books' : '${sel.count} selected'),
    actions: [
      IconButton(tooltip: 'Select all', icon: const Icon(Icons.select_all), onPressed: () => sel.selectAll(all())),
      if (Downloads.instance.ready)
        IconButton(
          tooltip: 'Download',
          icon: const Icon(Icons.download_outlined),
          onPressed: none
              ? null
              : () async {
                  final books = sel.books; // in the order they were picked
                  final int added;
                  try {
                    added = await Downloads.instance.add(books);
                  } catch (e, st) {
                    // (code review 2026-10-05, #30: a disk error went unhandled)
                    if (context.mounted) showErrorSnack(context, couldnt('queue the books for download', e), e, st);
                    return;
                  }
                  final skipped = books.length - added;
                  if (context.mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(added == 0
                        ? 'All already downloaded or queued'
                        : 'Queued $added book${added == 1 ? '' : 's'} for download'
                            '${skipped > 0 ? ' ($skipped already downloaded or queued)' : ''}')));
                  }
                  sel.end();
                },
        ),
      IconButton(tooltip: 'Mark as read', icon: const Icon(Icons.check_circle_outline),
          onPressed: none ? null : () => run(() => bulkMark(context, api, sel.books, read: true))),
      IconButton(tooltip: 'Mark as unread', icon: const Icon(Icons.radio_button_unchecked),
          onPressed: none ? null : () => run(() => bulkMark(context, api, sel.books, read: false))),
      IconButton(tooltip: 'Delete…', icon: const Icon(Icons.delete_outline, color: Color(0xFFFF8A80)),
          onPressed: none ? null : () async {
            if (await bulkDelete(context, api, sel.books)) {
              sel.end();
              onChanged();
            }
          }),
      const FullscreenExit(),
    ],
  );
}

/// Top-bar button that enters multi-select.
class SelectButton extends StatelessWidget {
  const SelectButton({super.key, required this.selection});
  final Selection selection;
  @override
  Widget build(BuildContext context) =>
      IconButton(tooltip: 'Select multiple', icon: const Icon(Icons.checklist), onPressed: () => selection.start());
}

/// Rebuilds a screen as the selection changes; Back while selecting ends the selection instead of leaving.
Widget selectionScope(Selection sel, WidgetBuilder builder) => ListenableBuilder(
      listenable: sel,
      builder: (context, _) => PopScope(
        canPop: !sel.active,
        onPopInvokedWithResult: (didPop, _) { if (!didPop) sel.end(); },
        child: builder(context),
      ),
    );
