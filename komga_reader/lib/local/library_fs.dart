import 'dart:io';

import 'local_meta.dart' show isMetaFile;
import 'dart:typed_data';

/// A file found in a library folder: its full path (as the library's own path is written), size and date.
class FsEntry {
  const FsEntry(this.path, this.size, this.modified);
  final String path;
  final int size;
  final DateTime modified;
}

/// Why a file or folder couldn't be read - each file system tells its own errors apart ([LibraryFs.classify]).
/// - [gone]: not there (deleted, or moved since the folder was listed).
/// - [refused]: there, but this app isn't allowed to read it (a permission taken back, a share's login refused).
/// - [noAnswer]: the network, the share or the drive didn't answer - not the file's doing (a card or a USB drive taken
///   out is this too: its books are kept, not taken for deleted).
/// - [damaged]: read, but not a book this app can use (a broken or unknown archive) - or an error not known as one of
///   the others: said, not taken for a share that's away (the local libraries' review, 2026-10-26: every error not
///   recognised counted as "no answer", and kept a book that was really broken).
enum FileTrouble { gone, refused, noAnswer, damaged }

/// A file opened for reading: its parts read as they're needed, then [close]d (on a share, opening is a round trip of
/// its own - opened once for a book, not once a read: review, 2026-10-26).
abstract interface class LibraryFile {
  Future<int> length();

  /// [length] bytes from [offset] (fewer only at the end of the file).
  Future<Uint8List> readRange(int offset, int length);

  Future<void> close();
}

/// Bytes already in memory as a [LibraryFile] - an EPUB loaded whole, read with the same zip reader as the comics.
class BytesFile implements LibraryFile {
  BytesFile(this.bytes);
  final Uint8List bytes;
  @override
  Future<int> length() async => bytes.length;
  @override
  Future<Uint8List> readRange(int offset, int length) async =>
      Uint8List.sublistView(bytes, offset.clamp(0, bytes.length), (offset + length).clamp(0, bytes.length));
  @override
  Future<void> close() async {}
}

/// Where a local library's files are read from: this device's own files ([LocalFs]), and - later - a share reached
/// by the app itself. Paths are written the same way for all: a share as \\host\share\folder.
abstract interface class LibraryFs {
  /// The folder is there (and can be read).
  Future<bool> exists(String folder);

  /// [folder] isn't there ([exists] said no): does the place it was in answer - so it looks deleted, not out of
  /// reach? (A library whose folder looks deleted is asked about; one out of reach is kept.)
  Future<bool> placeAnswers(String folder);

  /// The book files under [folder] (CBZ, CBR, EPUB), at any depth - not in the system's own folders (a NAS's
  /// #recycle and @eaDir, hidden ones) and not hidden files (a Mac's ._x). A folder in it that can't be read is told
  /// to [onUnreadable] and passed over: the rest is still listed.
  Stream<FsEntry> list(String folder, {void Function(String folder, Object error)? onUnreadable});

  Future<LibraryFile> open(String path);

  /// [path]'s contents replaced by [bytes] (made if it isn't there) - written beside it first, then put in its place, so
  /// a failure part-way leaves the file as it was (metadata edits - lib/local/local_meta.dart).
  Future<void> writeWhole(String path, Uint8List bytes);

  /// A new file at [path] (one there is emptied), written in order ([LibraryOut]) - a book rewritten with its
  /// metadata in it (lib/local/zip_rewrite.dart), too big to hold whole.
  Future<LibraryOut> create(String path);

  /// [from] put in [to]'s place (the old [to] gone).
  Future<void> replace(String from, String to);

  /// [path] deleted (a rewrite's new copy that didn't check out).
  Future<void> delete(String path);

  /// A file or folder at [from] moved to [to] (renamed, or into another folder) - refused if [to] is taken (Apply edits
  /// to files - lib/local/apply_edits.dart).
  Future<void> move(String from, String to);

  /// A folder made at [path] (its parent there already); one there already is left as it is.
  Future<void> makeFolder(String path);

  /// Whether a file or folder is at [path].
  Future<bool> isThere(String path);

  /// What's directly in [folder], for the folder browser: its folders' names (sorted, the system's own left out)
  /// and how many books.
  Future<FolderLook> look(String folder);

  /// What kind of trouble [error] (thrown by this file system's reads) is.
  FileTrouble classify(Object error);
}

/// A file being written ([LibraryFs.create]): its bytes added in order, then closed.
abstract interface class LibraryOut {
  Future<void> add(Uint8List bytes);
  Future<void> close();
}

