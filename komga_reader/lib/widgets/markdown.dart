import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import '../screen.dart';

/// A small Markdown renderer for the app's own documents (README, CHANGELOG - About > Read me / What's new). Covers
/// what they use: # headings (1-3), paragraphs, "- " bullets (one level of nesting) and "1. " lists, **bold**,
/// *italic*, `code`, [links](url), ``` code blocks, | tables | and blank-line spacing. Not a general Markdown engine.
class MarkdownView extends StatelessWidget {
  const MarkdownView(this.text, {super.key, this.padding = const EdgeInsets.fromLTRB(20, 12, 20, 40), this.controller});
  final String text;
  final EdgeInsets padding;
  final ScrollController? controller; // the remote's arrows scroll it (widgets/arrow_scroll.dart)

  @override
  Widget build(BuildContext context) {
    final blocks = parseBlocks(text);
    return ListView.builder(
      controller: controller,
      padding: padding,
      itemCount: blocks.length,
      itemBuilder: (context, i) => blocks[i].build(context),
    );
  }

  /// The document as blocks (headings, paragraphs, list items, code, tables), for [MarkdownView] and tests.
  static List<MdBlock> parseBlocks(String text) {
    final lines = text.replaceAll('\r\n', '\n').split('\n');
    final out = <MdBlock>[];
    var i = 0;
    String? para;
    void flush() {
      if (para != null) out.add(MdParagraph(para!.trim()));
      para = null;
    }

    while (i < lines.length) {
      final line = lines[i];
      final t = line.trim();
      if (t.startsWith('```')) {
        flush();
        final code = <String>[];
        i++;
        while (i < lines.length && !lines[i].trim().startsWith('```')) {
          code.add(lines[i]);
          i++;
        }
        out.add(MdCode(code.join('\n')));
        i++;
        continue;
      }
      if (t.isEmpty) {
        flush();
        i++;
        continue;
      }
      // badge lines ([![label](image)](link) / ![label](image)) are for GitHub; images aren't shown here
      if (RegExp(r'^\[?!\[[^\]]*\]\([^)]*\)(\]\([^)]*\))?$').hasMatch(t)) {
        flush();
        i++;
        continue;
      }
      final h = RegExp(r'^(#{1,3})\s+(.*)$').firstMatch(t);
      if (h != null) {
        flush();
        out.add(MdHeading(h.group(1)!.length, h.group(2)!));
        i++;
        continue;
      }
      if (t.startsWith('|')) {
        flush();
        final rows = <List<String>>[];
        while (i < lines.length && lines[i].trim().startsWith('|')) {
          final cells = lines[i].trim().replaceAll(RegExp(r'^\||\|$'), '').split('|').map((c) => c.trim()).toList();
          if (!cells.every((c) => RegExp(r'^:?-+:?$').hasMatch(c))) rows.add(cells); // skip the |---| line
          i++;
        }
        out.add(MdTable(rows));
        continue;
      }
      final bullet = RegExp(r'^(\s*)[-*]\s+(.*)$').firstMatch(line);
      final number = RegExp(r'^(\s*)(\d+)\.\s+(.*)$').firstMatch(line);
      if (bullet != null || number != null) {
        flush();
        final indent = (bullet?.group(1) ?? number!.group(1)!).length >= 2 ? 1 : 0;
        var body = bullet?.group(2) ?? number!.group(3)!;
        final marker = bullet != null ? '•' : '${number!.group(2)}.';
        i++;
        // continuation lines (indented further, not a new item)
        while (i < lines.length &&
            lines[i].trim().isNotEmpty &&
            lines[i].startsWith(' ') &&
            !RegExp(r'^\s*([-*]|\d+\.)\s+').hasMatch(lines[i])) {
          body += ' ${lines[i].trim()}';
          i++;
        }
        out.add(MdListItem(marker, body, indent));
        continue;
      }
      para = para == null ? t : '$para $t';
      i++;
    }
    flush();
    return out;
  }
}

