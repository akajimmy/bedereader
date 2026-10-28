import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dart_smb2/dart_smb2.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../local_names.dart' show hostToConnect;
import 'library_fs.dart';

/// A share's user name and password (kept encrypted on the device - [Shares]).
class SmbLogin {
  const SmbLogin(this.user, this.password, {this.domain});
  final String user;
  final String password;
  final String? domain;

  Map<String, Object?> toJson() => {'user': user, 'password': password, if (domain != null) 'domain': domain};
  factory SmbLogin.fromJson(Map j) =>
      SmbLogin(j['user'] as String, j['password'] as String, domain: j['domain'] as String?);
}

/// One entry of a share's folder.
class SmbEntry {
  const SmbEntry(this.name, {required this.folder, this.size = 0, required this.modified, this.hidden = false});
  final String name;
  final bool folder;
  final int size;
  final DateTime modified;
  final bool hidden;
}

/// A share, connected: what [SmbFs] asks of it (the app's: [_PoolShare], over dart_smb2 - tests give their own).
abstract interface class SmbShare {
  Future<List<SmbEntry>> list(String inShare);
  Future<bool> exists(String inShare);

  /// Opened for reading, with its size.
  Future<(Object handle, int size)> open(String inShare);
  Future<Uint8List> read(Object handle, int offset, int length);
  Future<void> close(Object handle);
  Future<void> disconnect();

  /// Opened for writing, emptied (made if it isn't there): written with [writeAt], let go with [close].
  Future<Object> openWrite(String inShare);
  Future<void> writeAt(Object handle, Uint8List data, int offset);

  /// [data] written as the whole of [inShare] (made if it isn't there).
  Future<void> write(String inShare, Uint8List data);
  Future<void> delete(String inShare);
  Future<void> rename(String from, String to);
  Future<void> mkdir(String inShare);
}

/// Connects to [share] on [host] (a refused login, a host out of reach: throws an [Smb2Exception]).
typedef SmbConnect = Future<SmbShare> Function(String host, String share, SmbLogin? login);

/// A share reached by the app itself (Android, iOS - they can't open \\host\share paths; Windows can, through
/// [LocalFs]): through dart_smb2 (libsmb2), SMB 2 to 3.1.1. Connected when first needed, again after a failure.
class SmbFs implements LibraryFs {
  SmbFs(this.host, this.share, this.login, {SmbConnect? connect}) : _connect = connect ?? _poolConnect;
  final String host, share;
  final SmbLogin? login;
  final SmbConnect _connect;
  Future<SmbShare>? _share;

  /// How many folders are listed at once (the pool has 4 workers; a NAS answers each listing in turn otherwise).
  static const parallel = 4;

  Future<SmbShare> get _connected => _share ??= _connect(host, share, login).catchError((Object e) {
        _share = null; // (connected again next time)
        throw e;
      });

  /// \\host\share\a\b -> a/b.
  static String _inShare(String path) => splitUnc(path)?.$3 ?? '';

  @override
  Future<bool> exists(String folder) async {
    final p = _inShare(folder);
    final s = await _connected; // (out of reach, or refused: throws - that isn't "no such folder")
    return p.isEmpty || await s.exists(p);
  }

  /// The share answers (connected); its folders may still not be there.
  @override
  Future<bool> placeAnswers(String folder) async {
    try {
      await _connected;
      return true;
    } catch (_) {
      return false;
    }
  }

