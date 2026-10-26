import 'dart:convert';
import 'dart:io';

import 'package:dart_smb2/dart_smb2.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// A file found in a library folder: its full path (as the library's own path is written), size and date.
class FsEntry {
  const FsEntry(this.path, this.size, this.modified);
  final String path;
  final int size;
  final DateTime modified;
}

/// Where a library's files are read from (experimental/sources): this device's own files, or an SMB share reached
/// directly. Paths are written the same way for both - a share as \\host\share\folder - so a library has the same
/// path, and its books the same ids, on every device.
abstract class LibraryFs {
  /// The folder is there (and can be read).
  Future<bool> exists(String folder);

  /// [folder] isn't there ([exists] said no): does the place it was in answer - so it looks deleted, not out of
  /// reach? (user, 2026-10-25: a library whose folder looks deleted is asked about; one out of reach is kept.)
  Future<bool> placeAnswers(String folder);

  /// Every file under [folder], at any depth.
  Stream<FsEntry> list(String folder);

  Future<int> length(String path);
  Future<Uint8List> readAll(String path);

  /// [length] bytes from [offset] (fewer at the end of the file).
  Future<Uint8List> readRange(String path, int offset, int length);

  /// What's directly in [folder], for the folder browser: its folders' names (sorted, the system's own left out)
  /// and how many books.
  Future<FolderLook> look(String folder);
}

/// A folder's own folders and its count of books (CBZ, CBR, EPUB), as the folder browser shows them.
class FolderLook {
  const FolderLook(this.folders, this.books);
  final List<String> folders;
  final int books;

  /// From the names directly in a folder: ([name], is a folder).
  factory FolderLook.of(Iterable<(String, bool)> names) {
    final folders = [for (final (n, dir) in names) if (dir && shownFolder(n)) n]
      ..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
    return FolderLook(folders, names.where((e) => !e.$2 && isBookFile(e.$1)).length);
  }
}

/// A file the scan reads as a book.
bool isBookFile(String name) {
  final n = name.toLowerCase();
  return n.endsWith('.cbz') || n.endsWith('.cbr') || n.endsWith('.epub');
}

/// Shown in the folder browser: not a system's own folder - hidden ones (.x), a NAS's (@Recycle, #recycle,
/// @eaDir) or Windows's (\$RECYCLE.BIN, System Volume Information).
bool shownFolder(String name) =>
    !name.startsWith('.') && !name.startsWith('@') && !name.startsWith('#') && !name.startsWith(r'$') &&
    name != 'System Volume Information';

/// The device's own files (and, on Windows, a share by its \\host\share path - Windows reaches it itself).
class LocalFs implements LibraryFs {
  const LocalFs();

  @override
  Future<bool> exists(String folder) => Directory(folder).exists();

  /// Any folder above it is there - a drive, the device's storage, or (Windows) a share's top, \\host\share: a share
  /// out of reach has none of them (Windows says "not there" for all, not "can't reach").
  @override
  Future<bool> placeAnswers(String folder) async {
    final unc = splitUnc(folder);
    var dir = Directory(folder.replaceAll(RegExp(r'[\\/]+$'), '')).parent;
    while (true) {
      if (unc != null && splitUnc(dir.path) == null) return false; // (above the share: \\host itself, never a folder)
      if (await dir.exists()) return true;
      final up = dir.parent;
      if (up.path == dir.path) return false;
      dir = up;
    }
  }

  @override
  Stream<FsEntry> list(String folder) async* {
    await for (final e in Directory(folder).list(recursive: true, followLinks: false)) {
      if (e is! File) continue;
      final s = await e.stat();
      yield FsEntry(e.path, s.size, s.modified);
    }
  }

  @override
  Future<FolderLook> look(String folder) async => FolderLook.of([
        await for (final e in Directory(folder).list(followLinks: false))
          (e.path.substring(e.path.lastIndexOf(RegExp(r'[\\/]')) + 1), e is Directory),
      ]);

  @override
  Future<int> length(String path) => File(path).length();
  @override
  Future<Uint8List> readAll(String path) => File(path).readAsBytes();

  @override
  Future<Uint8List> readRange(String path, int offset, int length) async {
    final raf = await File(path).open();
    try {
      await raf.setPosition(offset);
      return await raf.read(length);
    } finally {
      await raf.close();
    }
  }
}

