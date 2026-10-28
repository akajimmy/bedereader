import 'dart:async';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:shared_preferences/shared_preferences.dart';

import '../app_log.dart';
import '../book_source.dart';

/// Auto crop page borders (user, 2026-10-28 - reports\10-28-autocrop-review, the prototype it was dialled in with):
/// each page cut to its own content plus an even border, the book's pages kept to one frame shape so they show at one
/// size; covers, full-bleed pages and anything odd shown whole. Measured once per book from small pictures of its
/// pages (Komga's page thumbnails; a local book's pages decoded small) and remembered on the device.
///
/// What a page's margins are: its paper's colour (the commonest colour round its edge); content is whatever isn't
/// near it - aged paper's own shading and stains count as paper where they're smooth (small print isn't). A side whose
/// edge is content bleeds: never cut. The cut never goes into content, never through a page number in the border,
/// and taking more than [cropMax] off a side means it's a mistake: that page shown whole.

/// What's cut off each side of a page, as shares of its width (left, right) and height (top, bottom).
class PageCut {
  const PageCut(this.left, this.top, this.right, this.bottom);
  final double left, top, right, bottom;

  static const none = PageCut(0, 0, 0, 0);

  /// Crop edges' fixed steps: [share] off every side - [sidesOnly], the left and right only (a webtoon's slices).
  factory PageCut.even(double share, {bool sidesOnly = false}) =>
      share <= 0 ? none : PageCut(share, sidesOnly ? 0 : share, share, sidesOnly ? 0 : share);

  bool get isNone => left <= 0 && top <= 0 && right <= 0 && bottom <= 0;

  /// The pixels cut off a [width] x [height] picture's sides: (left, top, right, bottom) - always leaving one.
  (int, int, int, int) pixels(int width, int height) {
    final l = (width * left).round(), r = (width * right).round();
    final t = (height * top).round(), b = (height * bottom).round();
    return (l, t, math.min(r, width - l - 1).clamp(0, width), math.min(b, height - t - 1).clamp(0, height));
  }

  @override
  bool operator ==(Object other) =>
      other is PageCut && other.left == left && other.top == top && other.right == right && other.bottom == bottom;
  @override
  int get hashCode => Object.hash(left, top, right, bottom);
  @override
  String toString() => 'PageCut($left, $top, $right, $bottom)';
}

// ---- measuring one page (the prototype's measure(); its names in the comments)

const _ring = 0.015; // the outer ring the paper's colour is read from (share of the page's width)
const _near = 38.0; // a pixel within this RGB distance of the paper is paper
const _content = 0.03; // a line is content when more than this share of its pixels aren't paper...
const _sustain = 2; // ...for this many lines in a row
const _edgeMax = 0.04; // a ragged or dark scan edge up to this deep isn't content
const _maxShare = 0.20; // a margin is never taken as more than this share of the page
const _shadeLo = 0.55, _shadeHi = 1.25; // aged paper's shading: this much of the paper's brightness...
const _shadeHue = 0.09; // ...this close to its hue (unit RGB vectors apart)...
const _shadeSmooth = 8.0; // ...and smooth: its 3x3 neighbourhood's luminance varies this little (std)
const _fringe = 0.002, _fringeMax = 0.02; // a content edge followed out past its faint fringe, this far at most
const _paperLight = 140.0, _paperGrey = 110.0; // paper: this light, this little coloured (white, yellowed, tan)

/// One page measured: its shape, paper, margins and the lines near each edge.
class PageMeasure {
  PageMeasure({required this.width, required this.height, required this.paper, required this.margins,
      required this.lines});
  final int width, height; // the picture measured
  final List<double> paper; // RGB
  /// How far in content starts on each side (left, top, right, bottom), shares of the width / height; null: bleeds.
  final List<double?> margins;
  /// Each side's lines from the edge in: their share of not-paper pixels (up to a little past [_maxShare]).
  final List<Float64List> lines;

  double get aspect => height / width;
}