  /// The book files under [folder], several folders listed at once. A folder in it that can't be listed is told to
  /// [onUnreadable] and the rest goes on; [folder] itself not listed throws when there's no [onUnreadable].
  @override
  Stream<FsEntry> list(String folder, {void Function(String folder, Object error)? onUnreadable}) {
    final out = StreamController<FsEntry>();
    final base = folder.replaceAll(RegExp(r'[\\/]+$'), ''), sep = folder.contains('\\') ? '\\' : '/';
    final root = _inShare(folder);
    String full(String inShare) {
      final rest = inShare.substring(root.length).replaceFirst(RegExp('^/'), '');
      return rest.isEmpty ? base : '$base$sep${rest.replaceAll('/', sep)}';
    }

    Future<void> run() async {
      final share = await _connected;
      final todo = [root];
      var running = 0;
      final done = Completer<void>();
      void next() {
        while (running < parallel && todo.isNotEmpty) {
          final dir = todo.removeLast();
          running++;
          share.list(dir).then((entries) {
            for (final e in entries) {
              if (e.name == '.' || e.name == '..' || e.hidden) continue;
              final p = dir.isEmpty ? e.name : '$dir/${e.name}';
              if (e.folder) {
                if (shownFolder(e.name)) todo.add(p);
              } else if (isBookFile(e.name) || isMetaFile(e.name)) { // (and the metadata files)
                out.add(FsEntry(full(p), e.size, e.modified));
              }
            }
          }, onError: (Object e) {
            if (dir == root && onUnreadable == null) {
              if (!done.isCompleted) done.completeError(e);
              return;
            }
            onUnreadable?.call(full(dir), e);
          }).whenComplete(() {
            running--;
            if (todo.isEmpty && running == 0) {
              if (!done.isCompleted) done.complete();
            } else {
              next();
            }
          });
        }
      }

      next();
      await done.future;
    }

    run().then((_) => out.close(), onError: (Object e, StackTrace s) {
      out.addError(e, s);
      out.close();
    });
    return out.stream;
  }

  @override
  Future<LibraryFile> open(String path) async {
    final share = await _connected;
    final (handle, size) = await share.open(_inShare(path));
    return _SmbFile(share, handle, size);
  }

  /// (A share can't rename over a file: the new one is written beside it, the old one deleted, the new one renamed - a
  /// failure in between leaves the new one beside it, under its temporary name.)
  @override
  Future<LibraryOut> create(String path) async {
    final share = await _connected;
    return _SmbOut(share, await share.openWrite(_inShare(path)));
  }

  @override
  Future<void> replace(String from, String to) async => _swapIn(await _connected, _inShare(from), _inShare(to));

  /// [from] put in [at]'s place. A share can't rename over a file: the old one is renamed aside first, the new one
  /// into its place, and only then is the old one deleted - at no moment is neither of them there under a name the
  /// scan reads (a failure in between leaves the old one as "...bedereader-old").
  static Future<void> _swapIn(SmbShare share, String from, String at) async {
    final aside = '$at.bedereader-old';
    final there = await share.exists(at);
    if (there) await share.rename(at, aside);
    try {
      await share.rename(from, at);
    } catch (_) {
      if (there) await share.rename(aside, at).catchError((Object _) {}); // (the old one back)
      rethrow;
    }
    if (there) await share.delete(aside);
  }

  @override
  Future<void> delete(String path) async => (await _connected).delete(_inShare(path));

  @override
  Future<void> move(String from, String to) async {
    final share = await _connected;
    if (await share.exists(_inShare(to))) throw FileSystemException('Already there', to);
    await share.rename(_inShare(from), _inShare(to));
  }

  @override
  Future<void> makeFolder(String path) async {
    final share = await _connected;
    if (!await share.exists(_inShare(path))) await share.mkdir(_inShare(path));
  }

  @override
  Future<bool> isThere(String path) async => (await _connected).exists(_inShare(path));

  /// (Written beside it, then swapped in - [_swapIn].)
  @override
  Future<void> writeWhole(String path, Uint8List bytes) async {
    final share = await _connected;
    final at = _inShare(path), temp = '$at.bedereader-new';
    await share.write(temp, bytes);
    await _swapIn(share, temp, at);
  }

  @override
  Future<FolderLook> look(String folder) async => FolderLook.of([
        for (final e in await (await _connected).list(_inShare(folder)))
          if (e.name != '.' && e.name != '..' && !e.hidden) (e.name, e.folder),
      ]);

  /// The share's own answers: not there = gone; the login or the rights refused = refused; out of reach, too slow, the
  /// file busy, the connection lost = no answer (the book kept from before); anything else = damaged.
  @override
  FileTrouble classify(Object error) => troubleOf(error);

