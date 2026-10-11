import 'dart:convert';
import 'dart:io' show gzip;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// One meaning of a word: its part of speech (noun, verb, adjective, adverb), what it means, an example (or '').
@immutable
class Meaning {
  const Meaning(this.partOfSpeech, this.definition, this.example);
  final String partOfSpeech, definition, example;
}

/// What a lookup found: the dictionary's word (e.g. "run" for "running") and its meanings, in the dictionary's order.
@immutable
class Definition {
  const Definition(this.word, this.meanings);
  final String word;
  final List<Meaning> meanings;
}

/// The offline English dictionary behind eBooks' Define (user, 2026-10-11: offline, English only for now): Open
/// English WordNet, made into assets/dictionary/en.txt.gz by tools\dictionary\build_dictionary.py (its format is
/// described there). Read the first time a word is looked up (a few seconds on the tablet, off the main thread),
/// then kept.
class EnglishDictionary {
  EnglishDictionary._(this._meanings, this._words, this._forms);

  /// The dictionary in [text] (the asset, unzipped) - tests give a small one.
  factory EnglishDictionary.parse(String text) {
    final lines = text.split('\n');
    final meanings = <String>[];
    var i = 0;
    for (; i < lines.length && lines[i].isNotEmpty; i++) {
      meanings.add(lines[i]);
    }
    final words = <String, String>{}, forms = <String, List<String>>{};
    for (i++; i < lines.length; i++) {
      final l = lines[i];
      final tab = l.indexOf('\t');
      if (tab <= 0) continue;
      final rest = l.substring(tab + 1);
      if (rest.startsWith('=')) {
        forms[l.substring(0, tab)] = rest.substring(1).split(',');
      } else {
        words[l.substring(0, tab)] = rest;
      }
    }
    return EnglishDictionary._(meanings, words, forms);
  }

  final List<String> _meanings; // "pos\tdefinition\texample", by number
  final Map<String, String> _words; // word -> its meaning numbers, "4,17,..."
  final Map<String, List<String>> _forms; // an irregular form -> its words ("mice" -> mouse)

  static Future<EnglishDictionary>? _loading;

  /// The app's dictionary, read once ([loader]: from its asset).
  static Future<EnglishDictionary> load() => _loading ??= loader();

  /// Where [load] gets the dictionary (tests: a small one, no file reading); [reset] forgets the one read.
  @visibleForTesting
  static Future<EnglishDictionary> Function() loader = _fromAsset;
  @visibleForTesting
  static void reset() => _loading = null;

  static Future<EnglishDictionary> _fromAsset() async {
    final bytes = await rootBundle.load('assets/dictionary/en.txt.gz');
    return compute(_unpack, bytes.buffer.asUint8List(bytes.offsetInBytes, bytes.lengthInBytes));
  }

  static EnglishDictionary _unpack(Uint8List zipped) => EnglishDictionary.parse(utf8.decode(gzip.decode(zipped)));

  /// What [selected] means - a word or a few, as selected on the page: trimmed of punctuation and a possessive
  /// "'s", in any case. The word itself if the dictionary has it, and the first dictionary form it's an inflection
  /// of ("running": running, then run; "mice": mouse; "boxes": box), by WordNet's own rules. Empty: not found.
  List<Definition> lookup(String selected) {
    final word = clean(selected);
    if (word.isEmpty) return const [];
    final found = <Definition>[];
    for (final w in baseForms(word)) {
      final numbers = _words[w];
      if (numbers == null || (found.isNotEmpty && w == word)) continue;
      found.add(Definition(w, [
        for (final n in numbers.split(','))
          if (int.tryParse(n) case final i? when i < _meanings.length) _meaning(_meanings[i]),
      ]));
      if (w != word || found.length == 2) break; // the word, and one base form
    }
    return found;
  }

  static Meaning _meaning(String line) {
    final f = line.split('\t');
    final pos = switch (f[0]) { 'n' => 'noun', 'v' => 'verb', 'a' => 'adjective', 'r' => 'adverb', _ => f[0] };
    return Meaning(pos, f.length > 1 ? f[1] : '', f.length > 2 ? f[2] : '');
  }

  /// [selected] as a dictionary key: lower case, curly apostrophes straight, no surrounding punctuation or
  /// possessive, inner spaces single (a phrase: "drop back").
  static String clean(String selected) {
    var s = selected.toLowerCase().replaceAll(RegExp('[‘’ʼ]'), "'").replaceAll('­', '');
    s = s.replaceAll(RegExp(r'\s+'), ' ').trim();
    s = s.replaceAll(RegExp(r"^[^a-z0-9]+|[^a-z0-9.]+$"), ''); // keeps "U.S." whole, drops quotes and commas
    if (s.endsWith('.') && !RegExp(r'\.[a-z]\.$').hasMatch(s)) s = s.substring(0, s.length - 1);
    if (s.endsWith("'s")) s = s.substring(0, s.length - 2);
    if (s.endsWith("s'")) s = s.substring(0, s.length - 1);
    return s;
  }

  // WordNet's morphy rules: ending -> what it stands for, nouns then verbs then adjectives
  static const _rules = [
    ('s', ''), ('ses', 's'), ('xes', 'x'), ('zes', 'z'), ('ches', 'ch'), ('shes', 'sh'), ('men', 'man'), ('ies', 'y'),
    ('es', 'e'), ('es', ''), ('ed', 'e'), ('ed', ''), ('ing', 'e'), ('ing', ''),
    ('er', ''), ('est', ''), ('er', 'e'), ('est', 'e'),
  ];

  /// The keys to try for [word], best first: itself, its irregular base forms, then each rule's stem.
  List<String> baseForms(String word) {
    final out = <String>[word, ...?_forms[word]];
    for (final (end, base) in _rules) {
      if (word.length > end.length + 1 && word.endsWith(end)) {
        final stem = word.substring(0, word.length - end.length) + base;
        if (!out.contains(stem)) out.add(stem);
      }
    }
    // a doubled consonant before -ing / -ed / -er / -est (running -> run, stopped -> stop, bigger -> big)
    final doubled = RegExp(r'^(.*([bcdfgklmnprstvz]))\2(ing|ed|er|est)$').firstMatch(word);
    if (doubled != null && !out.contains(doubled.group(1))) out.add(doubled.group(1)!);
    return out;
  }
}
