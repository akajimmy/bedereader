/// A small XHTML reader: EPUB chapters are well-formed XML, so a tokenizer is enough (no package needed).
library;

sealed class XNode {
  XElement? parent;
}

class XText extends XNode {
  XText(this.text);
  final String text;
}

class XElement extends XNode {
  XElement(this.name, this.attributes);
  final String name; // local name, lower case ("p", "span", "img")
  final Map<String, String> attributes;
  final List<XNode> children = [];

  String? attr(String n) => attributes[n];
  List<String> get classes => (attributes['class'] ?? '').split(RegExp(r'\s+')).where((c) => c.isNotEmpty).toList();
  String? get id => attributes['id'];

  Iterable<XElement> get elements => children.whereType<XElement>();
  XElement? find(String n) {
    for (final e in elements) {
      if (e.name == n) return e;
      final f = e.find(n);
      if (f != null) return f;
    }
    return null;
  }
}

final _tag = RegExp(r'<(/?)([A-Za-z_][\w:.-]*)((?:\s+[^\s=/>]+(?:\s*=\s*(?:"[^"]*"|' "'[^']*'" r'|[^\s>]+))?)*)\s*(/?)>');
final _attr = RegExp(r'([^\s=/>]+)(?:\s*=\s*(?:"([^"]*)"|' "'([^']*)'" r'|([^\s>]+)))?');

/// Parses a document; returns its root element (a synthetic "#root" holding the top-level nodes).
XElement parseXhtml(String src) {
  final root = XElement('#root', const {});
  var cur = root;
  var i = 0;
  while (i < src.length) {
    final lt = src.indexOf('<', i);
    if (lt < 0) {
      _text(cur, src.substring(i));
      break;
    }
    if (lt > i) _text(cur, src.substring(i, lt));
    if (src.startsWith('<!--', lt)) {
      final e = src.indexOf('-->', lt);
      i = e < 0 ? src.length : e + 3;
      continue;
    }
    if (src.startsWith('<![CDATA[', lt)) {
      final e = src.indexOf(']]>', lt);
      final end = e < 0 ? src.length : e;
      cur.children.add(XText(src.substring(lt + 9, end))..parent = cur);
      i = e < 0 ? src.length : e + 3;
      continue;
    }
    if (src.startsWith('<?', lt) || src.startsWith('<!', lt)) {
      final e = src.indexOf('>', lt);
      i = e < 0 ? src.length : e + 1;
      continue;
    }
    final m = _tag.matchAsPrefix(src, lt);
    if (m == null) {
      _text(cur, '<');
      i = lt + 1;
      continue;
    }
    i = m.end;
    final name = _local(m[2]!);
    if (m[1] == '/') {
      // close the nearest open element of that name (tolerates stray closers)
      for (XElement? e = cur; e != null && e != root; e = e.parent) {
        if (e.name == name) {
          cur = e.parent ?? root;
          break;
        }
      }
      continue;
    }
    final attrs = <String, String>{};
    for (final a in _attr.allMatches(m[3] ?? '')) {
      attrs[_local(a[1]!)] = decodeEntities(a[2] ?? a[3] ?? a[4] ?? '');
    }
    final el = XElement(name, attrs)..parent = cur;
    cur.children.add(el);
    if (m[4] != '/' && !_void.contains(name)) cur = el;
  }
  return root;
}

const _void = {'br', 'img', 'hr', 'meta', 'link', 'input', 'col', 'area', 'base', 'wbr', 'source'};

String _local(String n) {
  final c = n.lastIndexOf(':');
  return (c < 0 ? n : n.substring(c + 1)).toLowerCase();
}

void _text(XElement cur, String raw) {
  if (raw.isEmpty) return;
  cur.children.add(XText(decodeEntities(raw))..parent = cur);
}

final _entity = RegExp(r'&(#x[0-9A-Fa-f]+|#[0-9]+|[A-Za-z]+);');
const _named = {
  'amp': '&', 'lt': '<', 'gt': '>', 'quot': '"', 'apos': "'", 'nbsp': ' ', 'mdash': '—', 'ndash': '–',
  'hellip': '…', 'lsquo': '‘', 'rsquo': '’', 'ldquo': '“', 'rdquo': '”', 'shy': '­',
  'copy': '©', 'eacute': 'é', 'thinsp': ' ', 'emsp': ' ', 'ensp': ' ',
};

String decodeEntities(String s) => s.contains('&')
    ? s.replaceAllMapped(_entity, (m) {
        final e = m[1]!;
        if (e.startsWith('#x')) return String.fromCharCode(int.parse(e.substring(2), radix: 16));
        if (e.startsWith('#')) return String.fromCharCode(int.parse(e.substring(1)));
        return _named[e] ?? m[0]!;
      })
    : s;
