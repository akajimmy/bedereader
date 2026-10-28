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
  FileTrouble classify(Object error) => FileTrouble.damaged;
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
