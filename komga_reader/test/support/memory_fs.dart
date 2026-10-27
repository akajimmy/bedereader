import 'dart:typed_data';

import 'package:komga_reader/local/library_fs.dart';

/// Files held in memory, counting the reads (as a share would answer them, one round trip each).
class MemoryFs implements LibraryFs {
  MemoryFs(this.files);
  final Map<String, Uint8List> files;
  int reads = 0;

  @override
  Future<bool> exists(String folder) async => files.keys.any((k) => k.startsWith(folder));
  @override
  Future<bool> placeAnswers(String folder) async => true;
  @override
  Stream<FsEntry> list(String folder) async* {
    for (final e in files.entries) {
      if (e.key.startsWith(folder)) yield FsEntry(e.key, e.value.length, DateTime(2026));
    }
  }

  @override
  Future<FolderLook> look(String folder) async => const FolderLook([], 0);

  @override
  Future<int> length(String path) async => files[path]!.length;
  @override
  Future<Uint8List> readAll(String path) async {
    reads++;
    return files[path]!;
  }

  @override
  Future<Uint8List> readRange(String path, int offset, int length) async {
    reads++;
    final f = files[path]!;
    return Uint8List.sublistView(f, offset.clamp(0, f.length), (offset + length).clamp(0, f.length));
  }

  @override
  FileTrouble classify(Object error) => FileTrouble.damaged;
}
