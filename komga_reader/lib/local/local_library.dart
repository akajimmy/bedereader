import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import 'book_names.dart' show localLibraryId;

/// A local library: a folder on this device (later: a share it can reach), its books one folder per series.
class LocalLibrary {
  const LocalLibrary(this.name, this.path);
  final String name;
  final String path;

  /// Stable for the folder: progress kept under it survives a rescan, a restart or the library added again.
  String get id => localLibraryId(path);

  /// The same library under another name.
  LocalLibrary renamed(String to) => LocalLibrary(to, path);

  Map<String, Object?> toJson() => {'name': name, 'path': path};
  factory LocalLibrary.fromJson(Map j) => LocalLibrary(j['name'] as String, j['path'] as String);

  /// A library for [path], named after its folder.
  factory LocalLibrary.at(String path) {
    final clean = path.trim().replaceAll(RegExp(r'[\\/]+$'), '');
    return LocalLibrary(clean.split(RegExp(r'[\\/]')).last, clean);
  }

  @override
  bool operator ==(Object other) => other is LocalLibrary && other.name == name && other.path == path;
  @override
  int get hashCode => Object.hash(name, path);
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
