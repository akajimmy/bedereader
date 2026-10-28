import 'dart:typed_data';

import 'package:komga_reader/local/library_fs.dart';

/// Files held in memory, counting the opens and the reads (as a share would answer them, one round trip each).
class MemoryFs implements LibraryFs {
  MemoryFs(this.files);
  final Map<String, Uint8List> files;
  int opens = 0, reads = 0;

  @override
  Future<bool> exists(String folder) async {
    final f = folder.replaceAll(RegExp(r'[\\/]+$'), '');
    return files.keys.any((k) => k.startsWith('$f/') || k.startsWith('$f\\'));
  }

  @override
  Future<bool> placeAnswers(String folder) async => true;
  @override
  Stream<FsEntry> list(String folder, {void Function(String folder, Object error)? onUnreadable}) async* {
    for (final e in files.entries) {
      if (e.key.startsWith(folder)) yield FsEntry(e.key, e.value.length, DateTime(2026));
    }
  }

  @override
  Future<FolderLook> look(String folder) async => const FolderLook([], 0);

  @override
  Future<LibraryFile> open(String path) async {
    final f = files[path];
    if (f == null) throw StateError('no file $path');
    opens++;
    return _MemoryFile(this, f);
  }

  @override
  FileTrouble classify(Object error) =>
      error is StateError && error.message.startsWith('no file') ? FileTrouble.gone : FileTrouble.damaged;

  @override
  Future<LibraryOut> create(String path) async {
    if (readOnly) throw StateError('read-only: $path');
    return _MemoryOut(this, path);
  }

  @override
  Future<void> replace(String from, String to) async {
    files[to] = files.remove(from)!;
    written.add(to);
  }

  @override
  Future<void> delete(String path) async => files.remove(path);

  /// Folders made (a folder here is there when a file is under it, or it was made).
  final folders = <String>{};

  @override
  Future<void> move(String from, String to) async {
    if (readOnly) throw StateError('read-only: $from');
    if (await isThere(to)) throw StateError('already there: $to');
    if (files.containsKey(from)) {
      files[to] = files.remove(from)!;
    } else {
      for (final k in [...files.keys.where((k) => k.startsWith('$from/'))]) {
        files['$to${k.substring(from.length)}'] = files.remove(k)!;
      }
      if (folders.remove(from)) folders.add(to);
    }
    written.add(to);
  }

  @override
  Future<void> makeFolder(String path) async {
    if (readOnly) throw StateError('read-only: $path');
    folders.add(path);
  }

  @override
  Future<bool> isThere(String path) async =>
      files.containsKey(path) || folders.contains(path) || files.keys.any((k) => k.startsWith('$path/'));

  /// Writes done (path, in order); [readOnly]: refused.
  final written = <String>[];
  bool readOnly = false;
  @override
  Future<void> writeWhole(String path, Uint8List bytes) async {
    if (readOnly) throw StateError('read-only: $path');
    files[path] = bytes;
    written.add(path);
  }
}

class _MemoryOut implements LibraryOut {
  _MemoryOut(this.fs, this.path);
  final MemoryFs fs;
  final String path;
  final _bytes = BytesBuilder();
  @override
  Future<void> add(Uint8List bytes) async => _bytes.add(bytes);
  @override
  Future<void> close() async => fs.files[path] = _bytes.takeBytes();
}

class _MemoryFile implements LibraryFile {
  _MemoryFile(this.fs, this.bytes);
  final MemoryFs fs;
  final Uint8List bytes;

  @override
  Future<int> length() async => bytes.length;

  @override
  Future<Uint8List> readRange(int offset, int length) async {
    fs.reads++;
    return Uint8List.sublistView(bytes, offset.clamp(0, bytes.length), (offset + length).clamp(0, bytes.length));
  }

  @override
  Future<void> close() async {}
}