/// Measures a page from its pixels ([rgba]: [width] x [height], 4 bytes each).
PageMeasure measurePage(Uint8List rgba, int width, int height) {
  final w = width, h = height, n = w * h;
  double c(int i, int k) => rgba[i * 4 + k].toDouble();
  // the paper: the ring's most common colour, coarsely (a stain or art touching the edge doesn't move it)
  final r = math.max(2, (w * _ring).round());
  // (the four strips, the corners in two each - as the prototype read them)
  final ring = <int>[
    for (var y = 0; y < h; y++) for (var x = 0; x < r; x++) y * w + x,
    for (var y = 0; y < h; y++) for (var x = w - r; x < w; x++) y * w + x,
    for (var y = 0; y < r; y++) for (var x = 0; x < w; x++) y * w + x,
    for (var y = h - r; y < h; y++) for (var x = 0; x < w; x++) y * w + x,
  ];
  int code(int i) => (rgba[i * 4] ~/ 24) * 10000 + (rgba[i * 4 + 1] ~/ 24) * 100 + rgba[i * 4 + 2] ~/ 24;
  final counts = <int, int>{};
  for (final i in ring) {
    counts.update(code(i), (v) => v + 1, ifAbsent: () => 1);
  }
  var best = counts.keys.first;
  for (final e in counts.entries) {
    if (e.value > counts[best]! || (e.value == counts[best]! && e.key < best)) best = e.key;
  }
  final inBest = [for (final i in ring) if (code(i) == best) i];
  final paper = [for (var k = 0; k < 3; k++) _median([for (final i in inBest) c(i, k)])];

  final content = Uint8List(n);
  for (var i = 0; i < n; i++) {
    final dr = c(i, 0) - paper[0], dg = c(i, 1) - paper[1], db = c(i, 2) - paper[2];
    if (dr * dr + dg * dg + db * db > _near * _near) content[i] = 1;
  }
  final lum = 0.299 * paper[0] + 0.587 * paper[1] + 0.114 * paper[2];
  if (!_white(paper) && lum >= _paperLight) {
    // aged paper: its own colour, darker or lighter (shading, foxing, uneven light), is paper too where it's smooth
    final pn = _norm(paper);
    final pu = [for (final v in paper) v / pn];
    final l = Float64List(n);
    for (var i = 0; i < n; i++) {
      l[i] = (c(i, 0) + c(i, 1) + c(i, 2)) / 3;
    }
    for (var y = 0; y < h; y++) {
      for (var x = 0; x < w; x++) {
        final i = y * w + x;
        if (content[i] == 0) continue;
        final rr = c(i, 0), gg = c(i, 1), bb = c(i, 2);
        final norm = math.sqrt(rr * rr + gg * gg + bb * bb);
        final shade = norm / pn;
        if (shade < _shadeLo || shade > _shadeHi) continue;
        final m = math.max(norm, 1.0);
        final hr = rr / m - pu[0], hg = gg / m - pu[1], hb = bb / m - pu[2];
        if (math.sqrt(hr * hr + hg * hg + hb * hb) > _shadeHue) continue;
        // its 3x3 neighbourhood's luminance std (edges repeated, as numpy's edge padding)
        var s = 0.0, s2 = 0.0;
        for (var dy = -1; dy <= 1; dy++) {
          final yy = (y + dy).clamp(0, h - 1);
          for (var dx = -1; dx <= 1; dx++) {
            final v = l[yy * w + (x + dx).clamp(0, w - 1)];
            s += v;
            s2 += v * v;
          }
        }
        final mean = s / 9;
        if (math.sqrt(math.max(0.0, s2 / 9 - mean * mean)) <= _shadeSmooth) content[i] = 0;
      }
    }
  }
  // each column's and row's share of not-paper pixels
  final cols = Float64List(w), rows = Float64List(h);
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      if (content[y * w + x] == 1) {
        cols[x]++;
        rows[y]++;
      }
    }
  }
  for (var x = 0; x < w; x++) {
    cols[x] /= h;
  }
  for (var y = 0; y < h; y++) {
    rows[y] /= w;
  }
  Float64List from(Float64List v, bool reversed) => reversed ? Float64List.fromList(v.reversed.toList()) : v;
  final seqs = [from(cols, false), from(rows, false), from(cols, true), from(rows, true)];
  final sizes = [w, h, w, h];
  return PageMeasure(
    width: w,
    height: h,
    paper: paper,
    margins: [for (var s = 0; s < 4; s++) _margin(seqs[s], sizes[s])],
    lines: [
      for (var s = 0; s < 4; s++)
        Float64List.fromList(seqs[s].sublist(0, math.min(seqs[s].length, (sizes[s] * _maxShare).round() + 2)))
    ],
  );
}

