import 'dart:io';

import 'package:flutter/scheduler.dart';

import 'screen.dart' show appStorageDir;

/// Measuring the page curl (experimental/sources, user 2026-10-24: "the page curl is lagging in the experimental branch
/// in a way that it's not in the main branch"): every frame drawn while a curl is on screen (build and raster times),
/// and every page loaded meanwhile (reading its file, decoding it), written to perf.log in the app's storage
/// (%LOCALAPPDATA%\KomgaReaderExp\perf.log). Each curl ends with a summary line.
class PerfLog {
  PerfLog._();
  static final instance = PerfLog._();

  final List<String> _lines = [];
  final List<FrameTiming> _frames = [];
  String? _curl; // the curl on screen: what it is, where its pages come from
  DateTime? _since;
  bool _listening = false;

  void _listen() {
    if (_listening) return;
    _listening = true;
    SchedulerBinding.instance.addTimingsCallback((timings) {
      if (_curl != null) _frames.addAll(timings);
    });
  }

  /// A curl started ([what]: forward or back, and the source).
  void curlStarted(String what) {
    _listen();
    _curl = what;
    _since = DateTime.now();
    _frames.clear();
    _lines.add('${_time()} curl start: $what');
  }

  /// The curl is over: its frames summed up.
  void curlEnded() {
    final what = _curl;
    if (what == null) return;
    _curl = null;
    double ms(Duration d) => d.inMicroseconds / 1000;
    final build = [for (final f in _frames) ms(f.buildDuration)];
    final raster = [for (final f in _frames) ms(f.rasterDuration)];
    final total = [for (final f in _frames) ms(f.totalSpan)];
    String stats(List<double> v) {
      if (v.isEmpty) return '-';
      final s = List.of(v)..sort();
      return 'avg ${(v.reduce((a, b) => a + b) / v.length).toStringAsFixed(1)} '
          'p90 ${s[(s.length * 0.9).floor().clamp(0, s.length - 1)].toStringAsFixed(1)} max ${s.last.toStringAsFixed(1)}';
    }

    final slow = total.where((t) => t > 16.7).length;
    _lines.add('${_time()} curl end: $what - ${_frames.length} frames in '
        '${DateTime.now().difference(_since!).inMilliseconds} ms, $slow over 16.7 ms; build ${stats(build)}; '
        'raster ${stats(raster)}; total ${stats(total)}');
    _flush();
  }

  /// A page loaded: how long reading its bytes and decoding them took (during a curl or not).
  void page(String book, int page, {required int readMs, required int decodeMs, required int bytes}) {
    _lines.add('${_time()} page $book p$page: read $readMs ms, decode $decodeMs ms, ${(bytes / 1048576).toStringAsFixed(1)} MB'
        '${_curl != null ? ' (during a curl)' : ''}');
    if (_curl == null && _lines.length > 50) _flush();
  }

  String _time() {
    final n = DateTime.now();
    String two(int v) => '$v'.padLeft(2, '0');
    return '${two(n.hour)}:${two(n.minute)}:${two(n.second)}.${'${n.millisecond}'.padLeft(3, '0')}';
  }

  Future<void> _flush() async {
    if (_lines.isEmpty) return;
    final out = List.of(_lines);
    _lines.clear();
    try {
      final dir = await appStorageDir();
      if (dir == null) return;
      await File('$dir${Platform.pathSeparator}perf.log').writeAsString('${out.join('\n')}\n', mode: FileMode.append);
    } catch (_) {
      // not kept: measuring only
    }
  }
}
