// The EPUB reader's trace file (lib/epub/trace.dart): what led up to a crash in the engine, written as it happens.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:komga_reader/epub/trace.dart';

import 'support/helpers.dart';

void main() {
  late Directory dir;
  setUp(() async {
    dir = await Directory.systemTemp.createTemp('epub_trace_test');
    await EpubTrace.instance.reset();
  });
  tearDown(() async {
    await EpubTrace.instance.reset();
    await deleteTemp(dir);
  });

  test('lines go to the file as they happen (lines from before it was opened too); at the next opening it is cut to '
      'the last ${EpubTrace.keep}', () async {
    final t = EpubTrace.instance;
    t.log('open B1');
    await t.open(dir: dir.path);
    t.log('turn 1');
    await t.flush(); // written off the UI thread: in the file moments later
    final f = File('${dir.path}${Platform.pathSeparator}epub-trace.log');
    final lines = await f.readAsLines();
    expect(lines.length, 2);
    expect(lines[0], endsWith('open B1'));
    expect(lines[1], endsWith('turn 1'));

    for (var i = 0; i < EpubTrace.keep + 50; i++) {
      t.log('page $i');
    }
    await t.reset();
    await t.open(dir: dir.path); // the next time a book opens
    final kept = await f.readAsLines();
    expect(kept.length, EpubTrace.keep);
    expect(kept.last, endsWith('page ${EpubTrace.keep + 49}'), reason: 'the newest lines are the ones kept');
  });

  test('frame times: a line per second with frames - how many, build and draw times, how many missed 16.7 ms', () {
    final s = FrameStats();
    final t0 = DateTime(2026, 10, 6, 12);
    expect(s.add(4, 6, t0), isNull);
    expect(s.add(30, 8, t0.add(const Duration(milliseconds: 500))), isNull);
    final line = s.add(2, 20, t0.add(const Duration(seconds: 1)));
    expect(line, 'frames 3: build avg 12.0 max 30.0 ms, draw avg 11.3 max 20.0 ms; over 16.7 ms: build 1, draw 1; '
        'missed refreshes 0');
    expect(s.flush(), isNull, reason: 'a new window, nothing in it yet');
    s.add(1, 1, t0.add(const Duration(seconds: 5)));
    expect(s.flush(), startsWith('frames 1:'), reason: 'closing: what is left');
  });

  test('frame starts: a frame that started a refresh or more late counts its missed refreshes; a rest between turns '
      "doesn't", () {
    final s = FrameStats();
    final t0 = DateTime(2026, 10, 6, 12);
    const r = 16667; // µs, one refresh at 60 Hz
    var v = 0;
    for (final gap in [1, 1, 2, 1, 1, 3, 1, 40, 1]) { // 2 = one missed, 3 = two missed, 40 = pages at rest
      v += gap * r;
      s.add(1, 5, t0, vsyncUs: v);
    }
    expect(s.flush(), endsWith('missed refreshes 3'));
  });
}