bool _white(List<double> p) => p.reduce(math.min) >= 235 && p.reduce(math.max) - p.reduce(math.min) <= 15;

double _norm(List<double> v) => math.sqrt(v.fold(0.0, (s, x) => s + x * x));

/// The median (of an even count: the middle two's mean, as numpy's).
double _median(List<double> v) {
  if (v.isEmpty) return 0;
  final s = [...v]..sort();
  final m = s.length ~/ 2;
  return s.length.isOdd ? s[m] : (s[m - 1] + s[m]) / 2;
}

/// How far in content starts on one side ([seq]: each line's share of not-paper pixels, from the edge in), past a
/// ragged or dark scan edge; null when the art runs off the side.
double? _margin(Float64List seq, int size) {
  final k = math.max(1, (size * _edgeMax).round());
  int? start;
  for (var i = 0; i <= k && i < seq.length; i++) {
    if (seq[i] <= _content) {
      start = i;
      break;
    }
  }
  if (start == null) return null; // content from the edge in: bleeds
  final end = math.min(seq.length, (size * _maxShare).round());
  var run = 0, i = start;
  while (i < end) {
    run = seq[i] > _content ? run + 1 : 0;
    if (run >= _sustain) {
      final p = i - _sustain + 1;
      // a thin dark strip at the scan's edge, clean paper after it: the paper's edge, not content
      if (p <= k) {
        int? q;
        for (var j = p; j < math.min(end - 3, k + 4); j++) {
          if (seq[j] <= _content && seq[j + 1] <= _content && seq[j + 2] <= _content) {
            q = j;
            break;
          }
        }
        if (q != null) {
          i = q;
          run = 0;
          continue;
        }
      }
      // the content's faint edge (anti-aliasing, a thin line at this size) followed out
      final grain = p > start ? _median(seq.sublist(start, p)) : 0.0;
      var f = p;
      final reach = math.max(1, (size * _fringeMax).round());
      while (f > start && p - f < reach && seq[f - 1] > grain + _fringe) {
        f--;
      }
      return f / size;
    }
    i++;
  }
  return _maxShare; // (no content within reach: as far as it's ever taken)
}

// ---- the book: each page's cut

/// The border left round the content, a share of the page width (user, 2026-10-28: "2.5% looks right").
const defaultBorder = 0.025;
const cropMax = 0.15; // taking more than this off a side is a mistake: that page whole (user: "like 15%")
const _fitMin = 0.25; // the book is cropped only if this share of its pages can be
const _shapeOff = 0.15; // a page this far off the book's usual shape (a spread, an insert) is shown whole
const _shapeTol = 0.06; // a page's frame may be this far off the book's frame shape before it's grown to it
const _floor = 0.90; // a page's frame is never smaller than this share of the usual one (sparse pages don't zoom in)
const _darkShare = 0.5; // dark paper only when this share of the well-measured pages have it (a black-bordered book)
const _clean = 0.008, _clearMax = 0.03; // a cut's line: this little above the margin's grain, looked for this far out

/// Each page's cut ([pages]: null - not measured, shown whole); null: the page shown whole.
List<PageCut?> bookCuts(List<PageMeasure?> pages, {double border = defaultBorder}) {
  final measured = pages.whereType<PageMeasure>().toList();
  if (measured.isEmpty) return List.filled(pages.length, null);
  final usualAspect = _median([for (final m in measured) m.aspect]);
  final trusted = _trustedPaper(measured);
  // each page's own box: its content plus the border (a side that bleeds: to the edge), in page-width units
  final boxes = <List<double>?>[
    for (final m in pages)
      if (m == null || m.margins.every((v) => v == null) || (m.aspect / usualAspect - 1).abs() > _shapeOff ||
          !trusted(m.paper))
        null
      else
        [
          m.margins[0] == null ? 0.0 : math.max(0.0, m.margins[0]! - border),
          m.margins[2] == null ? 1.0 : math.min(1.0, 1 - m.margins[2]! + border),
          m.margins[1] == null ? 0.0 : math.max(0.0, m.margins[1]! * m.aspect - border),
          m.margins[3] == null ? m.aspect : math.min(m.aspect, (1 - m.margins[3]!) * m.aspect + border),
        ]
  ];
  final known = boxes.whereType<List<double>>().toList();
  if (known.length < _fitMin * measured.length) return List.filled(pages.length, null);
  final w0 = _median([for (final b in known) b[1] - b[0]]), h0 = _median([for (final b in known) b[3] - b[2]]);
  final shape = h0 / w0;
  return [
    for (var i = 0; i < pages.length; i++) boxes[i] == null ? null : _place(pages[i]!, boxes[i]!, w0, h0, shape),
  ];
}

