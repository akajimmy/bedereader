import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// This device's own folders for the local libraries: Android's All files access and where its storage starts, the
/// iPad's and iPhone's own folder (the one the Files app shows under the app's name).
class DeviceFolders {
  static const _files = MethodChannel('komga_reader/files');
  static const _screen = MethodChannel('komga_reader/screen');

  /// Android: All files access is granted (elsewhere: nothing to grant).
  static Future<bool> hasAllFiles() async {
    if (defaultTargetPlatform != TargetPlatform.android) return true;
    try {
      return await _files.invokeMethod<bool>('hasAllFiles') ?? false;
    } catch (_) {
      return false;
    }
  }

  /// Android: where its own storage starts (/storage/emulated/0); null elsewhere.
  static Future<String?> storageRoot() async {
    if (defaultTargetPlatform != TargetPlatform.android) return null;
    try {
      return await _files.invokeMethod<String>('storageRoot');
    } catch (_) {
      return null;
    }
  }

  /// iOS: the app's own folder in the Files app (On My iPad > the app's name) - books copied in there by the Files
  /// app or over USB. Null elsewhere.
  static Future<String?> documents() async {
    if (defaultTargetPlatform != TargetPlatform.iOS) return null;
    try {
      return await _screen.invokeMethod<String>('documentsDir');
    } catch (_) {
      return null;
    }
  }

  /// iOS: a Comics folder in the app's own folder while that's empty - the Files app hides an empty one, so there was
  /// nowhere to copy books to (user, 2026-10-26). Only while empty: one deleted among the person's own isn't made
  /// again. [documents] for tests. Returns the folder made, or null.
  static Future<String?> makeComicsFolder({String? documents}) async {
    final docs = documents ?? await DeviceFolders.documents();
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

  /// Android: All files access, asked for until it's granted (Open Settings, then "I've allowed it"); false:
  /// cancelled. Elsewhere: nothing to grant.
  static Future<bool> allFiles(BuildContext context) async {
    if (defaultTargetPlatform != TargetPlatform.android) return true;
    while (!await hasAllFiles()) {
      if (!context.mounted) return false;
      final go = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Allow access to your files'),
          content: const Text("To read books from a folder on this device, the app needs Android's All files "
              'access. Open Settings, turn it on for BeDeReader, then come back here.'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
            TextButton(
              onPressed: () async {
                try {
                  await _files.invokeMethod('askAllFiles');
                } catch (_) {}
              },
              child: const Text('Open Settings'),
            ),
            TextButton(autofocus: true, onPressed: () => Navigator.pop(ctx, true), child: const Text("I've allowed it")),
          ],
        ),
      );
      if (go != true) return false;
    }
    return true;
  }
}

/// Where a library folder is, said plainly: the place (this device, a card or drive) and the folders within it
/// ("This Device › Comics/Saga/"). [storage]: Android's storage root; [documents]: the iOS app folder.
String wherePlainly(String path, {String? storage, String? documents}) {
  final p = path.replaceAll(RegExp(r'[\\/]+$'), '');
  String inside(String rest) => rest.isEmpty ? '' : '${rest.replaceAll('\\', '/')}/';
  final iosGuid = RegExp(r'^/(?:private/)?var/mobile/Containers/Data/Application/[^/]+/Documents/?');
  if (documents != null || iosGuid.hasMatch(p)) {
    final m = iosGuid.firstMatch(p);
    if (m != null) return 'This Device › Documents/${inside(p.substring(m.end))}';
  }
  if (storage != null && (p == storage || p.startsWith('$storage/'))) {
    return 'This Device › ${inside(p.substring(storage.length).replaceFirst(RegExp(r'^/'), ''))}';
  }
  final card = RegExp(r'^/storage/([0-9A-Fa-f]{4}-[0-9A-Fa-f]{4})/?(.*)$').firstMatch(p);
  if (card != null) return 'Card ${card[1]} › ${inside(card[2]!)}';
  return path;
}
