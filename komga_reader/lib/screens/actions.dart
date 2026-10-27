import 'package:flutter/material.dart';

import '../api.dart';
import '../book_title.dart';
import '../errors.dart';
import '../local/book_names.dart' show isLocalId;
import '../ondeck_hidden.dart';
import '../offline/downloads.dart';
import '../pins.dart';
import '../widgets/error_text.dart';
import 'book_details.dart';
import 'series.dart';
import 'series_details.dart';
import '../book_source.dart';

/// Book actions sheet (long-press a book): details, view series (not when already in that series), mark as read,
/// mark as unread (both always offered; a book already in that state is left alone), select multiple (where the
/// screen supports it), delete.
/// Every entry is a focusable list tile, so the remote can drive it.
/// Returns what was done: 'read', 'unread', 'deleted', or null (cancelled / nothing to do / failed).
Future<String?> showBookActions(BuildContext context, BookSource api, dynamic b,
    {required VoidCallback onChanged, VoidCallback? onSelectMultiple, String? readListId, bool showViewSeries = true}) async {
  final title = bookTitle(b);
  final dl = Downloads.instance;
  final pinned = Pins.instance.find(Pin.book(b));
  final choice = await showModalBottomSheet<String>(
    context: context,
    backgroundColor: const Color(0xFF141416),
    builder: (ctx) => SafeArea(
      child: SingleChildScrollView(child: Column(mainAxisSize: MainAxisSize.min, children: [
        ListTile(title: Text(title), subtitle: Text(bookSubtitle(b))),
        const Divider(height: 1),
        ListTile(autofocus: true, leading: const Icon(Icons.info_outline), title: const Text('Details'),
            onTap: () => Navigator.pop(ctx, 'details')),
        if (showViewSeries)
          ListTile(leading: const Icon(Icons.collections_bookmark_outlined), title: const Text('View series'),
              onTap: () => Navigator.pop(ctx, 'series')),
        if (dl.canDownload(b['id'] as String)) // (Komga's, or a network book's - one on the device is here)
          dl.isDownloaded(b['id'] as String)
              ? ListTile(leading: const Icon(Icons.download_done), title: const Text('Remove download'),
                  subtitle: const Text('Frees the space on this device; the book stays on the server'),
                  onTap: () => Navigator.pop(ctx, 'undownload'))
              : dl.downloadJob(b['id'] as String) != null
                  ? const ListTile(enabled: false, leading: Icon(Icons.downloading), title: Text('In the download queue'))
                  : ListTile(leading: const Icon(Icons.download_outlined), title: const Text('Download'),
                      onTap: () => Navigator.pop(ctx, 'download')),
        ListTile(leading: const Icon(Icons.check_circle_outline), title: const Text('Mark as read'),
            onTap: () => Navigator.pop(ctx, 'read')),
        ListTile(leading: const Icon(Icons.radio_button_unchecked), title: const Text('Mark as unread'),
            onTap: () => Navigator.pop(ctx, 'unread')),
        // a single book pinned to Home (user, 2026-10-16); pinned: rename or unpin it
        if (pinned == null)
          ListTile(leading: const Icon(Icons.push_pin_outlined), title: const Text('Pin to Home'),
              onTap: () => Navigator.pop(ctx, 'pin'))
        else
          ListTile(leading: const Icon(Icons.push_pin), title: Text('Pinned as "${pinned.name}"'),
              subtitle: const Text('Rename or unpin'), onTap: () => Navigator.pop(ctx, 'pin')),
        OnDeckHidden.instance.bookHidden(b['id'] as String?)
            ? ListTile(leading: const Icon(Icons.visibility_outlined), title: const Text('Show in On deck again'),
                onTap: () => Navigator.pop(ctx, 'ondeck-show'))
            : ListTile(leading: const Icon(Icons.visibility_off_outlined), title: const Text('Hide from On deck'),
                subtitle: const Text('Skips this book; its series comes back once it is read'),
                onTap: () => Navigator.pop(ctx, 'ondeck-hide')),
        if (onSelectMultiple != null)
          ListTile(leading: const Icon(Icons.checklist), title: const Text('Select multiple'),
              onTap: () => Navigator.pop(ctx, 'select')),
        // (Komga's only: a local or network book's delete is in the backlog - user, 2026-10-27)
        if (!isLocalId(b['id'] as String))
          ListTile(leading: const Icon(Icons.delete_outline, color: Color(0xFFFF8A80)),
              title: const Text('Delete book…', style: TextStyle(color: Color(0xFFFF8A80))),
              onTap: () => Navigator.pop(ctx, 'delete')),
      ])),
    ),
  );
  if (choice == null || !context.mounted) return null;
  if (choice == 'select') {
    onSelectMultiple!();
    return null;
  }
  if (choice == 'pin') {
    await showPinDialog(context, pinned ?? Pin.book(b), pinned: pinned != null);
    return null;
  }
  if (choice == 'ondeck-hide' || choice == 'ondeck-show') {
    OnDeckHidden.instance.setBook(b['id'] as String, choice == 'ondeck-hide');
    return null;
  }
  if (choice == 'download' || choice == 'undownload') {
    try {
      if (choice == 'download') {
        await dl.add([b]);
      } else {
        await dl.remove(b['id'] as String);
      }
    } catch (e, st) {
      // a disk full, a folder that can't be written (code review 2026-10-05, #30: unhandled)
      if (context.mounted) {
        showErrorSnack(context, couldnt(choice == 'download' ? 'queue "$title" for download'
            : 'remove the download of "$title"', e, thing: 'book'), e, st);
      }
      return null;
    }
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(choice == 'download' ? 'Queued "$title" for download' : 'Removed the download of "$title"')));
    }
    onChanged();
    return null;
  }
  if (choice == 'details' || choice == 'series') {
    try {
      final nav = Navigator.of(context);
      if (choice == 'details') {
        await nav.push(MaterialPageRoute(builder: (_) =>
            BookDetailsScreen(api: api, book: b, readListId: readListId, showViewSeries: showViewSeries)));
      } else {
        final s = await api.oneSeries(b['seriesId'] as String);
        if (s != null) await nav.push(MaterialPageRoute(builder: (_) => SeriesScreen(api: api, series: s)));
      }
      onChanged(); // read state may have changed there
    } catch (e, st) {
      if (context.mounted) showErrorSnack(context, couldnt('open the series of "$title"', e, thing: 'series'), e, st);
    }
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
  } catch (e, st) {
    if (context.mounted) {
      showErrorSnack(context, choice == 'delete'
          ? couldnt('delete "$title"', e, thing: 'book', forbidden: deleteNeedsAdmin)
          : couldnt('mark "$title" as $choice', e, thing: 'book'), e, st);
    }
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
Future<void> bulkMark(BuildContext context, BookSource api, List<dynamic> books, {required bool read}) async {
  final todo = books.where((b) => needsChange(b, read: read)).toList();
  final messenger = ScaffoldMessenger.of(context);
  final word = read ? 'read' : 'unread';
  var done = 0;
  try {
    for (var i = 0; i < todo.length; i += 4) {
      final batch = todo.skip(i).take(4).toList();
      await Future.wait([
        for (final b in batch) read ? api.markRead(b['id'] as String) : api.markUnread(b['id'] as String),
      ]);
      done += batch.length;
    }
    final skipped = books.length - todo.length;
    messenger.showSnackBar(SnackBar(content: Text(todo.isEmpty
        ? 'All ${books.length} already $word'
        : '${todo.length} marked $word${skipped > 0 ? ' ($skipped already $word)' : ''}')));
  } catch (e, st) {
    showErrorOn(messenger, done == 0
        ? couldnt('mark the books as $word', e)
        : stoppedAfter('Marked $done of ${todo.length} as $word', e), e, st);
  }
}

/// Delete several books' files (confirmed first, Cancel focused). Returns true if anything was deleted.
Future<bool> bulkDelete(BuildContext context, BookSource api, List<dynamic> books) async {
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
  } catch (e, st) {
    showErrorOn(messenger, done == 0
        ? couldnt('delete the books', e, thing: 'book', forbidden: deleteNeedsAdmin)
        : stoppedAfter('Deleted $done of $n', e, forbidden: deleteNeedsAdmin), e, st);
  }
  return done > 0;
}