/// Inline Markdown ( **bold**, *italic*, `code`, [text](url) ) as text spans.
List<InlineSpan> inlineSpans(String s, TextStyle base, {Color? link}) {
  final spans = <InlineSpan>[];
  final re = RegExp(r'\*\*(.+?)\*\*|\*(.+?)\*|`(.+?)`|\[(.+?)\]\((.+?)\)');
  var at = 0;
  for (final m in re.allMatches(s)) {
    if (m.start > at) spans.add(TextSpan(text: s.substring(at, m.start), style: base));
    if (m.group(1) != null) {
      spans.addAll(inlineSpans(m.group(1)!, base.copyWith(fontWeight: FontWeight.w700), link: link));
    } else if (m.group(2) != null) {
      spans.add(TextSpan(text: m.group(2), style: base.copyWith(fontStyle: FontStyle.italic)));
    } else if (m.group(3) != null) {
      spans.add(TextSpan(
          text: m.group(3),
          style: base.copyWith(fontFamily: 'monospace', backgroundColor: const Color(0xFF22242A), fontSize: (base.fontSize ?? 14) * 0.92)));
    } else {
      final url = m.group(5)!;
      spans.add(TextSpan(
        text: m.group(4),
        style: base.copyWith(color: link, decoration: TextDecoration.underline),
        recognizer: url.startsWith('http') ? (TapGestureRecognizer()..onTap = () => openUrl(url)) : null,
      ));
    }
    at = m.end;
  }
  if (at < s.length) spans.add(TextSpan(text: s.substring(at), style: base));
  return spans;
}

abstract class MdBlock {
  Widget build(BuildContext context);
}

class MdHeading extends MdBlock {
  MdHeading(this.level, this.text);
  final int level;
  final String text;
  @override
  Widget build(BuildContext context) {
    final size = switch (level) { 1 => 26.0, 2 => 20.0, _ => 16.5 };
    return Padding(
      padding: EdgeInsets.only(top: level == 1 ? 4 : 18, bottom: 6),
      child: Text.rich(TextSpan(children: inlineSpans(text,
          TextStyle(fontSize: size, fontWeight: FontWeight.w600,
              color: level == 3 ? Theme.of(context).colorScheme.primary : null), // the accent colour
          link: Theme.of(context).colorScheme.primary))),
    );
  }
}

class MdParagraph extends MdBlock {
  MdParagraph(this.text);
  final String text;
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 10),
        child: Text.rich(TextSpan(children: inlineSpans(text, const TextStyle(fontSize: 15, height: 1.45),
            link: Theme.of(context).colorScheme.primary))),
      );
}

class MdListItem extends MdBlock {
  MdListItem(this.marker, this.text, this.indent);
  final String marker, text;
  final int indent;
  @override
  Widget build(BuildContext context) => Padding(
        padding: EdgeInsets.only(left: 6.0 + indent * 20, bottom: 5),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          SizedBox(width: 20, child: Text(marker, style: const TextStyle(fontSize: 15, height: 1.45, color: Color(0xFF9A9A9A)))),
          Expanded(child: Text.rich(TextSpan(children: inlineSpans(text, const TextStyle(fontSize: 15, height: 1.45),
              link: Theme.of(context).colorScheme.primary)))),
        ]),
      );
}

class MdCode extends MdBlock {
  MdCode(this.code);
  final String code;
  @override
  Widget build(BuildContext context) => Container(
        margin: const EdgeInsets.only(bottom: 12),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(color: const Color(0xFF16171B), borderRadius: BorderRadius.circular(8),
            border: Border.all(color: const Color(0xFF26282E))),
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: SelectableText(code, style: const TextStyle(fontFamily: 'monospace', fontSize: 13, height: 1.4)),
        ),
      );
}

class MdTable extends MdBlock {
  MdTable(this.rows);
  final List<List<String>> rows;
  @override
  Widget build(BuildContext context) {
    if (rows.isEmpty) return const SizedBox.shrink();
    final cols = rows.map((r) => r.length).reduce((a, b) => a > b ? a : b);
    final link = Theme.of(context).colorScheme.primary;
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Table(
        border: TableBorder.all(color: const Color(0xFF2A2C33)),
        defaultColumnWidth: const IntrinsicColumnWidth(flex: 1),
        children: [
          for (var r = 0; r < rows.length; r++)
            TableRow(
              decoration: r == 0 ? const BoxDecoration(color: Color(0xFF1A1B20)) : null,
              children: [
                for (var c = 0; c < cols; c++)
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                    child: Text.rich(TextSpan(children: inlineSpans(c < rows[r].length ? rows[r][c] : '',
                        TextStyle(fontSize: 14, fontWeight: r == 0 ? FontWeight.w600 : null), link: link))),
                  ),
              ],
            ),
        ],
      ),
    );
  }
}
