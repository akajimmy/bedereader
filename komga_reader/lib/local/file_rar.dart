import 'dart:async';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:koni_archive_core/koni_archive_core.dart';
import 'package:koni_rar/koni_rar.dart';

import 'file_zip.dart';
import 'library_fs.dart';

/// A CBR - a RAR archive (RAR4 or RAR5) - read in place like [FileZip]: on this device or a share, each entry's bytes
/// as they're asked for (koni_rar, pure Dart: every platform, nothing native).
///
/// RAR is decoded in Dart, a lot slower than the zlib a CBZ's pages go through (30-40 MB/s on the PC: up to 125 ms for
/// one page of the NAS's CBRs), so the decoding runs in a background isolate ([_RarWorker], one for all the CBRs open)
/// and doesn't hold up the screen. The file reads it asks for are done here, where a share's connection lives.
class FileRar extends ComicArchive {
  FileRar._(this._file, this._id, this.names);

  final LibraryFile _file;
  final int _id;
  @override
  final List<String> names;
  bool _closed = false;

  @override
  String get mediaType => 'application/x-rar-compressed';

  /// [file]: the archive, opened (closed with this).
  static Future<FileRar> open(LibraryFile file) async {
    final length = await file.length();
    final w = _RarWorker.instance;
    final id = w.nextId++;
    w.open[id] = file;
    try {
      final names = (await w.ask(['open', id, length], id) as List).cast<String>();
      return FileRar._(file, id, names);
    } catch (_) {
      w.open.remove(id);
      w.idle();
      rethrow;
    }
  }

  @override
  Future<Uint8List?> read(String name) => _read(name, null);

  @override
  Future<Uint8List?> head(String name, int bytes) => _read(name, bytes);

  Future<Uint8List?> _read(String name, int? limit) async {
    if (_closed) throw StateError('closed');
    if (!names.contains(name)) return null;
    final got = await _RarWorker.instance.ask(['read', _id, name, limit], _id);
    return (got as TransferableTypedData).materialize().asUint8List();
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _RarWorker.instance
      ..send(['close', _id])
      ..open.remove(_id)
      ..idle();
    await _file.close();
  }
}

/// The background isolate decoding the CBRs, started when the first one is opened and let go when the last is
/// closed. Messages to it: [open, n, id, length] -> the entries' names; [read, n, id, name, limit] -> the bytes;
/// [close, id]; [io, n, bytes] (a read it asked for). From it: [done, n, value], [fail, n, message],
/// [io, n, id, offset, length].
class _RarWorker {
  _RarWorker._();
  static final instance = _RarWorker._();

  int nextId = 0;
  final Map<int, LibraryFile> open = {}; // the CBRs open: their file, for the reads
  final Map<int, (Completer<Object?>, int)> _asked = {}; // questions waiting: their answer, and which CBR
  final Map<int, Object> _ioFailed = {}; // a CBR's read that failed here: the error its question gets
  int _next = 0;
  RawReceivePort? _port;
  SendPort? _to;
  Completer<void>? _started;

  /// Asks the worker; the answer (or its failure - a file read that failed comes back as it was, for the file
  /// system to classify).
  Future<Object?> ask(List<Object?> message, int id) async {
    await _start();
    final n = _next++;
    final c = Completer<Object?>();
    _asked[n] = (c, id);
    _port!.keepIsolateAlive = true;
    _to!.send([message[0], n, ...message.skip(1)]);
    return c.future;
  }

  void send(List<Object?> message) => _to?.send(message);

  Future<void> _start() async {
    if (_started != null) return _started!.future;
    final started = _started = Completer<void>();
    final port = _port = RawReceivePort(_onMessage, 'rar worker');
    try {
      await Isolate.spawn(_workerMain, port.sendPort, debugName: 'rar');
    } catch (e) {
      port.close();
      _port = null;
      _started = null;
      started.completeError(e);
      rethrow;
    }
    return started.future;
  }