/// Series actions: mark whole series read/unread, download, select multiple (where the grid supports it), delete
/// series.
Future<void> showSeriesActions(BuildContext context, BookSource api, dynamic s,
    {required VoidCallback onChanged, bool inSeries = false, VoidCallback? onSelectMultiple}) async {
  final title = (s['metadata']?['title'] ?? s['name']) as String;
  final view = listPin('series', s['id'] as String, title);
  final pinned = Pins.instance.find(view);
  final choice = await showModalBottomSheet<String>(
    context: context,
    backgroundColor: const Color(0xFF141416),
    builder: (ctx) => SafeArea(
      child: SingleChildScrollView(child: Column(mainAxisSize: MainAxisSize.min, children: [
        ListTile(title: Text(title), subtitle: Text('${s['booksCount'] ?? 0} books')),
        const Divider(height: 1),
        ListTile(autofocus: true, leading: const Icon(Icons.info_outline), title: const Text('Details'),
            onTap: () => Navigator.pop(ctx, 'details')),
        pinTile(ctx, pinned),
        ListTile(leading: const Icon(Icons.check_circle_outline), title: const Text('Mark series as read'),
            onTap: () => Navigator.pop(ctx, 'read')),
        ListTile(leading: const Icon(Icons.radio_button_unchecked), title: const Text('Mark series as unread'),
            onTap: () => Navigator.pop(ctx, 'unread')),
        ...downloadTiles(ctx),
        OnDeckHidden.instance.seriesHidden(s['id'] as String?)
            ? ListTile(leading: const Icon(Icons.visibility_outlined), title: const Text('Show in On deck again'),
                onTap: () => Navigator.pop(ctx, 'ondeck-show'))
            : ListTile(leading: const Icon(Icons.visibility_off_outlined), title: const Text('Hide from On deck'),
                subtitle: const Text('This series never shows in On deck'),
                onTap: () => Navigator.pop(ctx, 'ondeck-hide')),
        if (onSelectMultiple != null)
          ListTile(leading: const Icon(Icons.checklist), title: const Text('Select multiple'),
              onTap: () => Navigator.pop(ctx, 'select')),
        ListTile(leading: const Icon(Icons.delete_outline, color: Color(0xFFFF8A80)),
            title: const Text('Delete series…', style: TextStyle(color: Color(0xFFFF8A80))),
            onTap: () => Navigator.pop(ctx, 'delete')),
      ])),
    ),
  );
  if (choice == null || !context.mounted) return;
  if (choice == 'select') {
    onSelectMultiple!();
    return;
  }
  if (choice == 'pin') return showPinDialog(context, pinned ?? view, pinned: pinned != null);
  if (choice == 'details') {
    await Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => SeriesDetailsScreen(api: api, series: s, showOpen: !inSeries)));
    onChanged(); // read state may have changed there
    return;
  }
  if (choice == 'ondeck-hide' || choice == 'ondeck-show') {
    OnDeckHidden.instance.setSeries(s['id'] as String, choice == 'ondeck-hide');
    return;
  }
  if (choice == 'dl-all' || choice == 'dl-unread') {
    return queueDownloads(context, '"$title"',
        (status) => api.seriesBooks(s['id'] as String, readStatus: status, size: 2000),
        unreadOnly: choice == 'dl-unread');
  }
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
      if (inSeries && context.mounted) {
        // deleted from its own screen: there's nothing left to show here - back to where it was opened from (code
        // review, 2026-09-30: the empty screen stayed, pin and actions and all)
        ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(content: Text('Deleted "$title"')));
        Navigator.of(context).pop();
        return;
      }
    }
    onChanged();
  } catch (e, st) {
    if (context.mounted) {
      showErrorSnack(context, choice == 'delete'
          ? couldnt('delete "$title"', e, thing: 'series', forbidden: deleteNeedsAdmin)
          : couldnt('mark "$title" as $choice', e, thing: 'series'), e, st);
    }
  }
}