/// A whole file, through [LibraryFs.open].
Future<Uint8List> readWhole(LibraryFs fs, String path) async {
  final f = await fs.open(path);
  try {
    return await f.readRange(0, await f.length());
  } finally {
    await f.close();
  }
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

/// A file read as a book - not a hidden one (a Mac's ._x copy of a book's attributes, on a share it wrote to).
bool isBookFile(String name) {
  if (name.startsWith('.')) return false;
  final n = name.toLowerCase();
  return n.endsWith('.cbz') || n.endsWith('.cbr') || n.endsWith('.epub');
}

/// Not a system's own folder: hidden ones (.x), a NAS's (@Recycle, #recycle, @eaDir) or Windows's (\$RECYCLE.BIN,
/// System Volume Information).
bool shownFolder(String name) =>
    !name.startsWith('.') && !name.startsWith('@') && !name.startsWith('#') && !name.startsWith(r'$') &&
    name != 'System Volume Information';

/// A share's path, \\host\share\folder (or smb://host/share/folder, or Windows's long form \\?\UNC\host\share\...):
/// (host, share, the folder in it with '/'). Null for anything else - Windows's long form of a drive path (\\?\C:\x)
/// too.
(String, String, String)? splitUnc(String path) {
  var p = path.trim();
  if (p.startsWith(r'\\?\UNC\') || p.startsWith(r'\\.\UNC\')) p = r'\\' + p.substring(8);
  if (p.startsWith(r'\\?\') || p.startsWith(r'\\.\')) return null;
  final m = RegExp(r'^(?:\\\\|//|smb://)([^\\/]+)[\\/]+([^\\/]+)[\\/]*(.*)$', caseSensitive: false).firstMatch(p);
  if (m == null) return null;
  return (m[1]!, m[2]!, m[3]!.replaceAll('\\', '/').replaceAll(RegExp(r'/+$'), ''));
}

/// How a system numbers its errors: Windows's (winerror.h), Apple's (Darwin's errno), the others' (Linux's - Android).
enum FsPlatform {
  windows, apple, linux;

  static FsPlatform get current =>
      Platform.isWindows ? windows : Platform.isIOS || Platform.isMacOS ? apple : linux;
}

/// The device's own files (and, on Windows, a share by its \\host\share path - Windows reaches it itself).
class LocalFs implements LibraryFs {
  LocalFs({FsPlatform? platform}) : _platform = platform ?? FsPlatform.current;
  final FsPlatform _platform;

  @override
  Future<bool> exists(String folder) => Directory(folder).exists();

  /// The place it was in answers: the nearest folder above it that's there - but not the system's own top folders
  /// (/, /storage, /var...), which are always there: a card or USB drive taken out (/storage/1234-ABCD/Comics) would
  /// look deleted (review, 2026-10-26). A drive's top (E:\) or a share's (\\host\share) is a place of its own.
  @override
  Future<bool> placeAnswers(String folder) async {
    final unc = splitUnc(folder);
    final posix = folder.startsWith('/');
    var dir = Directory(folder.replaceAll(RegExp(r'[\\/]+$'), '')).parent;
    while (true) {
      if (unc != null && splitUnc(dir.path) == null) return false; // (above the share: \\host itself, never a folder)
      if (posix && dir.path.split('/').where((s) => s.isNotEmpty).length < 2) return false;
      if (await dir.exists()) return true;
      final up = dir.parent;
      if (up.path == dir.path) return false;
      dir = up;
    }
  }

  @override
  Stream<FsEntry> list(String folder, {void Function(String folder, Object error)? onUnreadable}) async* {
    final List<FileSystemEntity> here;
    try {
      here = await Directory(folder).list(followLinks: false).toList();
    } catch (e) {
      if (onUnreadable == null) rethrow; // (the library's own folder: the caller says what's wrong)
      onUnreadable(folder, e);
      return;
    }
    for (final e in here) {
      final name = e.path.substring(e.path.lastIndexOf(RegExp(r'[\\/]')) + 1);
      if (e is Directory) {
        if (!shownFolder(name)) continue;
        yield* list(e.path, onUnreadable: onUnreadable ?? (_, __) {});
      } else if (e is File && (isBookFile(name) || isMetaFile(name))) { // (and the metadata files - local_meta.dart)
        final s = await e.stat();
        if (s.type == FileSystemEntityType.notFound) continue; // (deleted since it was listed)
        yield FsEntry(e.path, s.size, s.modified);
      }
    }
  }

  @override
  Future<LibraryFile> open(String path) async => _LocalFile(await File(path).open());

  @override
  Future<LibraryOut> create(String path) async => _LocalOut(await File(path).open(mode: FileMode.write));

  @override
  Future<void> replace(String from, String to) => File(from).rename(to); // (over the old one: Windows too)

  @override
  Future<void> delete(String path) => File(path).delete();

  @override
  Future<void> move(String from, String to) async {
    if (await isThere(to)) throw FileSystemException('Already there', to);
    await (await FileSystemEntity.isDirectory(from) ? Directory(from).rename(to) : File(from).rename(to));
  }

  @override
  Future<void> makeFolder(String path) => Directory(path).create();

  @override
  Future<bool> isThere(String path) async => await FileSystemEntity.type(path) != FileSystemEntityType.notFound;

  @override
  Future<void> writeWhole(String path, Uint8List bytes) async {
    final temp = File('$path.bedereader-new');
    await temp.writeAsBytes(bytes, flush: true);
    try {
      await temp.rename(path); // (over the old one: Windows too)
    } catch (_) {
      await temp.delete().catchError((Object _) => temp);
      rethrow;
    }
  }

  @override
  Future<FolderLook> look(String folder) async => FolderLook.of([
        await for (final e in Directory(folder).list(followLinks: false))
          (e.path.substring(e.path.lastIndexOf(RegExp(r'[\\/]')) + 1), e is Directory),
      ]);

  // the systems' error numbers
  static const _gone = {
    FsPlatform.windows: {2, 3}, // file / path not found
    FsPlatform.apple: {2, 20}, // ENOENT, ENOTDIR
    FsPlatform.linux: {2, 20},
  };
  static const _refused = {
    // access denied, network access denied, a share's password or login refused, not signed in
    FsPlatform.windows: {5, 65, 86, 1244, 1326},
    FsPlatform.apple: {1, 13}, // EPERM, EACCES
    FsPlatform.linux: {1, 13},
  };
  static const _noAnswer = {
    // a drive not there or not ready (a USB drive taken out); a file in use elsewhere; a share by \\host\share:
    // network path not found, unexpected network error, gone, bad name, timeout, session cancelled, no network,
    // host unreachable, connection aborted, unreachable, connection doesn't exist
    FsPlatform.windows: {15, 21, 32, 53, 59, 64, 67, 121, 240, 1222, 1231, 1232, 1236, 2250},
    // ENETDOWN, ENETUNREACH, ECONNABORTED, ECONNRESET, ETIMEDOUT, ECONNREFUSED, EHOSTDOWN, EHOSTUNREACH, ESTALE
    FsPlatform.apple: {50, 51, 53, 54, 60, 61, 64, 65, 70},
    // ENODEV, ENETDOWN, ENETUNREACH, ECONNABORTED, ECONNRESET, ETIMEDOUT, ECONNREFUSED, EHOSTDOWN, EHOSTUNREACH,
    // ESTALE, ENOMEDIUM (a card taken out)
    FsPlatform.linux: {19, 100, 101, 103, 104, 110, 111, 112, 113, 116, 123},
  };

  @override
  FileTrouble classify(Object error) {
    if (error is FileSystemException) {
      final code = error.osError?.errorCode;
      if (code != null) {
        if (_gone[_platform]!.contains(code)) return FileTrouble.gone;
        if (_refused[_platform]!.contains(code)) return FileTrouble.refused;
        if (_noAnswer[_platform]!.contains(code)) return FileTrouble.noAnswer;
      }
    }
    return FileTrouble.damaged;
  }
}

class _LocalOut implements LibraryOut {
  _LocalOut(this._f);
  final RandomAccessFile _f;
  @override
  Future<void> add(Uint8List bytes) => _f.writeFrom(bytes);
  @override
  Future<void> close() async {
    await _f.flush();
    await _f.close();
  }
}

class _LocalFile implements LibraryFile {
  _LocalFile(this._f);
  final RandomAccessFile _f;

  // one thing at a time on the file: a position set then a read, not another's read in between (a book's pages are
  // measured several at a time - found 2026-10-26: a size read from another page's place)
  Future<void> _turn = Future.value();

  Future<T> _inTurn<T>(Future<T> Function() f) {
    final run = _turn.then((_) => f());
    _turn = run.then((_) {}, onError: (Object _) {});
    return run;
  }

  @override
  Future<int> length() => _inTurn(_f.length);

  @override
  Future<Uint8List> readRange(int offset, int length) => _inTurn(() => _read(offset, length));

  Future<Uint8List> _read(int offset, int length) async {
    await _f.setPosition(offset);
    final first = await _f.read(length);
    if (first.length >= length || first.isEmpty) return first;
    // (a network file system can answer with less than asked before the end: the rest asked for until the end)
    final out = BytesBuilder(copy: false)..add(first);
    while (out.length < length) {
      final more = await _f.read(length - out.length);
      if (more.isEmpty) break;
      out.add(more);
    }
    return out.takeBytes();
  }

  @override
  Future<void> close() => _inTurn(_f.close);
}
