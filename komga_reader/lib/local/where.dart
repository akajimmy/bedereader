import 'package:flutter/foundation.dart';

import '../screen.dart' show appDocumentsDir;
import 'access.dart';
import 'folder_scan.dart' show iosContainer;
import 'storage.dart';

/// Where a library folder is, said plainly: the place - this device, a card or drive, a server - and the folders
/// within it, ending in a slash (user, 2026-10-26: the iPad showed /var/mobile/Containers/Data/Application/{GUID}/
/// Documents/Spider-Man; they chose "On This Device" › "Documents/Spider-Man/").
class Where {
  const Where(this.place, this.inside);
  final String place;
  final String inside; // '' at the place's top

  @override
  String toString() => inside.isEmpty ? place : '$place › $inside';
}

const onThisDevice = 'On This Device';

/// [path] said plainly. [documents]: iOS's Documents folder; [storage]: Android's own storage (/storage/emulated/0).
Where whereIs(String path, {String? documents, String? storage, TargetPlatform? platform}) {
  String slashed(String s, String sep) => s.isEmpty || s.endsWith(sep) ? s : '$s$sep';
  String after(String root) => path.substring(root.length).replaceFirst(RegExp(r'^[\\/]+'), '');
  if (splitUnc(path) case (final host, final share, final rest)) {
    return Where(host, slashed(rest.isEmpty ? share : '$share/$rest', '/'));
  }
  if (path.startsWith(r'\\')) return Where(path.substring(2).split(RegExp(r'[\\/]')).first, ''); // a server
  final unix = path.replaceAll(RegExp(r'/+$'), '');
  switch (platform ?? defaultTargetPlatform) {
    case TargetPlatform.iOS:
      // under the app's folder: from Documents on ("Documents/Spider-Man/"), however its GUID is now
      final docs = documents?.replaceAll(RegExp(r'/+$'), '');
      final m = iosContainer.firstMatch(unix);
      if (m != null) return Where(onThisDevice, slashed(unix.substring(m.end), '/'));
      if (docs != null && (unix == docs || unix.startsWith('$docs/'))) {
        return Where(onThisDevice, slashed('Documents/${after(docs)}'.replaceAll(RegExp(r'/+$'), ''), '/'));
      }
    case TargetPlatform.android:
      final root = (storage ?? '/storage/emulated/0').replaceAll(RegExp(r'/+$'), '');
      if (unix == root || unix.startsWith('$root/')) return Where(onThisDevice, slashed(after(root), '/'));
      // a card or USB drive: /storage/XXXX-XXXX/...
      if (RegExp(r'^/storage/([^/]+)(?:/(.*))?$').firstMatch(unix) case final m? when m[1] != 'emulated') {
        return Where('Card or drive ${m[1]}', slashed(m[2] ?? '', '/'));
      }
    case TargetPlatform.windows:
      return Where(onThisDevice, slashed(path.replaceAll(RegExp(r'[\\/]+$'), ''), r'\'));
    default:
  }
  return Where(onThisDevice, slashed(unix, '/'));
}

/// This device's places, asked once (iOS's Documents folder, Android's storage) - for [whereHere].
class DeviceRoots {
  static String? documents;
  static String? storage;
  static bool _loaded = false;

  static Future<void> load() async {
    if (_loaded) return;
    documents = await appDocumentsDir();
    storage = await FolderAccess.storageRoot();
    _loaded = true;
  }
}

/// [path] said plainly, with this device's places ([DeviceRoots.load] first, for the iPad's and the tablet's).
Where whereHere(String path) => whereIs(path, documents: DeviceRoots.documents, storage: DeviceRoots.storage);

/// iOS: [path] moved to the app's folder as it is now - a library kept from before the app's folder changed
/// ([iosContainer]). Unchanged elsewhere, or when it isn't in the app's folder.
String reanchored(String path, String? documents) {
  if (documents == null) return path;
  final now = iosContainer.firstMatch(documents);
  final m = iosContainer.firstMatch(path);
  return now == null || m == null ? path : '${now[0]}${path.substring(m.end)}';
}