/// Renames a read list on Komga (user, 2026-10-18: "starting with the ability to rename a read list"): asks for the
/// name, sends it, and updates [rl] in place - its screen shows the new name - and the pins of the list. Komga lets
/// admin accounts only do it, and turns down a name another read list has: both said so.
Future<void> renameReadList(BuildContext context, BookSource api, dynamic rl, {required VoidCallback onChanged}) =>
    _renameList(context, rl, 'read list', 'readlist', api.renameReadList, onChanged);

/// Renames a collection, as [renameReadList] a read list (user, 2026-10-18: its menu "does not ... have any options").
Future<void> renameCollection(BuildContext context, BookSource api, dynamic c, {required VoidCallback onChanged}) =>
    _renameList(context, c, 'collection', 'collection', api.renameCollection, onChanged);

Future<void> _renameList(BuildContext context, dynamic list, String thing, String pinKind,
    Future<void> Function(String id, String name) send, VoidCallback onChanged) async {
  final old = list['name'] as String;
  final name = await askName(context, title: 'Rename $thing', label: 'Name', initial: old, action: 'Rename');
  if (name == null || name == old || !context.mounted) return;
  final messenger = ScaffoldMessenger.of(context);
  try {
    await send(list['id'] as String, name);
  } catch (e, st) {
    showErrorOn(messenger, e is KomgaError && e.status == 400
        ? "Couldn't rename \"$old\": Komga turned the name down. Another $thing may already be called \"$name\"."
        : couldnt('rename "$old"', e, thing: thing, forbidden: editNeedsAdmin), e, st);
    return;
  }
  list['name'] = name;
  Pins.instance.retitle(pinKind, list['id'] as String, old, name);
  messenger.showSnackBar(SnackBar(content: Text('Renamed to "$name"')));
  onChanged();
}

