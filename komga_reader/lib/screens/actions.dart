import 'package:flutter/material.dart';

import '../api.dart';

/// Book actions sheet (long-press a book): mark as read, mark as unread (both always offered; a book already in that
/// state is left alone), select multiple (where the screen supports it), delete.
/// Every entry is a focusable list tile, so the remote can drive it.
/// Returns what was done: 'read', 'unread', 'deleted', or null (cancelled / nothing to do / failed).
Future<String?> showBookActions(BuildContext context, Komga api, dynamic b,
    {required VoidCallback onChanged, VoidCallback? onSelectMultiple}) async {
  final title = '${b['seriesTitle'] ?? ''} #${b['metadata']?['number'] ?? ''}';
  final choice = await showModalBottomSheet<String>(
    context: context,
    backgroundColor: const Color(0xFF141416),
    builder: (ctx) => SafeArea(
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        ListTile(title: Text(title), subtitle: Text(b['metadata']?['title'] ?? '')),
        const Divider(height: 1),
        ListTile(autofocus: true, leading: const Icon(Icons.check_circle_outline), title: const Text('Mark as read'),
            onTap: () => Navigator.pop(ctx, 'read')),
        ListTile(leading: const Icon(Icons.radio_button_unchecked), title: const Text('Mark as unread'),
            onTap: () => Navigator.pop(ctx, 'unread')),
        if (onSelectMultiple != null)
          ListTile(leading: const Icon(Icons.checklist), title: const Text('Select multiple'),
              onTap: () => Navigator.pop(ctx, 'select')),
        ListTile(leading: const Icon(Icons.delete_outline, color: Color(0xFFFF8A80)),
            title: const Text('Delete book…', style: TextStyle(color: Color(0xFFFF8A80))),
            onTap: () => Navigator.pop(ctx, 'delete')),
      ]),
    ),
  );
  if (choice == null || !context.mounted) return null;
  if (choice == 'select') {
    onSelectMultiple!();
    return null;
  }
  try {
    if (choice == 'read' || choice == 'unread') {
      final read = choice == 'read';
      if (!needsChange(b, read: read)) return null; // already in that state
      read ? await api.markRead(b['id']) : await api.markUnread(b['id']);
    }
    if (choice == 'delete') {
      if (!context.mounted) return null;
      final ok = await confirmDelete(context, 'Delete "$title"?',
          'This deletes the file from the server. It cannot be undone from the app.');
      if (!ok) return null;
      await api.deleteBookFile(b['id']);
    }
    onChanged();
    return choice == 'delete' ? 'deleted' : choice;
  } catch (e) {
    if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
    return null;
  }
}

/// Would marking this book read / unread change anything? Read = finished; unread = no progress at all (a book in
/// progress counts as not read, and marking it unread clears its page).
bool needsChange(dynamic b, {required bool read}) {
  final rp = b['readProgress'];
  return read ? !(rp != null && rp['completed'] == true) : rp != null;
}

/// Mark several books read or unread, skipping those already in that state; a few requests at a time.
Future<void> bulkMark(BuildContext context, Komga api, List<dynamic> books, {required bool read}) async {
  final todo = books.where((b) => needsChange(b, read: read)).toList();
  final messenger = ScaffoldMessenger.of(context);
  final word = read ? 'read' : 'unread';
  try {
    for (var i = 0; i < todo.length; i += 4) {
      await Future.wait([
        for (final b in todo.skip(i).take(4)) read ? api.markRead(b['id'] as String) : api.markUnread(b['id'] as String),
      ]);
    }
    final skipped = books.length - todo.length;
    messenger.showSnackBar(SnackBar(content: Text(todo.isEmpty
        ? 'All ${books.length} already $word'
        : '${todo.length} marked $word${skipped > 0 ? ' ($skipped already $word)' : ''}')));
  } catch (e) {
    messenger.showSnackBar(SnackBar(content: Text('Stopped part-way: $e')));
  }
}

/// Delete several books' files (confirmed first, Cancel focused). Returns true if anything was deleted.
Future<bool> bulkDelete(BuildContext context, Komga api, List<dynamic> books) async {
  final n = books.length;
  final ok = await confirmDelete(context, 'Delete $n book${n == 1 ? '' : 's'}?',
      'This deletes the files from the server. It cannot be undone from the app.');
  if (!ok || !context.mounted) return false;
  final messenger = ScaffoldMessenger.of(context);
  var done = 0;
  try {
    for (final b in books) {
      await api.deleteBookFile(b['id'] as String);
      done++;
    }
    messenger.showSnackBar(SnackBar(content: Text('Deleted $done book${done == 1 ? '' : 's'}')));
  } catch (e) {
    messenger.showSnackBar(SnackBar(content: Text('Deleted $done of $n, then stopped: $e')));
  }
  return done > 0;
}

