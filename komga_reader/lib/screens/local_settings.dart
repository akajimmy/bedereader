import 'package:flutter/material.dart';

import 'actions.dart' show askName;
import '../widgets/setting_rows.dart';
import '../local/device_folders.dart';
import 'folder_browser.dart';
import '../local/library_fs.dart';
import '../local/local_library.dart';
import '../local/local_scan.dart';
import '../local/local_source.dart';
import 'share_access.dart';
import '../local/smb_fs.dart';

/// Settings > Libraries: the local libraries - each with where it is and what its last scan couldn't read, Rename and
/// Remove - and Add a folder; Scan again with how far a scan has got.
///
/// [network]: the libraries on a share instead (the Network group: Add a shared folder, and each one's Sign in).
class LocalLibrariesGroup extends StatefulWidget {
  const LocalLibrariesGroup({super.key, required this.local, this.browse, this.network = false, this.shares});
  final LocalSource local;

  /// Where Add a folder browses (tests give their own).
  final BrowseSource? browse;
  final bool network;

  /// The shares' logins (tests give their own).
  final Shares? shares;

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
  Shares get _shares => widget.shares ?? Shares.instance;

  /// This group's libraries: on a share ([LocalLibrariesGroup.network]) or not.
  Iterable<LocalLibrary> get _mine => _local.folders.where((l) => (Shares.shareOf(l.path) != null) == widget.network);

  Future<void> _add() async {
    final library = await pickLibrary(context, source: widget.browse ??
        (widget.network ? NetworkBrowse(known: [for (final l in _local.folders) l.path], shares: _shares) : null));
    if (library == null || !mounted) return;
    if (_local.folders.any((l) => l.id == library.id)) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('That folder is a library already')));
      return;
    }
    // a share: reached first (its login asked for if it refuses one)
    if (!await ensureShare(context, library.path, shares: _shares) || !mounted) return;
    await _local.setLibraries([..._local.folders, library]);
  }

  /// A share's login, changed: kept, and the libraries scanned again with it.
  Future<void> _signIn(LocalLibrary l) async {
    final (host, share, _) = splitUnc(l.path)!;
    final login = await askShareLogin(context, '\\\\$host\\$share', was: _shares.loginFor(l.path));
    if (login == null) return;
    await _shares.setLogin(l.path, login);
    await _local.rescan();
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
        builder: (context, _) => SettingsGroup(title: widget.network ? 'Network' : 'Local', children: [
          for (final l in _mine)
            ListTile(
              contentPadding: const EdgeInsets.only(left: 14, right: 4),
              leading: const Icon(Icons.folder_outlined),
              title: Text(l.name, style: const TextStyle(fontSize: 14.5)),
              subtitle: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(wherePlainly(l.path, storage: _storage, documents: _documents),
                    style: const TextStyle(fontSize: 12, color: hintColour)),
                if (l.kind != LibraryKind.seriesFolders) // (what's in it, as said when it was added)
                  Text(libraryKindLabel(l.kind), style: const TextStyle(fontSize: 12, color: hintColour)),
                if (_said(_local.lastScan[l.id]) case final s?)
                  Text(s, style: const TextStyle(fontSize: 12, color: Color(0xFFFACC15))),
              ]),
              trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                if (widget.network && _shares.viaApp) // (Windows signs in to a share itself)
                  IconButton(tooltip: 'Sign in', icon: const Icon(Icons.key_outlined), onPressed: () => _signIn(l)),
                IconButton(tooltip: 'Rename', icon: const Icon(Icons.edit_outlined), onPressed: () => _rename(l)),
                IconButton(tooltip: 'Remove', icon: const Icon(Icons.delete_outline), onPressed: () => _remove(l)),
              ]),
            ),
          widget.network
              ? ActionRow(title: 'Add a shared folder', subtitle: 'On a server on your network (SMB)', icon: Icons.add,
                  onTap: _add)
              : ActionRow(title: 'Add a folder', subtitle: 'On this device, or a card or drive in it', icon: Icons.add,
                  onTap: _add),
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