/// A series', read list's or collection's plain view as a pin - as its screen pins it with nothing filtered or
/// sorted - for "Pin to Home" in its menu (user, 2026-10-18: "right click / context menu on a read list or series
/// should allow pin").
Pin listPin(String kind, String id, String name) => Pin(name: name, kind: kind, id: id, title: name);

/// A menu's pin entry: "Pin to Home", or, pinned already, the pin's name - to rename or unpin it. Pops 'pin'.
Widget pinTile(BuildContext ctx, Pin? pinned, {bool autofocus = false}) => pinned == null
    ? ListTile(autofocus: autofocus, leading: const Icon(Icons.push_pin_outlined), title: const Text('Pin to Home'),
        onTap: () => Navigator.pop(ctx, 'pin'))
    : ListTile(autofocus: autofocus, leading: const Icon(Icons.push_pin), title: Text('Pinned as "${pinned.name}"'),
        subtitle: const Text('Rename or unpin'), onTap: () => Navigator.pop(ctx, 'pin'));

/// Collection actions (right-click / long-press a collection; user, 2026-10-18: it had no menu at all): pin it to
/// Home, mark every series in it read or unread, rename it.
Future<void> showCollectionActions(BuildContext context, BookSource api, dynamic c,
    {required VoidCallback onChanged}) async {
  final name = c['name'] as String;
  final ids = [for (final id in (c['seriesIds'] as List?) ?? const []) '$id'];
  final view = listPin('collection', c['id'] as String, name);
  final pinned = Pins.instance.find(view);
  final choice = await showModalBottomSheet<String>(
    context: context,
    backgroundColor: const Color(0xFF141416),
    builder: (ctx) => SafeArea(
      child: SingleChildScrollView(child: Column(mainAxisSize: MainAxisSize.min, children: [
        ListTile(title: Text(name), subtitle: Text('${ids.length} series')),
        const Divider(height: 1),
        pinTile(ctx, pinned, autofocus: true),
        ListTile(leading: const Icon(Icons.check_circle_outline), title: const Text('Mark all as read'),
            onTap: () => Navigator.pop(ctx, 'read')),
        ListTile(leading: const Icon(Icons.radio_button_unchecked), title: const Text('Mark all as unread'),
            onTap: () => Navigator.pop(ctx, 'unread')),
        ListTile(leading: const Icon(Icons.edit_outlined), title: const Text('Rename'),
            onTap: () => Navigator.pop(ctx, 'rename')),
      ])),
    ),
  );
  if (choice == null || !context.mounted) return;
  if (choice == 'pin') return showPinDialog(context, pinned ?? view, pinned: pinned != null);
  if (choice == 'rename') return renameCollection(context, api, c, onChanged: onChanged);
  final read = choice == 'read';
  if (!await confirmBulk(context,
      read ? 'Mark all ${ids.length} series of "$name" read?' : 'Mark all ${ids.length} series of "$name" unread?',
      read ? 'Books in progress are marked finished.' : 'This also clears the saved page of books in progress.',
      read ? 'Mark read' : 'Mark unread')) {
    return;
  }
  if (!context.mounted) return;
  final messenger = ScaffoldMessenger.of(context);
  messenger.showSnackBar(SnackBar(content: Text('Updating "$name"…'), duration: const Duration(minutes: 5)));
  var done = 0;
  try {
    for (final id in ids) {
      read ? await api.markSeriesRead(id) : await api.markSeriesUnread(id);
      done++;
    }
    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text('${ids.length} series marked ${read ? 'read' : 'unread'}')));
  } catch (e, st) {
    messenger.hideCurrentSnackBar();
    final word = read ? 'read' : 'unread';
    showErrorOn(messenger, done == 0
        ? couldnt('mark "$name" as $word', e, thing: 'collection')
        : stoppedAfter('Marked $done of ${ids.length} series $word', e), e, st);
  }
  onChanged();
}

