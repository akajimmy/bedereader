import 'package:flutter/material.dart';

import 'folder_komga.dart';
import 'where.dart';

/// A local library whose folder looks deleted - not there, while the place it was in answers (user, 2026-10-25):
/// asked once - remove it, or keep it as out of reach (not asked again; read again once the folder is back). Each
/// library in [FolderKomga.toAsk], one after the other.
Future<void> askAboutMissing(BuildContext context, FolderKomga api) async {
  while (api.toAsk.value.isNotEmpty) {
    if (!context.mounted) return;
    final library = api.toAsk.value.first;
    final remove = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        title: const Text('Library folder not found'),
        content: Text('The folder of the library "${library.name}" isn\'t there any more:\n\n${whereHere(library.path)}\n\n'
            'Remove the library? Keep it if the folder will be back - a drive or a share renamed, say: it\'s read '
            'again once it\'s there.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Keep it')),
          TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Remove')),
        ],
      ),
    );
    if (!context.mounted) return;
    await (remove == true ? api.removeMissing(library) : api.keepMissing(library));
  }
}