PageCut? _place(PageMeasure m, List<double> box, double w0, double h0, double shape) {
  final a = m.aspect;
  var (x0, x1) = _grow(box[0], box[1], _floor * w0, 1.0);
  var (y0, y1) = _grow(box[2], box[3], _floor * h0, a);
  final w = x1 - x0, h = y1 - y0;
  if (h / w < shape * (1 - _shapeTol)) {
    (y0, y1) = _grow(y0, y1, w * shape * (1 - _shapeTol), a);
  } else if (h / w > shape * (1 + _shapeTol)) {
    (x0, x1) = _grow(x0, x1, h / (shape * (1 + _shapeTol)), 1.0);
  }
  final cut = [x0, y0 / a, 1 - x1, (a - y1) / a];
  if (cut.reduce(math.max) > cropMax) return null; // more is a mistake: whole
  for (var s = 0; s < 4; s++) {
    final size = s.isEven ? m.width.toDouble() : m.height.toDouble();
    final margin = m.margins[s];
    if (margin != null && cut[s] > 0) cut[s] = _clear(cut[s] * size, m.lines[s], margin * size, size) / size;
  }
  // (to 4 places - as remembered: a book opened again cuts exactly as it did the first time)
  double four(double v) => (v * 10000).round() / 10000;
  return PageCut(four(cut[0]), four(cut[1]), four(cut[2]), four(cut[3]));
}

/// [lo, hi] grown evenly both ways to [size] (no smaller), kept within [0, limit] - moved over at an edge.
(double, double) _grow(double lo, double hi, double size, double limit) {
  if (hi - lo >= size) return (lo, hi);
  if (size >= limit) return (0.0, limit);
  final extra = (size - (hi - lo)) / 2;
  lo -= extra;
  hi += extra;
  if (lo < 0) {
    hi -= lo;
    lo = 0;
  }
  if (hi > limit) {
    lo -= hi - limit;
    hi = limit;
  }
  return (math.max(0.0, lo), hi);
}

/// A side's cut (lines from the edge) moved out to the nearest clean line - never through a page number in the
/// border; [margin]: where content starts (lines). Clean is against the margin's own grain (its median line).
int _clear(double cut, Float64List lines, double margin, double size) {
  final k = math.min(cut.round(), lines.length - 1);
  final m = math.max(1, math.min(margin.toInt(), lines.length));
  final limit = _clean + _median(lines.sublist(0, m));
  final reach = math.max(1, (_clearMax * size).round());
  for (var j = k; j >= math.max(0, k - reach); j--) {
    if (j == 0 || math.max(lines[j - 1], lines[j]) <= limit) return j;
  }
  return k;
}

/// Which paper colours a page's margins are believed on: light, low-colour paper; a darker one only when most of the
/// book's well-measured pages (three sides or more) have it - full-bleed art's flat dark or red edge isn't paper.
bool Function(List<double>) _trustedPaper(List<PageMeasure> pages) {
  bool light(List<double> p) =>
      0.299 * p[0] + 0.587 * p[1] + 0.114 * p[2] >= _paperLight &&
      p.reduce(math.max) - p.reduce(math.min) <= _paperGrey;
  final well = [for (final m in pages) if (m.margins.where((v) => v != null).length >= 3) m.paper];
  final dark = [for (final p in well) if (!light(p)) p];
  List<double>? usualDark;
  if (well.length >= 5 && dark.length >= _darkShare * well.length) {
    usualDark = [for (var k = 0; k < 3; k++) _median([for (final p in dark) p[k]])];
  }
  return (p) {
    if (light(p)) return true;
    final d = usualDark;
    if (d == null) return false;
    return _norm([p[0] - d[0], p[1] - d[1], p[2] - d[2]]) <= _near;
  };
}

