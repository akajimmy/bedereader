/// A short running log of what the EPUB reader does (opened, turned, chapter laid out / let go, laid out again), written
/// to a file line by line as it happens: after a crash in Flutter's engine (build 66 on the PC: flutter_windows.dll,
/// "illegal instruction", nothing in the app's error log - user, 2026-10-06), the last lines say what led up to it.
/// Kept to the last few hundred lines; on Windows %LOCALAPPDATA%\KomgaReader\epub-trace.log.
library;

import 'dart:io';

import 'package:flutter/foundation.dart';

import '../screen.dart';

class EpubTrace {
  EpubTrace._();
  static final EpubTrace instance = EpubTrace._();

  static const keep = 400; // lines

  File? _file;
  bool _tried = false;
  final List<String> _pending = []; // before the file is known

  /// Opens (or starts) the trace file; lines written before land in it too. [dir]: the folder (tests; else the app's
  /// own storage folder).
  Future<void> open({String? dir}) async {
    if (_tried || kIsWeb) return;
    _tried = true;
    try {
      dir ??= await appStorageDir();
      if (dir == null) return;
      final f = File('$dir${Platform.pathSeparator}epub-trace.log');
      // trimmed to the last [keep] lines at each opening of the reader (cheap: a small file)
      if (await f.exists()) {
        final lines = await f.readAsLines();
        if (lines.length > keep) await f.writeAsString('${lines.sublist(lines.length - keep).join('\n')}\n');
      }
      _file = f;
      for (final l in _pending) {
        _write(l);
      }
      _pending.clear();
    } catch (_) {
      // no trace: nothing else depends on it
    }
  }

  /// One line, written now (flushed, so it's there even if the app is killed the next moment).
  void log(String what) {
    final line = '${DateTime.now().toIso8601String()} $what';
    if (_file == null) {
      if (_pending.length < 50) _pending.add(line);
      return;
    }
    _write(line);
  }

  void _write(String line) {
    try {
      _file!.writeAsStringSync('$line\n', mode: FileMode.append, flush: true);
    } catch (_) {
      // a full disk, a locked file: the reader carries on
    }
  }

  @visibleForTesting
  void reset() {
    _file = null;
    _tried = false;
    _pending.clear();
  }
}
