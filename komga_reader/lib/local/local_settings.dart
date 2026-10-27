import 'package:flutter/material.dart';

import '../screens/actions.dart' show askName;
import '../widgets/setting_rows.dart';
import 'device_folders.dart';
import 'folder_browser.dart';
import 'library_fs.dart';
import 'local_library.dart';
import 'local_scan.dart';
import 'local_source.dart';

/// Settings > Libraries: the local libraries - each with where it is and what its last scan couldn't read, Rename and
/// Remove - and Add a folder; Scan again with how far a scan has got.
class LocalLibrariesGroup extends StatefulWidget {
  const LocalLibrariesGroup({super.key, required this.local, this.browse});
  final LocalSource local;

  /// Where Add a folder browses (tests give their own).
  final BrowseSource? browse;

  @override
  State<LocalLibrariesGroup> createState() => _LocalLibrariesGroupState();
}

class _LocalLibrariesGroupState extends State<LocalLibrariesGroup> {
  String? _storage, _documents; // (for saying where a folder is)

  @override
  void initState() {
    super.initState();
    DeviceFolders.storageRoot().then((s) => DeviceFolders.documents().then((d) {
          if (mounted) {
            setState(() {
              _storage = s;
              _documents = d;
            });
          }
        }));
  }

  LocalSource get _local => widget.local;

  Future<void> _add() async {
    final path = await pickFolder(context, source: widget.browse);
    if (path == null || !mounted) return;
    final library = LocalLibrary.at(path);
    if (_local.folders.any((l) => l.id == library.id)) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('That folder is a library already')));
      return;
    }
    await _local.setLibraries([..._local.folders, library]);
  }

  Future<void> _rename(LocalLibrary l) async {
    final name = await askName(context, title: 'Rename library', label: 'Name', initial: l.name, action: 'Rename');
    if (name == null || name == l.name) return;
    await _local.setLibraries([for (final x in _local.folders) x.id == l.id ? x.renamed(name) : x]);
  }

  Future<void> _remove(LocalLibrary l) async {
    final yes = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Remove ${l.name}?'),
        content: const Text('It goes from the app only - its files stay where they are. Adding the folder again '
            'brings it back, with its reading progress.'),
        actions: [
          TextButton(autofocus: true, onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Remove')),
        ],
      ),
    );
    if (yes == true) await _local.setLibraries([for (final x in _local.folders) if (x.id != l.id) x]);
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: _local.changed,
        builder: (context, _) => SettingsGroup(title: 'Local', children: [
          for (final l in _local.folders)
            ListTile(
              contentPadding: const EdgeInsets.only(left: 14, right: 4),
              leading: const Icon(Icons.folder_outlined),
              title: Text(l.name, style: const TextStyle(fontSize: 14.5)),
              subtitle: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(wherePlainly(l.path, storage: _storage, documents: _documents),
                    style: const TextStyle(fontSize: 12, color: hintColour)),
                if (_said(_local.lastScan[l.id]) case final s?)
                  Text(s, style: const TextStyle(fontSize: 12, color: Color(0xFFFACC15))),
              ]),
              trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                IconButton(tooltip: 'Rename', icon: const Icon(Icons.edit_outlined), onPressed: () => _rename(l)),
                IconButton(tooltip: 'Remove', icon: const Icon(Icons.delete_outline), onPressed: () => _remove(l)),
              ]),
            ),
          ActionRow(title: 'Add a folder', subtitle: 'On this device, or a card or drive in it', icon: Icons.add,
              onTap: _add),
          LibraryScanRow(local: _local),
        ]),
      );

  /// What the last scan couldn't read, in a line; null: nothing to say.
  static String? _said(LibraryScan? r) {
    if (r == null || r.clean) return null;
    if (!r.reached) {
      return r.missing
          ? 'Not found on the last scan (it looks deleted) - its books are from the scan before'
          : "Couldn't be reached on the last scan - its books are from the scan before";
    }
    final parts = [
      if (r.count(FileTrouble.noAnswer) + r.count(FileTrouble.refused) case final k when k > 0)
        "$k couldn't be read just then (kept from the scan before)",
      if (r.count(FileTrouble.damaged) case final k when k > 0) '$k damaged or not readable yet (left out)',
      if (r.count(FileTrouble.gone) case final k when k > 0) '$k gone since the folder was listed (left out)',
    ];
    return "${r.files.length} file${r.files.length == 1 ? '' : 's'} couldn't be read - ${parts.join('; ')}";
  }
}

/// Scan again, with how far a scan running has got.
class LibraryScanRow extends StatelessWidget {
  const LibraryScanRow({super.key, required this.local});
  final LocalSource local;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: Listenable.merge([local.scanning, local.found]),
        builder: (context, _) {
          final scanned = local.scanning.value, found = local.found.value;
          return ActionRow(
            title: scanned == null
                ? 'Scan again'
                : found != null
                    ? 'Looking through folders… $found found'
                    : 'Scanning… $scanned books',
            subtitle: 'New and changed files are read; books whose files went are taken off',
            icon: Icons.refresh,
            onTap: scanned == null ? () => local.rescan() : null,
          );
        },
      );
}

/// A library whose folder looks deleted (not there, while the place it was in answers): Remove it, or Keep it (its
/// books stay, as for one out of reach - the folder may come back).
Future<void> askAboutMissing(BuildContext context, LocalSource local) async {
  for (final l in [...local.missing.value]) {
    if (!context.mounted) return;
    final remove = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('${l.name} not found'),
        content: Text("Its folder isn't there any more:\n${l.path}\n\nRemove the library, or keep it in case the "
            'folder comes back?'),
        actions: [
          TextButton(autofocus: true, onPressed: () => Navigator.pop(ctx, false), child: const Text('Keep it')),
          TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Remove')),
        ],
      ),
    );
    if (remove == true) await local.setLibraries([for (final x in local.folders) if (x.id != l.id) x]);
  }
  local.missing.value = const [];
}