// ---- a book measured, and remembered

/// The size pages are measured at (Komga's page thumbnails are about this wide).
const measureWidth = 300;

/// A book's pages measured and its cuts worked out: [done] of [total] so far; [cuts] once finished. Each page is
/// fetched small ([BookSource.pageThumbBytes]), decoded at [measureWidth] and measured off the UI's thread; a page
/// that fails is shown whole. Remembered on the device ([AutoCropStore]) when every page was measured.
class AutoCropRun {
  AutoCropRun(this.api, this.bookId, this.pageNumbers, {required this.border, this.onProgress,
      Future<PageMeasure?> Function(Uint8List bytes, AutoCropTimes times)? measure})
      : _measure = measure ?? measureForTests ?? measureBytes {
    _run();
  }
  final BookSource api;
  final String bookId;
  final List<int> pageNumbers;
  final double border;
  final void Function()? onProgress;
  final Future<PageMeasure?> Function(Uint8List bytes, AutoCropTimes times) _measure;

  int done = 0;
  int get total => pageNumbers.length;
  List<PageCut?>? cuts;
  bool _cancelled = false;
  final _finished = Completer<List<PageCut?>>();
  Future<List<PageCut?>> get finished => _finished.future;

  /// Stops it (the book closed, another border): nothing more is fetched or told.
  void cancel() => _cancelled = true;

  /// Tests: pages measured with this instead (no decoding or isolates in a widget test).
  @visibleForTesting
  static Future<PageMeasure?> Function(Uint8List bytes, AutoCropTimes times)? measureForTests;

  /// Pages measured at once.
  static const parallel = 4;

  Future<void> _run() async {
    final wall = Stopwatch()..start(); // TEMPORARY timing (user, 2026-10-28: timed on the tablet, then stripped)
    final saved = await AutoCropStore.load(bookId, total, border);
    if (_cancelled) return;
    if (saved != null) {
      _log('$bookId: remembered cuts for $total pages, ${wall.elapsedMilliseconds} ms');
      _finish(saved);
      return;
    }
    _log('$bookId: measuring $total pages, border ${(border * 100).toStringAsFixed(1)}%, $parallel at once');
    final measured = List<PageMeasure?>.filled(total, null);
    var next = 0, failed = 0;
    final times = AutoCropTimes();
    Future<void> worker() async {
      while (next < total && !_cancelled) {
        final i = next++;
        final page = Stopwatch()..start();
        try {
          final fetch = Stopwatch()..start();
          final bytes = await api.pageThumbBytes(bookId, pageNumbers[i]);
          times.fetchUs += fetch.elapsedMicroseconds;
          times.bytes += bytes.length;
          measured[i] = await _measure(bytes, times);
        } catch (_) {
          measured[i] = null; // shown whole
        }
        if (page.elapsedMilliseconds > times.slowestMs) {
          times
            ..slowestMs = page.elapsedMilliseconds
            ..slowestPage = i + 1;
        }
        if (measured[i] == null) failed++;
        done++;
        if (done % 25 == 0) _log('$bookId: $done / $total pages, ${wall.elapsedMilliseconds} ms');
        if (!_cancelled) onProgress?.call();
      }
    }

    await Future.wait([for (var k = 0; k < parallel; k++) worker()]);
    if (_cancelled) {
      _log('$bookId: stopped at $done / $total, ${wall.elapsedMilliseconds} ms');
      return;
    }
    final placing = Stopwatch()..start();
    final result = bookCuts(measured, border: border);
    final placeMs = placing.elapsedMilliseconds;
    if (failed == 0) await AutoCropStore.save(bookId, border, result);
    String avg(int us) => (us / 1000 / math.max(1, total)).toStringAsFixed(1);
    final px = measured.whereType<PageMeasure>().firstOrNull;
    _log('$bookId: $total pages in ${wall.elapsedMilliseconds} ms - per page (summed over $parallel at once): '
        'fetch ${avg(times.fetchUs)} ms, decode ${avg(times.decodeUs)} ms, measure ${avg(times.measureUs)} ms; '
        'placing $placeMs ms; slowest p${times.slowestPage} ${times.slowestMs} ms; '
        '${(times.bytes / 1024 / math.max(1, total)).round()} KB a page${px == null ? '' : ', measured ${px.width}x${px.height}'}; '
        '${result.where((c) => c != null && !c.isNone).length} cropped, ${result.where((c) => c == null).length} whole'
        '${failed == 0 ? '' : ', $failed failed (not remembered)'}');
    _finish(result);
  }