  void _onMessage(Object? m) {
    if (m is SendPort) {
      _to = m;
      _started!.complete();
      return;
    }
    final msg = m as List;
    switch (msg[0]) {
      case 'io':
        unawaited(_io(msg[1] as int, msg[2] as int, msg[3] as int, msg[4] as int));
      case 'done' || 'fail':
        final (c, id) = _asked.remove(msg[1] as int)!;
        final io = _ioFailed.remove(id);
        if (msg[0] == 'done') {
          c.complete(msg[2]);
        } else {
          c.completeError(io ?? FormatException(msg[2] as String));
        }
        if (_asked.isEmpty) _port?.keepIsolateAlive = false; // (nothing waited for: the app, or a test, can end)
    }
  }

  Future<void> _io(int n, int id, int offset, int length) async {
    final file = open[id];
    try {
      if (file == null) throw StateError('closed');
      final bytes = await file.readRange(offset, length);
      _to?.send(['io', n, TransferableTypedData.fromList([bytes])]);
    } catch (e) {
      _ioFailed[id] = e;
      _to?.send(['io', n, null]);
    }
  }

  /// Nothing open: the isolate goes (started again with the next CBR).
  void idle() {
    if (open.isNotEmpty || _asked.isNotEmpty || _started == null) return;
    _to?.send(['exit']);
    _port?.close();
    _port = _to = _started = null;
  }
}

// ---- in the worker isolate ----------------------------------------------------------------------------------------

void _workerMain(SendPort toMain) {
  final readers = <int, RarReader>{};
  final reads = <int, Completer<Uint8List?>>{};
  var next = 0;
  final port = RawReceivePort();
  toMain.send(port.sendPort);

  Future<Uint8List> readRange(int id, int offset, int length) async {
    final n = next++;
    final c = reads[n] = Completer<Uint8List?>();
    toMain.send(['io', n, id, offset, length]);
    final got = await c.future;
    if (got == null) throw const FormatException('the file could not be read');
    return got;
  }

  Future<void> answer(int n, Future<Object?> Function() f) async {
    try {
      toMain.send(['done', n, await f()]);
    } catch (e) {
      // its own words (passed on as a FormatException: "FormatException: FormatException: ..." with its name in them)
      toMain.send(['fail', n, e is FormatException ? e.message : '$e']);
    }
  }

  port.handler = (Object? m) {
    final msg = m as List;
    switch (msg[0]) {
      case 'io':
        reads.remove(msg[1] as int)?.complete((msg[2] as TransferableTypedData?)?.materialize().asUint8List());
      case 'open':
        final id = msg[2] as int;
        unawaited(answer(msg[1] as int, () async {
          final source = _Proxy(msg[3] as int, (offset, length) => readRange(id, offset, length));
          final r = await const RarFormat().createReader(source, const ArchiveReadOptions()) as RarReader;
          // a file cut short lists the entries it still has headers for, the last one's data missing: damaged, left
          // out by the scan (tablet, 2026-10-25: one cut at 4 KB came in as a book whose page never loaded)
          if (r.cutShort case final cut when cut.isNotEmpty) {
            await r.close();
            throw FormatException('the file is cut short (${cut.first.path} reaches past its end)');
          }
          readers[id] = r;
          return [for (final e in r.entries) if (e.type == ArchiveEntryType.file) e.path];
        }));
      case 'read':
        final r = readers[msg[2] as int];
        final name = msg[3] as String;
        final limit = msg[4] as int?;
        unawaited(answer(msg[1] as int, () async {
          if (r == null) throw StateError('closed');
          final e = r.entries.firstWhere((e) => e.path == name);
          final Uint8List bytes;
          if (limit != null) {
            bytes = await r.readHead(e, limit);
          } else {
            final out = BytesBuilder(copy: false);
            await r.openRead(e).forEach(out.add);
            bytes = out.takeBytes();
          }
          return TransferableTypedData.fromList([bytes]);
        }));
      case 'close':
        unawaited(readers.remove(msg[1] as int)?.close());
      case 'exit':
        port.close();
        Isolate.exit();
    }
  };
}

/// The archive's bytes as koni_rar reads them: asked of the main isolate.
class _Proxy implements ByteSource {
  _Proxy(this.length, this._read);
  @override
  final int length;
  final Future<Uint8List> Function(int offset, int length) _read;
  @override
  String? get name => null;
  @override
  Future<Uint8List> read(int offset, int length) => _read(offset, length);
  @override
  Future<void> close() async {}
}
