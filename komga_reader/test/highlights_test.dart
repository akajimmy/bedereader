// eBook highlights (lib/highlights.dart): kept per book in Komga's client settings (shared by the user's devices), a
// copy on the device; a change made here wins and is sent until Komga has it.
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:komga_reader/highlights.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/client_settings.dart';
import 'support/no_network.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  const key = 'komgareader.highlights.B1';
  List<Map<String, dynamic>> sent(SettingsServer s) => (jsonDecode(s.written[key]!) as List).cast();

  test('a highlight is saved on Komga under the book; one overlapping others takes them in (start of the first to '
      'the end of the last); removing one sends the rest', () async {
    final s = noNetwork(SettingsServer.new);
    final h = BookHighlights(s, 'B1');
    addTearDown(h.dispose);
    await h.load();
    await h.add(const Highlight('c1.xhtml', 10, 20, 'ten to twenty'));
    await h.add(const Highlight('c1.xhtml', 40, 50, 'forty'));
    expect(sent(s).map((j) => (j['s'], j['e'])), [(10, 20), (40, 50)]);
    await h.add(const Highlight('c1.xhtml', 15, 45, 'across both'));
    expect(h.items.map((m) => (m.start, m.end)), [(10, 50)], reason: 'one highlight now');
    await h.add(const Highlight('c2.xhtml', 15, 45, 'another chapter'));
    expect(h.items, hasLength(2), reason: 'other chapters are apart');
    await h.remove(h.items.first);
    expect(sent(s).single['c'], 'c2.xhtml');
  });

  test("another device's highlights come from Komga; a change made here that hasn't reached Komga wins over them",
      () async {
    final s = noNetwork(() => SettingsServer({key: jsonEncode([const Highlight('c1.xhtml', 1, 5, 'from the PC').toJson()])}));
    final h = BookHighlights(s, 'B1');
    addTearDown(h.dispose);
    await h.load();
    expect(h.items.single.text, 'from the PC');

    // offline here: the change stays on the device ...
    s.down = true;
    await h.add(const Highlight('c1.xhtml', 30, 40, 'made offline'));
    expect(h.items, hasLength(2));
    expect(h.retrying, isTrue, reason: 'tried again later');
    h.dispose();

    // ... and is sent the next time the book opens, over what Komga had
    s.down = false;
    final again = BookHighlights(s, 'B1');
    addTearDown(again.dispose);
    await again.load();
    expect(again.items.map((m) => m.text), ['from the PC', 'made offline']);
    expect(sent(s), hasLength(2), reason: 'Komga has it now');
  });

  test("listed in reading order - the chapter's place in the book, not its file name (audit, 2026-10-11: ch10 came "
      'before ch2)', () {
    const spine = ['ch2.xhtml', 'ch10.xhtml'];
    final marks = inReadingOrder(const [
      Highlight('ch10.xhtml', 5, 9, 'later'),
      Highlight('ch2.xhtml', 50, 60, 'second'),
      Highlight('ch2.xhtml', 1, 4, 'first'),
    ], spine);
    expect(marks.map((m) => m.text), ['first', 'second', 'later']);
  });

  test("a damaged copy on the device is no highlights, not a failure (sorting it threw)", () async {
    SharedPreferences.setMockInitialValues({'highlights.B1': 'not json'});
    final h = BookHighlights(noNetwork(SettingsServer.new), 'B1');
    addTearDown(h.dispose);
    await h.load();
    expect(h.items, isEmpty);
  });

  test('highlights within a stretch of a chapter: the ones touching it only', () async {
    final s = noNetwork(SettingsServer.new);
    final h = BookHighlights(s, 'B1');
    addTearDown(h.dispose);
    await h.add(const Highlight('c1.xhtml', 10, 20, 'a'));
    await h.add(const Highlight('c1.xhtml', 100, 120, 'b'));
    expect(h.within('c1.xhtml', 15, 101).map((m) => m.text), ['a', 'b']);
    expect(h.within('c1.xhtml', 20, 100), isEmpty, reason: 'ends are open');
    expect(h.within('c2.xhtml', 0, 1000), isEmpty);
  });
}
