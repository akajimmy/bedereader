/// The parts of CSS books use (from the survey of the user's 339 EPUBs, 2026-10-05): rules with tag / class / id
/// selectors, descendant chains, and the properties the layout understands. Anything else is read and ignored.
library;

import 'xhtml.dart';

class CssRule {
  CssRule(this.selector, this.decls, this.order);
  final CssSelector selector;
  final Map<String, String> decls;
  final int order;
}

class CssCompound {
  CssCompound(this.tag, this.classes, this.id, this.pseudo, [this.states = const []]);
  final String? tag;
  final List<String> classes;
  final String? id;
  final String? pseudo; // a pseudo-element: first-letter, first-line, before ... (only first-letter is used)
  // pseudo-classes: :first-child, :last-child, :first-of-type are checked; any other (:hover, :nth-child...) never
  // matches. They were taken for pseudo-elements, so a "p:first-child" rule never applied (EPUB review E11)
  final List<String> states;

  static const pseudoElements = {'first-letter', 'first-line', 'before', 'after', 'marker', 'selection'};

  bool matches(XElement e) =>
      (tag == null || tag == '*' || tag == e.name) &&
      (id == null || e.id == id) &&
      classes.every(e.classes.contains) &&
      states.every((s) => _state(s, e));

  static bool _state(String s, XElement e) {
    final siblings = e.parent?.elements.toList() ?? [e];
    return switch (s) {
      'first-child' => siblings.first == e,
      'last-child' => siblings.last == e,
      'first-of-type' => siblings.firstWhere((x) => x.name == e.name) == e,
      _ => false,
    };
  }

  int get specificity =>
      (id != null ? 100 : 0) + (classes.length + states.length) * 10 + (tag != null && tag != '*' ? 1 : 0);
}

class CssSelector {
  CssSelector(this.parts);
  final List<CssCompound> parts; // last = the element itself, the rest its ancestors (descendant or child)

  int get specificity => parts.fold(0, (s, p) => s + p.specificity);
  String? get pseudo => parts.last.pseudo;

  bool matches(XElement e) {
    if (!parts.last.matches(e)) return false;
    var i = parts.length - 2;
    for (var a = e.parent; i >= 0 && a != null; a = a.parent) {
      if (parts[i].matches(a)) i--;
    }
    return i < 0;
  }

  static final _compound = RegExp(r'^([A-Za-z][\w-]*|\*)?((?:[.#][\w-]+)*)((?::{1,2}[\w-]+)*)$');

  static CssSelector? parse(String s) {
    final parts = <CssCompound>[];
    for (final raw in s.replaceAll('>', ' ').replaceAll('+', ' ').replaceAll('~', ' ').trim().split(RegExp(r'\s+'))) {
      if (raw.isEmpty) continue;
      final m = _compound.firstMatch(raw);
      if (m == null) return null; // attribute selectors etc.: not supported, rule skipped
      final classes = <String>[];
      String? id;
      for (final x in RegExp(r'([.#])([\w-]+)').allMatches(m[2] ?? '')) {
        if (x[1] == '.') {
          classes.add(x[2]!);
        } else {
          id = x[2];
        }
      }
      final ps = (m[3] ?? '').replaceAll('::', ':').split(':').where((p) => p.isNotEmpty).map((p) => p.toLowerCase());
      parts.add(CssCompound(m[1]?.toLowerCase(), classes, id,
          ps.where(CssCompound.pseudoElements.contains).lastOrNull,
          ps.where((p) => !CssCompound.pseudoElements.contains(p)).toList()));
    }
    return parts.isEmpty ? null : CssSelector(parts);
  }
}

class StyleSheet {
  final List<CssRule> rules = [];
  int _order = 0;

