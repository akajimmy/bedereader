import 'package:flutter/material.dart';

import '../widgets/setting_rows.dart';
import 'access.dart';
import 'folder_browser.dart';
import 'folder_komga.dart';
import 'folder_scan.dart';

/// Settings > Server and sync in local mode: the libraries (folders) - added, renamed, removed - and Scan again,
/// with how far a scan running has got. Removing one takes it out of the app only: its files stay where they are.
class LocalLibrariesGroup extends StatelessWidget {
  const LocalLibrariesGroup({super.key, required this.api});
  final FolderKomga api;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: Listenable.merge([api.changed, api.scanning]),
        builder: (context, _) {
          final scanned = api.scanning.value;
          return SettingsGroup(title: 'Local libraries', children: [
            for (final l in api.folders)
              ListTile(
                contentPadding: const EdgeInsets.only(left: 14, right: 4),
                leading: const Icon(Icons.folder_outlined),
                title: Text(l.name, style: const TextStyle(fontSize: 14.5)),
                subtitle: Text(l.path, style: const TextStyle(fontSize: 12, color: hintColour)),
                trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                  IconButton(tooltip: 'Rename', icon: const Icon(Icons.edit_outlined), onPressed: () => _rename(context, l)),
                  IconButton(tooltip: 'Remove', icon: const Icon(Icons.delete_outline),
                      onPressed: () => _remove(context, l)),
                ]),
              ),
            ActionRow(title: 'Add a library', icon: Icons.add, onTap: () => _add(context)),
            ActionRow(
              title: scanned == null ? 'Scan again' : 'Scanning… $scanned books',
              subtitle: 'New and changed files are read; books whose files went are taken off',
              icon: Icons.refresh,
              onTap: scanned == null ? () => api.rescan() : null,
            ),
          ]);
        },
      );

  Future<String?> _ask(BuildContext context, {required String title, required String label, String initial = '',
      String? hint, required String action}) {
    final c = TextEditingController(text: initial);
    return showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: TextField(controller: c, autofocus: true, autocorrect: false, enableSuggestions: false,
            decoration: InputDecoration(labelText: label, hintText: hint),
            onSubmitted: (v) => Navigator.pop(ctx, v)),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          TextButton(onPressed: () => Navigator.pop(ctx, c.text), child: Text(action)),
        ],
      ),
    ).whenComplete(c.dispose);
  }

  Future<void> _add(BuildContext context) async {
    // browsed for (this device, a drive, a share), or typed from the browser's "Type a folder…"
    final path = await pickFolder(context);
    if (path == null || path.trim().isEmpty || !context.mounted) return;
    final lib = LocalLibrary.at(path);
    final messenger = ScaffoldMessenger.maybeOf(context);
    if (api.folders.any((l) => l.id == lib.id)) {
      messenger?.showSnackBar(const SnackBar(content: Text('That folder is a library already')));
      return;
    }
    // reachable: a share's login asked for and tried, the tablet's All files access (each said in a dialog if not)
    if (!await FolderAccess.ensure(context, lib.path)) return;
    await api.setLibraries([...api.folders, lib]);
  }

  Future<void> _rename(BuildContext context, LocalLibrary l) async {
    final name = await _ask(context, title: 'Rename library', label: 'Name', initial: l.name, action: 'Rename');
    if (name == null || name.trim().isEmpty || name.trim() == l.name) return;
    await api.setLibraries([for (final x in api.folders) x.id == l.id ? LocalLibrary(name.trim(), x.path) : x]);
  }

  Future<void> _remove(BuildContext context, LocalLibrary l) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Remove ${l.name}?'),
        content: const Text('It goes from the app only - its files stay where they are. Adding the folder again '
            'brings back its reading progress.'),
        actions: [
          TextButton(autofocus: true, onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Remove')),
        ],
      ),
    );
    if (ok != true) return;
    await api.setLibraries([for (final x in api.folders) if (x.id != l.id) x]);
  }
}
