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

  static const keep = 1000; // lines (frame timings add one a second while pages move)

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

  /// One line, written now (flushed, so it's there even if the app is killed the next moment). Also to the system log
  /// (Android's logcat, as "epub: ..."), which can be read over adb without the app's own files.
  void log(String what) {
    final line = '${DateTime.now().toIso8601String()} $what';
    if (!kIsWeb && toConsole) debugPrint('epub: $what');
    if (_file == null) {
      if (_pending.length < 50) _pending.add(line);
      return;
    }
    _write(line);
  }

  void _write(String line) {
    try {
      // not flushed to the disk each line (a few times a page turn): written, it outlives the app crashing
      _file!.writeAsStringSync('$line\n', mode: FileMode.append);
    } catch (_) {
      // a full disk, a locked file: the reader carries on
    }
  }

  /// Whether lines go to the system log too (off in tests: they'd fill the test output).
  static bool toConsole = kIsWeb || !Platform.environment.containsKey('FLUTTER_TEST');

  @visibleForTesting
  void reset() {
    _file = null;
    _tried = false;
    _pending.clear();
  }
}

/// How smoothly the reader draws: frame times gathered over about a second at a time, one line each for the trace -
/// how many frames, the slowest and average time to build each (the app's own work: layout, widgets) and to draw it
/// (the GPU's), and how many missed the 60 Hz frame (16.7 ms) on either side. Only seconds with frames make a line
/// (a page at rest draws none). User, 2026-10-06: page turns "not smooth in the way that comics are".
class FrameStats {
  FrameStats({this.window = const Duration(seconds: 1)});
  final Duration window;
  static const budgetMs = 1000 / 60;

  final List<double> _build = [], _raster = [];
  DateTime? _since;

  /// Adds one frame's build and raster times (ms) seen at [now]; returns the summary line when a window is over.
  String? add(double buildMs, double rasterMs, DateTime now) {
    _since ??= now;
    _build.add(buildMs);
    _raster.add(rasterMs);
    return now.difference(_since!) >= window ? flush() : null;
  }

  /// The summary of the frames so far (null if none), and a new window.
  String? flush() {
    if (_build.isEmpty) return null;
    String part(List<double> v) {
      final avg = v.reduce((a, b) => a + b) / v.length;
      final max = v.reduce((a, b) => a > b ? a : b);
      return 'avg ${avg.toStringAsFixed(1)} max ${max.toStringAsFixed(1)} ms';
    }
    final slowBuild = _build.where((v) => v > budgetMs).length, slowRaster = _raster.where((v) => v > budgetMs).length;
    final line = 'frames ${_build.length}: build ${part(_build)}, draw ${part(_raster)}; over 16.7 ms: build '
        '$slowBuild, draw $slowRaster';
    _build.clear();
    _raster.clear();
    _since = null;
    return line;
  }
}
