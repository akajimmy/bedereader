import 'package:flutter/material.dart';

import '../settings.dart';
import 'setting_rows.dart';

/// The EPUB settings rows (one set for every book, synced): the reader's Aa panel and Settings > Books use them.
List<Widget> epubSettingRows(BuildContext context, EpubPrefs e, ValueChanged<EpubPrefs> set) {
  final i = EpubPrefs.sizes.indexOf(e.size);
  final at = i < 0 ? EpubPrefs.sizes.indexWhere((s) => s >= e.size) : i;
  void size(int by) => set(e.copyWith(size: EpubPrefs.sizes[(at + by).clamp(0, EpubPrefs.sizes.length - 1)]));
  return [
    SettingsGroup(title: 'Text', children: [
      // the fonts under the label, full width, wrapping onto more lines as needed - beside it, they were scaled down
      // to fit the side sheet until the names couldn't be read (user, 2026-10-06)
      const SettingRow(title: 'Font'),
      Padding(
        padding: const EdgeInsets.fromLTRB(14, 0, 14, 8),
        child: Wrap(spacing: 6, runSpacing: 6, children: [
          for (final f in EpubFont.values)
            ChoiceChip(
              label: Text(f.label, style: TextStyle(fontFamily: f.family, fontSize: 14)),
              selected: e.font == f,
              onSelected: (_) => set(e.copyWith(font: f)),
            ),
        ]),
      ),
      SettingRow(
        title: 'Size',
        trailing: Row(mainAxisSize: MainAxisSize.min, children: [
          IconButton(icon: const Icon(Icons.text_decrease), tooltip: 'Smaller', onPressed: at > 0 ? () => size(-1) : null),
          SizedBox(width: 40, child: Text('${e.size.round()}', textAlign: TextAlign.center)),
          IconButton(icon: const Icon(Icons.text_increase), tooltip: 'Larger',
              onPressed: at < EpubPrefs.sizes.length - 1 ? () => size(1) : null),
        ]),
      ),
      SegmentRow<double>(
        title: 'Line spacing',
        choices: const [Choice(1.25, 'Tight'), Choice(1.45, 'Normal'), Choice(1.7, 'Loose')],
        value: EpubPrefs.spacings.contains(e.lineSpacing) ? e.lineSpacing : 1.45,
        onChanged: (v) => set(e.copyWith(lineSpacing: v)),
      ),
      SegmentRow<EpubParagraphGap>(
        title: 'Paragraph spacing',
        choices: [for (final g in EpubParagraphGap.values) Choice(g, g.label)],
        value: e.paragraphGap,
        onChanged: (v) => set(e.copyWith(paragraphGap: v)),
      ),
      SegmentRow<EpubMargins>(
        title: 'Margins',
        choices: [for (final m in EpubMargins.values) Choice(m, m.label)],
        value: e.margins,
        onChanged: (v) => set(e.copyWith(margins: v)),
      ),
      SettingRow(
        title: 'Theme',
        trailing: Row(mainAxisSize: MainAxisSize.min, children: [
          for (final c in EpubColours.values)
            ColourSwatch(colour: c.background, label: c.label, selected: e.colours == c,
                onTap: () => set(e.copyWith(colours: c))),
        ]),
      ),
      SwitchRow(
        title: "Book's formatting",
        subtitle: e.bookFormatting
            ? "The publisher's alignment, indents and spacing"
            : 'Off: every book justified, paragraphs indented, no gaps',
        value: e.bookFormatting,
        onChanged: (v) => set(e.copyWith(bookFormatting: v)),
      ),
    ]),
    SettingsGroup(title: 'Pages', children: [
      SegmentRow<EpubTurn>(
        title: 'Page turn',
        choices: const [Choice(EpubTurn.slide, 'Slide'), Choice(EpubTurn.none, 'None')],
        value: e.turn,
        onChanged: (v) => set(e.copyWith(turn: v)),
      ),
      SegmentRow<EpubCorner>(
        title: 'Page corner',
        subtitle: 'Pages left in the chapter and how far through the book',
        choices: const [
          Choice(EpubCorner.always, 'Always'),
          Choice(EpubCorner.afterTurn, 'After a turn'),
          Choice(EpubCorner.off, 'Off'),
        ],
        value: e.corner,
        onChanged: (v) => set(e.copyWith(corner: v)),
      ),
    ]),
  ];
}
