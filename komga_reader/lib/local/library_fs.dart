import 'dart:io';

import 'package:flutter/foundation.dart';

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
/// - [noAnswer]: the network or the share didn't answer - not the file's doing.
/// - [damaged]: read, but not a book this app can use (a broken or unknown archive) - or an error not known as one of
///   the others: said, not taken for a share that's away (the local libraries' review, 2026-10-26: every error not
///   recognised counted as "no answer", and kept a book that was really broken).
enum FileTrouble { gone, refused, noAnswer, damaged }

/// Where a local library's files are read from: this device's own files ([LocalFs]), and - later - a share reached
/// by the app itself. Paths are written the same way for all: a share as \\host\share\folder.
abstract interface class LibraryFs {
  /// The folder is there (and can be read).
  Future<bool> exists(String folder);

  /// [folder] isn't there ([exists] said no): does the place it was in answer - so it looks deleted, not out of
  /// reach? (A library whose folder looks deleted is asked about; one out of reach is kept.)
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

  /// What kind of trouble [error] (thrown by this file system's reads) is.
  FileTrouble classify(Object error);
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

/// A file read as a book.
bool isBookFile(String name) {
  final n = name.toLowerCase();
  return n.endsWith('.cbz') || n.endsWith('.cbr') || n.endsWith('.epub');
}

/// Not a system's own folder: hidden ones (.x), a NAS's (@Recycle, #recycle, @eaDir) or Windows's (\$RECYCLE.BIN,
/// System Volume Information).
bool shownFolder(String name) =>
    !name.startsWith('.') && !name.startsWith('@') && !name.startsWith('#') && !name.startsWith(r'$') &&
    name != 'System Volume Information';

/// A share's path, \\host\share\folder (or smb://host/share/folder): (host, share, the folder in it with '/').
/// Null for anything else.
(String, String, String)? splitUnc(String path) {
  final m = RegExp(r'^(?:\\\\|//|smb://)([^\\/]+)[\\/]+([^\\/]+)[\\/]*(.*)$', caseSensitive: false).firstMatch(path.trim());
  if (m == null) return null;
  return (m[1]!, m[2]!, m[3]!.replaceAll('\\', '/').replaceAll(RegExp(r'/+$'), ''));
}

/// The device's own files (and, on Windows, a share by its \\host\share path - Windows reaches it itself).
class LocalFs implements LibraryFs {
  /// [windows]: tell the errors apart as Windows numbers them (else as Android, iOS and the rest do).
  LocalFs({bool? windows}) : _windows = windows ?? Platform.isWindows;
  final bool _windows;

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

  // the system's error numbers: Windows's (winerror.h) and the others' (errno)
  static const _winGone = {2, 3}; // file / path not found
  static const _winRefused = {5}; // access denied
  // a share by \\host\share: network path not found, gone, bad name, unexpected network error, timeout, unreachable;
  // a file in use elsewhere (32: sharing violation) - there, just not now
  static const _winNoAnswer = {32, 53, 59, 64, 67, 121, 1231};
  static const _posixGone = {2, 20}; // ENOENT, ENOTDIR
  static const _posixRefused = {1, 13}; // EPERM, EACCES
  static const _posixNoAnswer = {101, 110, 112, 113}; // ENETUNREACH, ETIMEDOUT, EHOSTDOWN, EHOSTUNREACH

  @override
  FileTrouble classify(Object error) {
    if (error is FileSystemException) {
      final code = error.osError?.errorCode;
      if (code != null) {
        if ((_windows ? _winGone : _posixGone).contains(code)) return FileTrouble.gone;
        if ((_windows ? _winRefused : _posixRefused).contains(code)) return FileTrouble.refused;
        if ((_windows ? _winNoAnswer : _posixNoAnswer).contains(code)) return FileTrouble.noAnswer;
      }
    }
    return FileTrouble.damaged;
  }
}
