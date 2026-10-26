import 'package:flutter/material.dart';

import '../widgets/setting_rows.dart';
import 'access.dart';
import 'folder_browser.dart';
import 'folder_komga.dart';
import 'folder_scan.dart';
import 'where.dart';

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
                // what the last scan couldn't read, under the path (punch list 2: it used to say nothing)
                subtitle: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(whereHere(l.path).toString(), style: const TextStyle(fontSize: 12, color: hintColour)),
                  // what's in it, as said when it was added (not changed here: removed and added again)
                  if (l.kind != LibraryKind.seriesFolders)
                    Text(libraryKindLabel(l.kind), style: const TextStyle(fontSize: 12, color: hintColour)),
                  if (api.lastScan[l.id]?.summary case final s?)
                    Text(s[0].toUpperCase() + s.substring(1),
                        style: const TextStyle(fontSize: 12, color: Color(0xFFFACC15))),
                ]),
                // the files left out, listed (the log has five at most)
                onTap: (api.lastScan[l.id]?.leftOut ?? const []).isEmpty
                    ? null
                    : () => _showLeftOut(context, l, api.lastScan[l.id]!),
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

  /// The files of [library] the last scan left out, each with why - the file's name, and its folder under the library.
  Future<void> _showLeftOut(BuildContext context, LocalLibrary library, LibraryScan scan) {
    final root = library.path.replaceAll(RegExp(r'[\\/]+$'), '');
    String inLibrary(String p) => p.startsWith(root) ? p.substring(root.length).replaceFirst(RegExp(r'^[\\/]'), '') : p;
    final rows = [
      for (final (path, trouble) in scan.files)
        if (trouble != FileTrouble.noAnswer)
          (inLibrary(path), trouble == FileTrouble.damaged ? 'damaged, or a format not read yet' : 'gone since listed'),
    ];
    return showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Left out of ${library.name}'),
        content: SizedBox(
          width: 520,
          child: ListView(shrinkWrap: true, children: [
            const Padding(padding: EdgeInsets.only(bottom: 8), child: Text(
                "Not in the app after the last scan. The files aren't touched; each comes back once it can be read.",
                style: TextStyle(fontSize: 12.5, color: hintColour))),
            for (final (name, why) in rows)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Text.rich(TextSpan(children: [
                  TextSpan(text: name),
                  TextSpan(text: '  $why', style: const TextStyle(fontSize: 12, color: hintColour)),
                ])),
              ),
          ]),
        ),
        actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Close'))],
      ),
    );
  }

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
    // browsed for (this device, a drive, a share), or typed from the browser's "Type a folder…"; then what's in it
    final lib = await pickLibrary(context);
    if (lib == null || !context.mounted) return;
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
    await api.setLibraries([for (final x in api.folders) x.id == l.id ? x.renamed(name.trim()) : x]);
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
