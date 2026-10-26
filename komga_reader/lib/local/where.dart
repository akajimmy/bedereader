import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../screen.dart' show appDocumentsDir;
import '../widgets/source_badge.dart' show BookSource, SourceIcon;
import 'access.dart';
import 'folder_scan.dart' show iosContainer;
import 'storage.dart';

/// Where a library folder is, said plainly: the place - this device, a card or drive, a server - and the folders
/// within it, ending in a slash (user, 2026-10-26: the iPad showed /var/mobile/Containers/Data/Application/{GUID}/
/// Documents/Spider-Man; they chose "On This Device" › "Documents/Spider-Man/" - later "This Device", after an icon
/// of the place: [WhereLine]).
class Where {
  const Where(this.place, this.inside, [this.kind = WhereKind.device]);
  final String place;
  final String inside; // '' at the place's top
  final WhereKind kind;

  @override
  String toString() => inside.isEmpty ? place : '$place › $inside';
}

/// The kind of place, for its icon ([WhereLine]).
enum WhereKind { device, card, server }

const onThisDevice = 'This Device';

/// [path] said plainly. [documents]: iOS's Documents folder; [storage]: Android's own storage (/storage/emulated/0).
Where whereIs(String path, {String? documents, String? storage, TargetPlatform? platform}) {
  String slashed(String s, String sep) => s.isEmpty || s.endsWith(sep) ? s : '$s$sep';
  String after(String root) => path.substring(root.length).replaceFirst(RegExp(r'^[\\/]+'), '');
  if (splitUnc(path) case (final host, final share, final rest)) {
    return Where(host, slashed(rest.isEmpty ? share : '$share/$rest', '/'), WhereKind.server);
  }
  if (path.startsWith(r'\\')) {
    return Where(path.substring(2).split(RegExp(r'[\\/]')).first, '', WhereKind.server); // a server
  }
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
        return Where('Card or drive ${m[1]}', slashed(m[2] ?? '', '/'), WhereKind.card);
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

/// iOS: a Comics folder in the app's own folder while that's empty - the Files app hides an empty one, so there was
/// nowhere to copy books to (user, 2026-10-26). Only while empty: one deleted among the person's own isn't made again.
/// [documents] for tests (else iOS's, [appDocumentsDir]). Returns the folder made, or null.
Future<String?> makeComicsFolder({String? documents}) async {
  final docs = documents ?? await appDocumentsDir();
  if (docs == null) return null;
  try {
    final dir = Directory(docs);
    if (!await dir.exists()) return null;
    await for (final e in dir.list()) {
      if (!e.path.split(RegExp(r'[\\/]')).last.startsWith('.')) return null; // not empty (.DS_Store and such aside)
    }
    final made = Directory('$docs${Platform.pathSeparator}Comics');
    await made.create();
    return made.path;
  } catch (_) {
    return null; // (tried again at the next start)
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

/// [path] said plainly after its place's icon: a network folder for a share, this device's own (a tablet, a phone, a
/// computer) for its storage, a card for a card or USB drive (user, 2026-10-26).
class WhereLine extends StatelessWidget {
  const WhereLine(this.path, {super.key, this.style});
  final String path;
  final TextStyle? style;

  @override
  Widget build(BuildContext context) {
    final where = whereHere(path);
    final style = this.style ?? DefaultTextStyle.of(context).style;
    final size = (style.fontSize ?? 14) * 1.25;
    final colour = style.color;
    final Widget icon = switch (where.kind) {
      WhereKind.server => SourceIcon(BookSource.network, size: size, colour: colour),
      WhereKind.card => Icon(Icons.sd_card_outlined, size: size, color: colour),
      WhereKind.device => Icon(deviceIcon(context), size: size, color: colour),
    };
    return Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Padding(padding: const EdgeInsets.only(right: 6), child: icon),
      Flexible(child: Text('$where', style: style)),
    ]);
  }
}

/// This device's icon: a tablet or a phone (by the screen's shorter side, 600 and up a tablet), else a computer.
IconData deviceIcon(BuildContext context) {
  final tablet = MediaQuery.sizeOf(context).shortestSide >= 600;
  return switch (defaultTargetPlatform) {
    TargetPlatform.iOS => tablet ? Icons.tablet_mac : Icons.phone_iphone,
    TargetPlatform.android => tablet ? Icons.tablet_android : Icons.smartphone,
    _ => Icons.computer,
  };
}
