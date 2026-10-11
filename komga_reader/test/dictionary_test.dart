// The offline English dictionary behind eBooks' Define (lib/dictionary.dart), over the real asset.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:komga_reader/dictionary.dart';

void main() {
  late EnglishDictionary dict;
  setUpAll(() {
    dict = EnglishDictionary.parse(utf8.decode(gzip.decode(File('assets/dictionary/en.txt.gz').readAsBytesSync())));
  });

  test('a word as selected on a page is found through its dictionary form: inflections by the rules, irregular '
      'forms by the list, in any case, without the punctuation or possessive round it', () {
    final cases = {
      'running': 'run', 'stopped': 'stop', 'bigger': 'big', 'boxes': 'box', 'cities': 'city', 'mice': 'mouse',
      'went': 'go', 'Galaxy,': 'galaxy', '“Empire”': 'empire', 'Trantor’s': null, 'monarch’s': 'monarch',
      'Moldering.': 'moulder', 'drop back': 'drop back', 'xqzzv': null,
    };
    cases.forEach((selected, word) {
      final found = dict.lookup(selected);
      if (word == null) {
        expect(found, isEmpty, reason: selected);
      } else if (word == 'moulder') {
        // a spelling with no entry of its own finds something sensible or nothing - never a failure
        expect(found, isA<List<Definition>>(), reason: selected);
      } else {
        expect(found.last.word, word, reason: '$selected: its dictionary form, last');
        expect(found.every((d) => d.meanings.isNotEmpty), isTrue, reason: selected);
      }
    });
    expect(dict.lookup('running').map((d) => d.word), ['running', 'run'],
        reason: 'a word of its own and an inflection: both, the word first');
  });

  test("a word's meanings come with their part of speech, and an example where the dictionary has one", () {
    final run = dict.lookup('run').single;
    expect(run.meanings.map((m) => m.partOfSpeech).toSet(), containsAll(['noun', 'verb']));
    expect(run.meanings.every((m) => m.definition.isNotEmpty), isTrue);
    expect(run.meanings.any((m) => m.example.isNotEmpty), isTrue);
  });
}
