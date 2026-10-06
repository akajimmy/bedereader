/// The languages there are patterns for (user, 2026-10-06: English + French), picked by a book's lang attribute.
class Hyphenators {
  Hyphenators(this.byLanguage);
  final Map<String, Hyphenator> byLanguage;

  static const _dir = 'assets/hyphenation';

  /// [read]: an asset's text (rootBundle.loadString in the app, a file in tests).
  static Future<Hyphenators> load(Future<String> Function(String path) read) async => Hyphenators({
        'en': Hyphenator(await read('$_dir/hyph-en-us.pat.txt'), await read('$_dir/hyph-en-us.hyp.txt')),
        // French: 2 letters at least on either side of a break (the patterns' own minimums)
        'fr': Hyphenator(await read('$_dir/hyph-fr.pat.txt'), '', rightMin: 2),
      });

  /// For a book's lang ("en", "en-GB", "fr-CA"): English when it doesn't say; null (no hyphenation) for languages
  /// without patterns.
  Hyphenator? forLang(String? lang) {
    final l = (lang == null || lang.trim().isEmpty ? 'en' : lang).trim().toLowerCase().split(RegExp('[-_]')).first;
    return byLanguage[l];
  }
}

/// Liang's hyphenation (the algorithm TeX and browsers use) over the hyph-utf8 patterns. Marks the places a word
/// may break with soft hyphens (U+00AD); Flutter's line breaker breaks there, and the paginator draws the hyphen
/// (Flutter doesn't).
class Hyphenator {
  Hyphenator(String patterns, String exceptions, {this.leftMin = 2, this.rightMin = 3}) {
    for (final p in patterns.split(RegExp(r'\s+'))) {
      if (p.isEmpty) continue;
      final letters = StringBuffer();
      final points = <int>[0];
      for (final c in p.runes) {
        if (c >= 0x30 && c <= 0x39) {
          points[points.length - 1] = c - 0x30;
        } else {
          letters.writeCharCode(c);
          points.add(0);
        }
      }
      _patterns[letters.toString()] = points;
      if (letters.length > _maxLen) _maxLen = letters.length;
    }
    for (final e in exceptions.split(RegExp(r'\s+'))) {
      if (e.isEmpty) continue;
      _exceptions[e.replaceAll('-', '')] = e.split('-');
    }
  }

  final int leftMin, rightMin;
  final Map<String, List<int>> _patterns = {};
  final Map<String, List<String>> _exceptions = {};
  int _maxLen = 0;

  static const soft = '­';
  static final _word = RegExp(r"[A-Za-zÀ-ɏ]{4,}"); // 4: French breaks after 2 letters, before the last 2

  /// [text] with soft hyphens put into every word of 5 letters or more.
  String apply(String text) => text.replaceAllMapped(_word, (m) => _hyphenate(m[0]!).join(soft));

  List<String> _hyphenate(String word) {
    final lower = word.toLowerCase();
    final ex = _exceptions[lower];
    if (ex != null) {
      // keep the word's own capitals
      final out = <String>[];
      var i = 0;
      for (final part in ex) {
        out.add(word.substring(i, i + part.length));
        i += part.length;
      }
      return out;
    }
    final w = '.$lower.';
    final points = List<int>.filled(w.length + 1, 0);
    for (var i = 0; i < w.length; i++) {
      for (var j = i + 1; j <= w.length && j - i <= _maxLen; j++) {
        final p = _patterns[w.substring(i, j)];
        if (p == null) continue;
        for (var k = 0; k < p.length; k++) {
          if (p[k] > points[i + k]) points[i + k] = p[k];
        }
      }
    }
    // points[i + 1] is the value between word[i - 1] and word[i]
    final parts = <String>[];
    var start = 0;
    for (var i = leftMin; i <= word.length - rightMin; i++) {
      if (points[i + 1].isOdd) {
        parts.add(word.substring(start, i));
        start = i;
      }
    }
    parts.add(word.substring(start));
    return parts;
  }
}
