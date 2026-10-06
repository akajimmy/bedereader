/// A short running log of what the EPUB reader does (opened, turned, chapter laid out / let go, laid out again), written
/// to a file line by line as it happens: after a crash in Flutter's engine (build 66 on the PC: flutter_windows.dll,
/// "illegal instruction", nothing in the app's error log - user, 2026-10-06), the last lines say what led up to it.
/// Kept to the last few hundred lines; on Windows %LOCALAPPDATA%\KomgaReader\epub-trace.log.
library;

import 'dart:io';

import 'package:flutter/foundation.dart';

import '../screen.dart';

/// The reader's timing instruments - frame times ([FrameStats]), the page-change timer, the trace mirrored to the
/// system log for adb - compiled in only for a measuring build (`tools\build.ps1 -Timing`). Off in everyday builds:
/// they served the 2026-10-06 page-turn measurements, and ask Flutter for every frame's timings for no purpose
/// otherwise (user: no performance hit for something that's not serving a purpose).
const readerTiming = bool.fromEnvironment('BEDEREADER_TIMING');

class EpubTrace {
  EpubTrace._();
  static final EpubTrace instance = EpubTrace._();

  static const keep = 1000; // lines (frame timings add one a second while pages move)

  File? _file;
  IOSink? _sink; // appends on Dart's I/O thread: the UI thread never waits on the storage (see [log])
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
      _sink = f.openWrite(mode: FileMode.append);
      for (final l in _pending) {
        _write(l);
      }
      _pending.clear();
    } catch (_) {
      // no trace: nothing else depends on it
    }
  }

  /// One line, handed to the file at once and written by Dart's I/O thread moments later - not on the UI thread, where
  /// a slow write to the storage could hold up a frame (tablet, build 77: one missed refresh in the middle of each
  /// tap's turn, as the page changed and its line was written; no frame itself was slow). A crash can lose the last
  /// few milliseconds of lines. Also to the system log (Android's logcat, as "epub: ..."), which can be read over adb
  /// without the app's own files.
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
      _sink!.writeln(line);
    } catch (_) {
      // a full disk, a locked file: the reader carries on
    }
  }

  /// Whether lines go to the system log too: a measuring build only ([readerTiming]), never in tests (they'd fill the
  /// test output).
  static bool toConsole = readerTiming && (kIsWeb || !Platform.environment.containsKey('FLUTTER_TEST'));

  /// Everything logged so far is in the file (tests).
  Future<void> flush() async {
    try {
      await _sink?.flush();
    } catch (_) {
      // as with a write
    }
  }

  @visibleForTesting
  Future<void> reset() async {
    final s = _sink;
    _sink = null;
    try {
      await s?.close();
    } catch (_) {
      // nothing to close
    }
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
  int _missed = 0; // refreshes with no new frame while frames were coming (a late start, not a slow frame)
  int? _lastVsync; // the previous frame's start (µs)

  /// Adds one frame's build and raster times (ms) seen at [now]; returns the summary line when a window is over.
  /// [vsyncUs]: when the frame started (µs): a gap of 2-5 refreshes since the frame before, while pages move, is a
  /// frame that started late - missed refreshes no frame time shows (tablet, build 77: one a tap turn, every frame
  /// itself fast). Longer gaps are pages at rest.
  String? add(double buildMs, double rasterMs, DateTime now, {int? vsyncUs}) {
    _since ??= now;
    _build.add(buildMs);
    _raster.add(rasterMs);
    final last = _lastVsync;
    if (vsyncUs != null) {
      if (last != null) {
        final refreshes = ((vsyncUs - last) / 1000 / budgetMs).round();
        if (refreshes >= 2 && refreshes <= 5) _missed += refreshes - 1;
      }
      _lastVsync = vsyncUs;
    }
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
        '$slowBuild, draw $slowRaster; missed refreshes $_missed';
    _build.clear();
    _raster.clear();
    _missed = 0;
    _since = null;
    return line;
  }
}