  /// [classify], for a share's answer without a share at hand (a server's share list refused).
  static FileTrouble troubleOf(Object error) {
    if (error is! Smb2Exception) return FileTrouble.damaged;
    return switch (error.type) {
      Smb2ErrorType.notFound || Smb2ErrorType.notADirectory => FileTrouble.gone,
      Smb2ErrorType.auth || Smb2ErrorType.accessDenied => FileTrouble.refused,
      Smb2ErrorType.connection || Smb2ErrorType.timeout || Smb2ErrorType.inUse || Smb2ErrorType.state ||
      Smb2ErrorType.cancelled || Smb2ErrorType.io => FileTrouble.noAnswer,
      _ => FileTrouble.damaged,
    };
  }

  /// Let go of the connection (a new login, the app done with the share).
  Future<void> close() async {
    final s = _share;
    _share = null;
    try {
      await (await s)?.disconnect();
    } catch (_) {
      // never connected
    }
  }
}

class _SmbOut implements LibraryOut {
  _SmbOut(this._share, this._handle);
  final SmbShare _share;
  final Object _handle;
  int _at = 0;
  @override
  Future<void> add(Uint8List bytes) async {
    await _share.writeAt(_handle, bytes, _at);
    _at += bytes.length;
  }

  @override
  Future<void> close() => _share.close(_handle);
}

class _SmbFile implements LibraryFile {
  _SmbFile(this._share, this._handle, this._size);
  final SmbShare _share;
  final Object _handle;
  final int _size;

  @override
  Future<int> length() async => _size;

  /// (fewer bytes only at the end of the file, as [LocalFs]'s)
  @override
  Future<Uint8List> readRange(int offset, int length) => _share.read(_handle, offset, length);

  @override
  Future<void> close() => _share.close(_handle);
}

Future<SmbShare> _poolConnect(String host, String share, SmbLogin? login) async {
  final pool = await Smb2Pool.connect(host: await hostToConnect(host), share: share, user: login?.user,
      password: login?.password, domain: login?.domain, workers: SmbFs.parallel);
  return _PoolShare(pool);
}

class _PoolShare implements SmbShare {
  _PoolShare(this._pool);
  final Smb2Pool _pool;

  @override
  Future<List<SmbEntry>> list(String inShare) async => [
        for (final e in await _pool.listDirectory(inShare))
          SmbEntry(e.name, folder: e.isDirectory, size: e.size, modified: e.stat.modified.toUtc(),
              hidden: e.stat.isHidden),
      ];

  @override
  Future<bool> exists(String inShare) => _pool.exists(inShare);

  @override
  Future<(Object, int)> open(String inShare) async => await _pool.openFileWithSize(inShare);

  @override
  Future<Uint8List> read(Object handle, int offset, int length) =>
      _pool.readFromHandle(handle as Smb2PoolHandle, offset: offset, length: length);

  @override
  Future<void> close(Object handle) => _pool.closeHandle(handle as Smb2PoolHandle);

  @override
  Future<void> disconnect() => _pool.disconnect();
  @override
  Future<void> write(String inShare, Uint8List data) => _pool.writeFile(inShare, data);
  @override
  Future<Object> openWrite(String inShare) => _pool.openFileWrite(inShare, truncate: true);
  @override
  Future<void> writeAt(Object handle, Uint8List data, int offset) =>
      _pool.writeToHandle(handle as Smb2PoolHandle, data, offset: offset);
  @override
  Future<void> delete(String inShare) => _pool.deleteFile(inShare);
  @override
  Future<void> rename(String from, String to) => _pool.rename(from, to);
  @override
  Future<void> mkdir(String inShare) => _pool.mkdir(inShare);
}

/// The shares: which [LibraryFs] reads a library's path, and their logins. On Windows every path is the system's own -
/// a share's too, with Windows's own login; elsewhere a \\host\share path goes through the app's SMB client, with the
/// login kept here for its share.
class Shares {
  Shares({@visibleForTesting bool? viaApp, @visibleForTesting SmbConnect? connect,
      @visibleForTesting FlutterSecureStorage? storage})
      : _viaApp = viaApp ?? !Platform.isWindows,
        _connect = connect,
        _storage = storage ?? const FlutterSecureStorage();
  static final instance = Shares();