/// An SMB share reached by the app itself (Android, iOS - where the system can't open \\host\share paths): through
/// dart_smb2 (libsmb2), SMB 2 to 3.1.1. One connection pool per share, made when first needed.
class SmbFs implements LibraryFs {
  SmbFs(this.host, this.share, this.login);
  final String host, share;
  final SmbLogin? login;
  Future<Smb2Pool>? _pool;

  Future<Smb2Pool> get _connected => _pool ??= hostAddress(host)
      .then((address) => Smb2Pool.connect(host: address, share: share, user: login?.user,
          password: login?.password, domain: login?.domain, workers: 4))
      .catchError((Object e) {
        _pool = null; // (asked again next time)
        throw e;
      });

  /// \\host\share\a\b -> a/b (the path inside the share).
  String _inShare(String path) {
    final parts = splitUnc(path)!;
    return parts.$3;
  }

  String _full(String inShare) => '\\\\$host\\$share${inShare.isEmpty ? '' : '\\${inShare.replaceAll('/', '\\')}'}';

  /// (a share that can't be reached, or refuses the login, throws: that isn't "no such folder")
  @override
  Future<bool> exists(String folder) async {
    final p = _inShare(folder);
    return p.isEmpty || await (await _connected).exists(p);
  }

  /// [exists] answered (a share out of reach, or refusing, throws instead): the share is there.
  @override
  Future<bool> placeAnswers(String folder) async => true;

  @override
  Stream<FsEntry> list(String folder) async* {
    final pool = await _connected;
    final todo = [_inShare(folder)];
    while (todo.isNotEmpty) {
      final dir = todo.removeLast();
      for (final e in await pool.listDirectory(dir)) {
        if (e.name == '.' || e.name == '..') continue;
        final p = dir.isEmpty ? e.name : '$dir/${e.name}';
        if (e.isDirectory) {
          todo.add(p);
        } else if (e.isFile) {
          yield FsEntry(_full(p), e.size, e.stat.modified.toLocal());
        }
      }
    }
  }

  @override
  Future<FolderLook> look(String folder) async => FolderLook.of([
        for (final e in await (await _connected).listDirectory(_inShare(folder)))
          if (e.name != '.' && e.name != '..' && !e.stat.isHidden) (e.name, e.isDirectory),
      ]);

  @override
  Future<int> length(String path) async => (await _connected).fileSize(_inShare(path));
  @override
  Future<Uint8List> readAll(String path) async => (await _connected).readFile(_inShare(path));
  @override
  Future<Uint8List> readRange(String path, int offset, int length) async =>
      (await _connected).readFileRange(_inShare(path), offset: offset, length: length);

  Future<void> close() async => (await _pool)?.disconnect();
}

/// \\host\share\rest (or smb://host/share/rest) -> (host, share, rest with /); null if it isn't a share path.
(String, String, String)? splitUnc(String path) {
  final m = RegExp(r'^(?:\\\\|//|smb://)([^\\/]+)[\\/]+([^\\/]+)[\\/]*(.*)$', caseSensitive: false).firstMatch(path.trim());
  if (m == null) return null;
  return (m[1]!, m[2]!, m[3]!.replaceAll('\\', '/').replaceAll(RegExp(r'/+$'), ''));
}

/// Looks a host name up (tests replace it).
@visibleForTesting
Future<List<InternetAddress>> Function(String host) lookupHost = InternetAddress.lookup;

/// The address to connect to for [host]. A bare name (no dot) that DNS doesn't know is tried as name.local: the NAS
/// answers to that on the local network (mDNS), which Android and iOS look up - Windows finds the bare name that way
/// by itself, they don't (user, 2026-10-25: \\nick-nas "Can not resolve into IPv4/v6" on the tablet). Not found
/// either way: [host] as it is, for the SMB client to say so.
Future<String> hostAddress(String host) async {
  if (host.contains('.') || host.contains(':')) return host; // a full name, or an address
  for (final name in [host, '$host.local']) {
    try {
      final found = await lookupHost(name);
      if (found.isNotEmpty) {
        // IPv4 first: an IPv6 address the NAS also has may be one this device can't reach
        return found.firstWhere((a) => a.type == InternetAddressType.IPv4, orElse: () => found.first).address;
      }
    } catch (_) {
      // not found that way
    }
  }
  return host;
}