  void add(String css) {
    final src = css.replaceAll(RegExp(r'/\*[\s\S]*?\*/'), '');
    // @media / @font-face / @page blocks: skip their bodies (nested braces included)
    var i = 0;
    while (i < src.length) {
      final open = src.indexOf('{', i);
      if (open < 0) break;
      var head = src.substring(i, open).trim();
      // statement at-rules ending in ';' before it (@charset "UTF-8"; @import ...; @namespace h "...";) aren't
      // part of its selector - the whole first rule was skipped as an at-rule, and Calibre's stylesheets all start
      // with @namespace (EPUB review 2026-10-06, E5)
      while (head.startsWith('@') && head.contains(';')) {
        head = head.substring(head.indexOf(';') + 1).trim();
      }
      final close = _matching(src, open);
      final body = src.substring(open + 1, close < 0 ? src.length : close);
      i = close < 0 ? src.length : close + 1;
      if (head.startsWith('@')) {
        if (head.startsWith('@media') && (head.contains('screen') || head.contains('all'))) add(body);
        continue;
      }
      final decls = parseDecls(body);
      for (final s in head.split(',')) {
        final sel = CssSelector.parse(s.trim());
        if (sel != null) rules.add(CssRule(sel, decls, _order++));
      }
    }
  }

  static int _matching(String s, int open) {
    var depth = 0;
    for (var i = open; i < s.length; i++) {
      if (s[i] == '{') depth++;
      if (s[i] == '}' && --depth == 0) return i;
    }
    return -1;
  }

  static Map<String, String> parseDecls(String body) {
    final out = <String, String>{};
    for (final d in body.split(';')) {
      final c = d.indexOf(':');
      if (c < 0) continue;
      final k = d.substring(0, c).trim().toLowerCase();
      var v = d.substring(c + 1).trim();
      v = v.replaceAll(RegExp(r'\s*!important\s*$'), '');
      if (k.isNotEmpty && v.isNotEmpty) out[k] = v;
    }
    return out;
  }

  /// Declarations for [e] in cascade order (later / more specific wins), its style attribute last.
  /// [pseudo]: 'first-letter' for the ::first-letter rules only.
  Map<String, String> declsFor(XElement e, {String? pseudo}) {
    final hits = rules.where((r) => r.selector.pseudo == pseudo && r.selector.matches(e)).toList()
      ..sort((a, b) {
        final s = a.selector.specificity.compareTo(b.selector.specificity);
        return s != 0 ? s : a.order.compareTo(b.order);
      });
    final out = <String, String>{};
    for (final r in hits) {
      out.addAll(_expand(r.decls));
    }
    if (pseudo == null) {
      final inline = e.attr('style');
      if (inline != null) out.addAll(_expand(parseDecls(inline)));
    }
    return out;
  }

  static Map<String, String> _expand(Map<String, String> d) {
    final m = d['margin'];
    if (m == null) return d;
    final v = m.split(RegExp(r'\s+'));
    final (t, r, b, l) = switch (v.length) {
      1 => (v[0], v[0], v[0], v[0]),
      2 => (v[0], v[1], v[0], v[1]),
      3 => (v[0], v[1], v[2], v[1]),
      _ => (v[0], v[1], v[2], v[3]),
    };
    return {
      'margin-top': t, 'margin-right': r, 'margin-bottom': b, 'margin-left': l,
      for (final e in d.entries) if (e.key != 'margin') e.key: e.value,
    };
  }
}

/// A CSS length in px. [em]: the element's font size; [percentOf]: what % means (width for margins, font for size).
double? cssLength(String? v, {required double em, double? percentOf, double rem = 16}) {
  if (v == null) return null;
  final m = RegExp(r'^(-?[\d.]+)\s*(em|rem|px|pt|%|ex)?$').firstMatch(v.trim());
  if (m == null) return v.trim() == '0' ? 0 : null;
  final n = double.tryParse(m[1]!);
  if (n == null) return null;
  return switch (m[2]) {
    'em' => n * em,
    'rem' => n * rem,
    'ex' => n * em * 0.5,
    'pt' => n * 4 / 3,
    '%' => percentOf == null ? null : n * percentOf / 100,
    _ => n, // px or a bare number
  };
}