/// Series actions: mark whole series read/unread, delete series.
Future<void> showSeriesActions(BuildContext context, Komga api, dynamic s, {required VoidCallback onChanged}) async {
  final title = (s['metadata']?['title'] ?? s['name']) as String;
  final choice = await showModalBottomSheet<String>(
    context: context,
    backgroundColor: const Color(0xFF141416),
    builder: (ctx) => SafeArea(
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        ListTile(title: Text(title), subtitle: Text('${s['booksCount'] ?? 0} books')),
        const Divider(height: 1),
        ListTile(autofocus: true, leading: const Icon(Icons.check_circle_outline), title: const Text('Mark series as read'),
            onTap: () => Navigator.pop(ctx, 'read')),
        ListTile(leading: const Icon(Icons.radio_button_unchecked), title: const Text('Mark series as unread'),
            onTap: () => Navigator.pop(ctx, 'unread')),
        ListTile(leading: const Icon(Icons.delete_outline, color: Color(0xFFFF8A80)),
            title: const Text('Delete series…', style: TextStyle(color: Color(0xFFFF8A80))),
            onTap: () => Navigator.pop(ctx, 'delete')),
      ]),
    ),
  );
  if (choice == null || !context.mounted) return;
  final n = s['booksCount'] ?? 0;
  if (choice == 'read' &&
      !await confirmBulk(context, 'Mark all $n books of "$title" read?', 'Books in progress are marked finished.', 'Mark read')) {
    return;
  }
  if (choice == 'unread' && context.mounted &&
      !await confirmBulk(context, 'Mark all $n books of "$title" unread?',
          'This also clears the saved page of books in progress.', 'Mark unread')) {
    return;
  }
  if (!context.mounted) return;
  try {
    if (choice == 'read') await api.markSeriesRead(s['id']);
    if (choice == 'unread') await api.markSeriesUnread(s['id']);
    if (choice == 'delete') {
      if (!context.mounted) return;
      final ok = await confirmDelete(context, 'Delete the series "$title"?',
          'This deletes all ${s['booksCount'] ?? ''} books of the series from the server. It cannot be undone from the app.');
      if (!ok) return;
      await api.deleteSeriesFiles(s['id']);
    }
    onChanged();
  } catch (e) {
    if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
  }
}

/// Read-list actions (long-press a read list, or ⋮ in the list): mark every book in it read or unread.
/// Komga has no bulk call for read lists, so only the books that need changing are updated, a few at a time.
Future<void> showReadListActions(BuildContext context, Komga api, dynamic rl, {required VoidCallback onChanged}) async {
  final name = rl['name'] as String;
  final total = (rl['bookIds'] as List?)?.length ?? 0;
  final choice = await showModalBottomSheet<String>(
    context: context,
    backgroundColor: const Color(0xFF141416),
    builder: (ctx) => SafeArea(
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        ListTile(title: Text(name), subtitle: Text('$total books')),
        const Divider(height: 1),
        ListTile(autofocus: true, leading: const Icon(Icons.check_circle_outline), title: const Text('Mark all as read'),
            onTap: () => Navigator.pop(ctx, 'read')),
        ListTile(leading: const Icon(Icons.radio_button_unchecked), title: const Text('Mark all as unread'),
            onTap: () => Navigator.pop(ctx, 'unread')),
      ]),
    ),
  );
  if (choice == null || !context.mounted) return;
  final read = choice == 'read';
  if (!await confirmBulk(context, read ? 'Mark all $total books of "$name" read?' : 'Mark all $total books of "$name" unread?',
      read ? 'Books in progress are marked finished.' : 'This also clears the saved page of books in progress.',
      read ? 'Mark read' : 'Mark unread')) {
    return;
  }
  if (!context.mounted) return;
  final messenger = ScaffoldMessenger.of(context);
  messenger.showSnackBar(SnackBar(content: Text('Updating "$name"…'), duration: const Duration(minutes: 5)));
  try {
    // books that need changing: for "read" everything not finished, for "unread" everything with progress
    final todo = <String>[];
    for (final status in read ? ['UNREAD', 'IN_PROGRESS'] : ['IN_PROGRESS', 'READ']) {
      var page = 0;
      while (true) {
        final r = await api.readListBooks(rl['id'] as String, readStatus: [status], page: page, size: 500);
        todo.addAll([for (final b in (r['content'] as List<dynamic>? ?? [])) b['id'] as String]);
        if (r['last'] != false) break;
        page++;
      }
    }
    for (var i = 0; i < todo.length; i += 4) {
      await Future.wait([
        for (final id in todo.skip(i).take(4)) read ? api.markRead(id) : api.markUnread(id),
      ]);
    }
    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(todo.isEmpty
          ? 'Nothing to change in "$name"'
          : '${todo.length} book${todo.length == 1 ? '' : 's'} marked ${read ? 'read' : 'unread'}')));
  } catch (e) {
    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text('Stopped part-way: $e')));
  }
  onChanged();
}

/// Confirm for actions that change many books at once; "Cancel" has focus.
Future<bool> confirmBulk(BuildContext context, String title, String body, String action) async {
  final r = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(title),
      content: Text(body),
      actions: [
        TextButton(autofocus: true, onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
        TextButton(onPressed: () => Navigator.pop(ctx, true), child: Text(action)),
      ],
    ),
  );
  return r == true;
}

/// Deletion always needs an explicit confirm; "Cancel" has focus so an accidental OK press on the remote is safe.
Future<bool> confirmDelete(BuildContext context, String title, String body) async {
  final r = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(title),
      content: Text(body),
      actions: [
        TextButton(autofocus: true, onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
        TextButton(onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Delete', style: TextStyle(color: Color(0xFFFF8A80)))),
      ],
    ),
  );
  return r == true;
}