/// The folder shares in what Windows's `net view \\host /all` prints: the rows under its dashed line, of type Disk,
/// the hidden ones (ending in $) left out.
List<String> netViewShares(String output) {
  final lines = output.split(RegExp(r'\r?\n'));
  final start = lines.indexWhere((l) => l.startsWith('-----'));
  if (start < 0) return [];
  return [
    for (final l in lines.skip(start + 1))
      if (RegExp(r'^(.+?)\s+Disk(\s|$)').firstMatch(l) case final m? when !m[1]!.trim().endsWith(r'$')) m[1]!.trim(),
  ]..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
}

/// A share's user name and password (the password kept encrypted on the device).
class SmbLogin {
  const SmbLogin(this.user, this.password, {this.domain});
  final String user;
  final String password;
  final String? domain;
}

/// Which [LibraryFs] reads a library's path, and the shares' logins. On Windows every path is the system's own (a
/// share included); elsewhere a \\host\share path goes through the app's SMB client.
class Storage {
  Storage._();
  static final instance = Storage._();

  /// Tests: share paths through SMB on any platform (null: as the platform does).
  @visibleForTesting
  static bool? smbEverywhere;

  bool get _smb => smbEverywhere ?? !Platform.isWindows;

  final Map<String, SmbFs> _shares = {};
  final Map<String, SmbLogin> _logins = {};
  bool _loaded = false;
  static const _key = 'local.smbLogins';
  static const _store = FlutterSecureStorage();

  /// The share a path is on, as a key ("host\share", lower case); null: not a share.
  static String? shareOf(String path) {
    final s = splitUnc(path);
    return s == null ? null : '${s.$1}\\${s.$2}'.toLowerCase();
  }

  /// The logins kept on this device (once).
  Future<void> load() async {
    if (_loaded) return;
    _loaded = true;
    try {
      final raw = await _store.read(key: _key);
      if (raw == null) return;
      (jsonDecode(raw) as Map).forEach((k, v) => _logins[k as String] =
          SmbLogin(v['user'] as String, v['password'] as String, domain: v['domain'] as String?));
    } catch (_) {
      // none kept, or not readable: asked again
    }
  }

  SmbLogin? loginFor(String path) => switch (shareOf(path)) { final k? => _logins[k], _ => null };

  /// [path]'s share now uses [login] (kept, encrypted).
  Future<void> setLogin(String path, SmbLogin login) async {
    final k = shareOf(path);
    if (k == null) return;
    _logins[k] = login;
    await _shares.remove(k)?.close(); // (connected again with the new login)
    await _store.write(key: _key, value: jsonEncode({
      for (final e in _logins.entries)
        e.key: {'user': e.value.user, 'password': e.value.password, if (e.value.domain != null) 'domain': e.value.domain},
    }));
  }

  /// Reached through the app's SMB client (not the system).
  bool viaSmb(String path) => _smb && shareOf(path) != null;

  /// A login kept for any share on [host] (the folder browser lists a server's shares with it); null: none.
  SmbLogin? loginForHost(String host) {
    final h = '${host.toLowerCase()}\\';
    for (final e in _logins.entries) {
      if (e.key.startsWith(h)) return e.value;
    }
    return null;
  }

  /// The folder shares on [host] (its hidden ones, C$ and the like, left out). Windows asks the system (`net view`,
  /// with Windows's own login, as it reads the shares); elsewhere the app's SMB client, with [login] (null: as a
  /// guest). A refused login throws an [Smb2Exception] (elsewhere) or a [FileSystemException] (Windows).
  Future<List<String>> sharesOn(String host, SmbLogin? login) async {
    if (!_smb) {
      final r = await Process.run('net', ['view', '\\\\$host', '/all']);
      if (r.exitCode != 0) {
        throw FileSystemException('${r.stdout}${r.stderr}'.trim().replaceAll(RegExp(r'\s+'), ' '), '\\\\$host');
      }
      return netViewShares('${r.stdout}');
    }
    final shares = await Smb2Pool.listSharesOn(host: await hostAddress(host), user: login?.user,
        password: login?.password, domain: login?.domain);
    return [for (final s in shares) if (s.isDisk && !s.isHidden) s.name]
      ..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
  }

  /// Tests: the storage for a path (a share out of reach, say), in place of the real one.
  @visibleForTesting
  static LibraryFs Function(String path)? fsFor;

  LibraryFs of(String path) {
    if (fsFor case final f?) return f(path);
    if (!viaSmb(path)) return const LocalFs();
    final (host, share, _) = splitUnc(path)!;
    return _shares.putIfAbsent(shareOf(path)!, () => SmbFs(host, share, _logins[shareOf(path)]));
  }
}