/// The [askName] dialog's own button (tests find it by this).
const askNameOkKey = ValueKey('askName.ok');

/// Asks for a name (or a server, a folder): [initial] filled in and selected, ready to type over; [hint] in the empty
/// box; [plain]: typed as it is - no autocorrect or suggestions (an address, a path). Null: cancelled, or left empty.
Future<String?> askName(BuildContext context, {required String title, required String label, String initial = '',
    String action = 'OK', String? hint, bool plain = false}) async {
  final name = TextEditingController(text: initial)..selection = TextSelection(baseOffset: 0, extentOffset: initial.length);
  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(title),
      content: TextField(
        controller: name,
        autofocus: true,
        autocorrect: !plain,
        enableSuggestions: !plain,
        decoration: InputDecoration(labelText: label, hintText: hint),
        onSubmitted: (_) => Navigator.pop(ctx, true),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
        FilledButton(key: askNameOkKey, onPressed: () => Navigator.pop(ctx, true), child: Text(action)),
      ],
    ),
  );
  // (not disposed here: the dialog still shows the field while it closes - showPinDialog leaves it to the GC too)
  final n = name.text.trim();
  return ok == true && n.isNotEmpty ? n : null;
}

/// Read-list actions (long-press a read list, or ⋮ in the list): mark every book in it read or unread; rename it.
/// Komga has no bulk call for read lists, so only the books that need changing are updated, a few at a time.
Future<void> showReadListActions(BuildContext context, BookSource api, dynamic rl,
    {required VoidCallback onChanged}) async {
  final name = rl['name'] as String;
  final total = (rl['bookIds'] as List?)?.length ?? 0;
  final view = listPin('readlist', rl['id'] as String, name);
  final pinned = Pins.instance.find(view);
  final choice = await showModalBottomSheet<String>(
    context: context,
    backgroundColor: const Color(0xFF141416),
    builder: (ctx) => SafeArea(
      child: SingleChildScrollView(child: Column(mainAxisSize: MainAxisSize.min, children: [
        ListTile(title: Text(name), subtitle: Text('$total books')),
        const Divider(height: 1),
        pinTile(ctx, pinned, autofocus: true),
        ListTile(leading: const Icon(Icons.check_circle_outline), title: const Text('Mark all as read'),
            onTap: () => Navigator.pop(ctx, 'read')),
        ListTile(leading: const Icon(Icons.radio_button_unchecked), title: const Text('Mark all as unread'),
            onTap: () => Navigator.pop(ctx, 'unread')),
        ...downloadTiles(ctx),
        ListTile(leading: const Icon(Icons.edit_outlined), title: const Text('Rename'),
            onTap: () => Navigator.pop(ctx, 'rename')),
      ])),
    ),
  );
  if (choice == null || !context.mounted) return;
  if (choice == 'rename') return renameReadList(context, api, rl, onChanged: onChanged);
  if (choice == 'pin') return showPinDialog(context, pinned ?? view, pinned: pinned != null);
  if (choice == 'dl-all' || choice == 'dl-unread') {
    return queueDownloads(context, '"$name"', (status) => api.readListBooks(rl['id'] as String, readStatus: status, size: 2000),
        unreadOnly: choice == 'dl-unread');
  }
  final read = choice == 'read';
  if (!await confirmBulk(context, read ? 'Mark all $total books of "$name" read?' : 'Mark all $total books of "$name" unread?',
      read ? 'Books in progress are marked finished.' : 'This also clears the saved page of books in progress.',
      read ? 'Mark read' : 'Mark unread')) {
    return;
  }
  if (!context.mounted) return;
  final messenger = ScaffoldMessenger.of(context);
  messenger.showSnackBar(SnackBar(content: Text('Updating "$name"…'), duration: const Duration(minutes: 5)));
  final todo = <String>[];
  var done = 0;
  try {
    // books that need changing: for "read" everything not finished, for "unread" everything with progress
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
      final batch = todo.skip(i).take(4).toList();
      await Future.wait([
        for (final id in batch) read ? api.markRead(id) : api.markUnread(id),
      ]);
      done += batch.length;
    }
    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(todo.isEmpty
          ? 'Nothing to change in "$name"'
          : '${todo.length} book${todo.length == 1 ? '' : 's'} marked ${read ? 'read' : 'unread'}')));
  } catch (e, st) {
    final word = read ? 'read' : 'unread';
    showErrorOn(messenger, done == 0
        ? couldnt('mark "$name" as $word', e, thing: 'read list')
        : stoppedAfter('Marked $done of ${todo.length} in "$name" as $word', e), e, st);
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

/// "Download all" / "Download unread" entries for series and read-list menus (when downloads are available).
List<Widget> downloadTiles(BuildContext ctx) => !Downloads.instance.anyReady
    ? const []
    : [
        ListTile(leading: const Icon(Icons.download_outlined), title: const Text('Download unread'),
            subtitle: const Text('Unread and in-progress books'), onTap: () => Navigator.pop(ctx, 'dl-unread')),
        ListTile(leading: const Icon(Icons.download_for_offline_outlined), title: const Text('Download all'),
            onTap: () => Navigator.pop(ctx, 'dl-all')),
      ];

/// Queues the books of a series or read list (in their order) and says how many were added. [name] as shown in the
/// messages (a title in quotes, or "3 series").
Future<void> queueDownloads(BuildContext context, String name,
    Future<Map<String, dynamic>> Function(List<String>? readStatus) fetch, {required bool unreadOnly}) async {
  final messenger = ScaffoldMessenger.of(context);
  try {
    final r = await fetch(unreadOnly ? const ['UNREAD', 'IN_PROGRESS'] : null);
    final books = (r['content'] as List<dynamic>?) ?? [];
    final added = await Downloads.instance.add(books);
    final skipped = books.length - added;
    messenger.showSnackBar(SnackBar(content: Text(added == 0
        ? 'Nothing new to download from $name'
        : 'Queued $added book${added == 1 ? '' : 's'} from $name'
            '${skipped > 0 ? ' ($skipped already downloaded or queued)' : ''}')));
  } catch (e, st) {
    showErrorOn(messenger, couldnt('queue $name for download', e), e, st);
  }
}

/// Download several series (a series selection): asks "unread" or "all" as the one-series menu does, then queues
/// their books, series by series in the order they were picked, each in its number order. False if cancelled.
Future<bool> bulkDownloadSeries(BuildContext context, BookSource api, List<dynamic> series) async {
  final choice = await showModalBottomSheet<String>(
    context: context,
    backgroundColor: const Color(0xFF141416),
    builder: (ctx) => SafeArea(child: SingleChildScrollView(child: Column(mainAxisSize: MainAxisSize.min, children: [
      ListTile(title: Text('Download ${series.length} series')),
      const Divider(height: 1),
      ...downloadTiles(ctx),
    ]))),
  );
  if (choice == null || !context.mounted) return false;
  if (series.length == 1) {
    final title = (series.first['metadata']?['title'] ?? series.first['name']) as String;
    await queueDownloads(context, '"$title"',
        (status) => api.seriesBooks(series.first['id'] as String, readStatus: status, size: 2000),
        unreadOnly: choice == 'dl-unread');
  } else {
    await queueDownloads(context, '${series.length} series', (status) async => {
          'content': [
            for (final s in series)
              ...((await api.seriesBooks(s['id'] as String, readStatus: status, size: 2000))['content'] as List? ?? []),
          ],
        }, unreadOnly: choice == 'dl-unread');
  }
  return true;
}

/// Would marking this series read / unread change anything, by its counts? Read: a book not finished; unread: a book
/// read or in progress.
bool seriesNeedsChange(dynamic s, {required bool read}) {
  final total = (s['booksCount'] ?? 0) as int;
  final unread = (s['booksUnreadCount'] ?? 0) as int, inProgress = (s['booksInProgressCount'] ?? 0) as int;
  return read ? unread + inProgress > 0 : unread < total;
}

/// Mark several series read or unread (a series selection), confirmed first as for one series; those already in that
/// state are skipped, the rest a few at a time. False if cancelled.
Future<bool> bulkMarkSeries(BuildContext context, BookSource api, List<dynamic> series, {required bool read}) async {
  final n = series.length;
  final word = read ? 'read' : 'unread';
  if (!await confirmBulk(context, 'Mark all books of $n series $word?',
      read ? 'Books in progress are marked finished.' : 'This also clears the saved page of books in progress.',
      read ? 'Mark read' : 'Mark unread')) {
    return false;
  }
  if (!context.mounted) return false;
  final todo = series.where((s) => seriesNeedsChange(s, read: read)).toList();
  final messenger = ScaffoldMessenger.of(context);
  var done = 0;
  try {
    for (var i = 0; i < todo.length; i += 4) {
      final batch = todo.skip(i).take(4).toList();
      await Future.wait([
        for (final s in batch) read ? api.markSeriesRead(s['id'] as String) : api.markSeriesUnread(s['id'] as String),
      ]);
      done += batch.length;
    }
    final skipped = n - todo.length;
    messenger.showSnackBar(SnackBar(content: Text(todo.isEmpty
        ? 'All $n series already $word'
        : '${todo.length} series marked $word${skipped > 0 ? ' ($skipped already $word)' : ''}')));
  } catch (e, st) {
    showErrorOn(messenger, done == 0
        ? couldnt('mark the series as $word', e, thing: 'series')
        : stoppedAfter('Marked $done of ${todo.length} series as $word', e), e, st);
  }
  return true;
}
