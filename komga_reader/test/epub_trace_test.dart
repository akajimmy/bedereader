// The EPUB reader's trace file (lib/epub/trace.dart): what led up to a crash in the engine, written as it happens.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:komga_reader/epub/trace.dart';

import 'support/helpers.dart';

void main() {
  late Directory dir;
  setUp(() async {
    dir = await Directory.systemTemp.createTemp('epub_trace_test');
    EpubTrace.instance.reset();
  });
  tearDown(() async {
    EpubTrace.instance.reset();
    await deleteTemp(dir);
  });

  test('lines go to the file as they happen (lines from before it was opened too); at the next opening it is cut to '
      'the last ${EpubTrace.keep}', () async {
    final t = EpubTrace.instance;
    t.log('open B1');
    await t.open(dir: dir.path);
    t.log('turn 1');
    final f = File('${dir.path}${Platform.pathSeparator}epub-trace.log');
    final lines = await f.readAsLines();
    expect(lines.length, 2);
    expect(lines[0], endsWith('open B1'));
    expect(lines[1], endsWith('turn 1'));

    for (var i = 0; i < EpubTrace.keep + 50; i++) {
      t.log('page $i');
    }
    t.reset();
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
    expect(line, 'frames 3: build avg 12.0 max 30.0 ms, draw avg 11.3 max 20.0 ms; over 16.7 ms: build 1, draw 1');
    expect(s.flush(), isNull, reason: 'a new window, nothing in it yet');
    s.add(1, 1, t0.add(const Duration(seconds: 5)));
    expect(s.flush(), startsWith('frames 1:'), reason: 'closing: what is left');
  });
}