  final bool _viaApp;
  final SmbConnect? _connect;
  final FlutterSecureStorage _storage;
  final Map<String, SmbFs> _open = {};
  final Map<String, SmbLogin> _logins = {};
  static const _key = 'local.smbLogins';
  final _localFs = LocalFs();

  /// Share paths go through the app's SMB client here (not Windows).
  bool get viaApp => _viaApp;

  /// Before a share's connection is replaced (a new login): what holds files open through it lets them go (the app:
  /// the local libraries' open books - main.dart).
  Future<void> Function()? beforeReconnect;

  /// The share [path] is on, as a key (host\share, lower case - the NAS doesn't tell case apart); null: not a share.
  static String? shareOf(String path) {
    final s = splitUnc(path);
    return s == null ? null : '${s.$1}\\${s.$2}'.toLowerCase();
  }

  /// The logins kept on this device.
  Future<void> load() async {
    try {
      final raw = await _storage.read(key: _key);
      if (raw == null) return;
      (jsonDecode(raw) as Map).forEach((k, v) => _logins[k as String] = SmbLogin.fromJson(v as Map));
    } catch (_) {
      // none, or not readable (the keystore reset): asked again
    }
  }

  SmbLogin? loginFor(String path) => switch (shareOf(path)) { final k? => _logins[k], _ => null };

  /// A login kept for any share on [host] (to list its shares with); null: none.
  SmbLogin? loginForHost(String host) {
    final h = '${host.toLowerCase()}\\';
    for (final e in _logins.entries) {
      if (e.key.startsWith(h)) return e.value;
    }
    return null;
  }

  /// [path]'s share now uses [login] (null: none - as a guest), kept encrypted; connected again with it.
  Future<void> setLogin(String path, SmbLogin? login) async {
    final k = shareOf(path);
    if (k == null) return;
    login == null ? _logins.remove(k) : _logins[k] = login;
    final old = _open.remove(k);
    if (old != null) {
      // the files open through the old connection let go first (a book open on it lost its pages - the review,
      // 2026-10-26): opened again through the new one when next read
      await beforeReconnect?.call();
      await old.close();
    }
    await _storage.write(key: _key, value: jsonEncode({for (final e in _logins.entries) e.key: e.value.toJson()}));
  }

  /// Where [path]'s files are read from.
  LibraryFs fsFor(String path) {
    final k = shareOf(path);
    if (!_viaApp || k == null) return _localFs;
    final (host, share, _) = splitUnc(path)!;
    return _open.putIfAbsent(k, () => SmbFs(host, share, _logins[k], connect: _connect));
  }

  /// The folder shares on [host], hidden ones (C$ and the like) left out, in name order. Windows asks the system
  /// (`net view`, with Windows's own login); elsewhere the app's SMB client with [login] (null: as a guest). A refused
  /// login throws.
  Future<List<String>> sharesOn(String host, SmbLogin? login) async {
    final List<String> names;
    if (!_viaApp) {
      final r = await Process.run('net', ['view', '\\\\$host', '/all']);
      if (r.exitCode != 0) {
        throw FileSystemException('${r.stdout}${r.stderr}'.trim().replaceAll(RegExp(r'\s+'), ' '), '\\\\$host');
      }
      names = netViewShares('${r.stdout}');
    } else {
      final found = await Smb2Pool.listSharesOn(host: await hostToConnect(host), user: login?.user,
          password: login?.password, domain: login?.domain);
      names = [for (final s in found) if (s.isDisk && !s.isHidden) s.name];
    }
    return names..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
  }

  /// Every share's connection let go (the app leaving).
  Future<void> closeAll() async {
    final open = [..._open.values];
    _open.clear();
    for (final s in open) {
      await s.close();
    }
  }
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
  ];
}