  static void _log(String msg) => AppLog.instance.info('autocrop', msg);

  void _finish(List<PageCut?> result) {
    if (_cancelled) return;
    cuts = result;
    done = total;
    if (!_finished.isCompleted) _finished.complete(result);
    onProgress?.call();
  }
}

/// TEMPORARY: where a book's measuring time goes, summed over its pages (microseconds).
class AutoCropTimes {
  int fetchUs = 0, decodeUs = 0, measureUs = 0, bytes = 0, slowestMs = 0, slowestPage = 0;
}

/// A page's file decoded [measureWidth] wide and measured off the UI's thread; null if it can't be decoded.
Future<PageMeasure?> measureBytes(Uint8List bytes, [AutoCropTimes? times]) async {
  final decode = Stopwatch()..start();
  final ui.Image image;
  try {
    image = (await (await ui.instantiateImageCodec(bytes, targetWidth: measureWidth)).getNextFrame()).image;
  } catch (_) {
    return null;
  }
  try {
    final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
    if (times != null) times.decodeUs += decode.elapsedMicroseconds;
    if (data == null) return null;
    final rgba = data.buffer.asUint8List(), w = image.width, h = image.height;
    final measure = Stopwatch()..start();
    final m = await Isolate.run(() => measurePage(rgba, w, h));
    if (times != null) times.measureUs += measure.elapsedMicroseconds;
    return m;
  } finally {
    image.dispose();
  }
}

/// Books' cuts remembered on this device (shared preferences, as the book's levels are): by book, for its page
/// count and the border they were made with. The last [kept] books' only.
class AutoCropStore {
  static const kept = 300;
  static String _key(String bookId) => 'autocrop.$bookId';

  static Future<List<PageCut?>?> load(String bookId, int pages, double border) async {
    final v = (await SharedPreferences.getInstance()).getString(_key(bookId));
    return v == null ? null : decode(v, pages, border);
  }

  static Future<void> save(String bookId, double border, List<PageCut?> cuts) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_key(bookId), encode(border, cuts));
    final books = prefs.getStringList('autocrop.books') ?? [];
    books
      ..remove(bookId)
      ..add(bookId);
    while (books.length > kept) {
      await prefs.remove(_key(books.removeAt(0)));
    }
    await prefs.setStringList('autocrop.books', books);
  }

  /// "border|pages|cut;cut;..." - a cut "l,t,r,b", or "-" for a page shown whole.
  static String encode(double border, List<PageCut?> cuts) => [
        border.toStringAsFixed(4),
        cuts.length,
        [
          for (final c in cuts)
            c == null ? '-' : [c.left, c.top, c.right, c.bottom].map((v) => v.toStringAsFixed(4)).join(','),
        ].join(';'),
      ].join('|');

  /// [encode]'s cuts, if they're for [pages] pages and [border]; else null (measured again).
  static List<PageCut?>? decode(String v, int pages, double border) {
    final parts = v.split('|');
    if (parts.length != 3 || parts[0] != border.toStringAsFixed(4) || int.tryParse(parts[1]) != pages) return null;
    final items = pages == 0 ? <String>[] : parts[2].split(';');
    if (items.length != pages) return null;
    final out = <PageCut?>[];
    for (final s in items) {
      if (s == '-') {
        out.add(null);
        continue;
      }
      final n = s.split(',').map(double.tryParse).toList();
      if (n.length != 4 || n.any((x) => x == null)) return null;
      out.add(PageCut(n[0]!, n[1]!, n[2]!, n[3]!));
    }
    return out;
  }
}
