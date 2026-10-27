import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import 'book_names.dart' show localLibraryId, localReadListId;

/// What a library folder holds (chosen when it's added).
enum LibraryKind {
  /// One folder per series (a book loose in the library, or in _oneshots: a book of its own).
  seriesFolders,

  /// Books of one series: every book in the folder and its subfolders, folder by folder.
  oneSeries,

  /// Books of several series, in an order: a read list named after the library, the books in it by path ("001 - "
  /// first); each book's series from its ComicInfo, else its file name.
  readList,
}

/// A local library: a folder on this device or a share, holding its books as [kind] says.
class LocalLibrary {
  const LocalLibrary(this.name, this.path, {this.kind = LibraryKind.seriesFolders});
  final String name;
  final String path;
  final LibraryKind kind;

  /// Stable for the folder: progress kept under it survives a rescan, a restart or the library added again.
  String get id => localLibraryId(path);

  /// A read-list library's read list.
  String get readListId => localReadListId(path);

  /// The same library under another name.
  LocalLibrary renamed(String to) => LocalLibrary(to, path, kind: kind);

  Map<String, Object?> toJson() => {'name': name, 'path': path, if (kind != LibraryKind.seriesFolders) 'kind': kind.name};
  factory LocalLibrary.fromJson(Map j) => LocalLibrary(j['name'] as String, j['path'] as String,
      kind: LibraryKind.values.asNameMap()[j['kind']] ?? LibraryKind.seriesFolders);

  /// A library for [path], named after its folder.
  factory LocalLibrary.at(String path, {LibraryKind kind = LibraryKind.seriesFolders}) {
    final clean = path.trim().replaceAll(RegExp(r'[\\/]+$'), '');
    return LocalLibrary(clean.split(RegExp(r'[\\/]')).last, clean, kind: kind);
  }

  @override
  bool operator ==(Object other) =>
      other is LocalLibrary && other.name == name && other.path == path && other.kind == kind;
  @override
  int get hashCode => Object.hash(name, path, kind);
}

/// The local libraries kept on this device (in the app's settings - this device's own, never synced).
class LocalLibraries {
  static const _key = 'local.libraries';

  static Future<List<LocalLibrary>> load() async {
    final raw = (await SharedPreferences.getInstance()).getString(_key);
    if (raw == null) return const [];
    try {
      return [for (final j in jsonDecode(raw) as List) LocalLibrary.fromJson(j as Map)];
    } catch (_) {
      return const [];
    }
  }

  static Future<void> save(List<LocalLibrary> libraries) async =>
      (await SharedPreferences.getInstance()).setString(_key, jsonEncode([for (final l in libraries) l.toJson()]));
}

/// No server mode: the app on the local libraries alone, without Komga - a setting of its own (the experiment kept a
/// 'local' server address instead, and a second key to remember Komga's through it). This device's own.
class NoServerMode {
  static const _key = 'local.noServer';

  static Future<bool> load() async => (await SharedPreferences.getInstance()).getBool(_key) ?? false;

  static Future<void> save(bool on) async {
    final p = await SharedPreferences.getInstance();
    on ? await p.setBool(_key, true) : await p.remove(_key);
  }
}
