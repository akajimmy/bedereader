import 'package:flutter/material.dart';

import '../screen.dart';
import '../settings.dart';
import 'display_panel.dart';
import 'setting_rows.dart';

/// The EPUB set's synced groups (one set for every book, through Komga) for Settings > eBooks: Text, Formatting and
/// Page.
List<Widget> epubSettingRows(BuildContext context, EpubPrefs e, ValueChanged<EpubPrefs> set) => [
      SettingsGroup(title: 'Text', synced: true, children: [
        ..._fontRows(e, set),
        _sizeRow(e, set),
        _lineSpacingRow(e, set),
        _paragraphGapRow(e, set),
        _marginsRow(e, set),
      ]),
      SettingsGroup(title: 'Formatting', synced: true, children: _formattingRows(e, set)),
      SettingsGroup(title: 'Page', synced: true, children: [
        _coloursRow(e, set),
        SegmentRow<EpubTurn>(
          title: 'Page turn',
          choices: const [Choice(EpubTurn.none, 'None'), Choice(EpubTurn.slide, 'Slide')],
          value: e.turn,
          onChanged: (v) => set(e.copyWith(turn: v)),
        ),
      ]),
    ];

/// The eBook reader's panel, "eBook settings" (user, 2026-10-07): what's changed mid-book - the text, its
/// formatting, then the page colours, position text and this device's screen.
List<Widget> epubPanelRows(BuildContext context, AppSettings s) {
  final e = s.epub;
  final set = s.setEpub;
  return [
    SettingsGroup(title: 'Text', children: [
      _sizeRow(e, set),
      ..._fontRows(e, set),
      _lineSpacingRow(e, set),
      _paragraphGapRow(e, set),
      _marginsRow(e, set),
    ]),
    SettingsGroup(title: 'Formatting', children: _formattingRows(e, set)),
    SettingsGroup(title: 'Reading', children: [
      _coloursRow(e, set),
      positionTextRow(s, BookKind.ebooks),
      ...brightnessRows(s),
      if (canRotate) rotationRow(s, BookKind.ebooks),
      screenOnRow(s),
    ]),
  ];
}

// the fonts under the label, full width, wrapping onto more lines as needed - beside it, they were scaled down to fit
// the side sheet until the names couldn't be read (user, 2026-10-06). One row with its label, so the chips have room
// above them (user, 2026-10-07: they sat against the line above)
List<Widget> _fontRows(EpubPrefs e, ValueChanged<EpubPrefs> set) => [
      Padding(
        padding: const EdgeInsets.fromLTRB(14, 10, 14, 10),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Text('Font face', style: TextStyle(fontSize: 14.5)),
          const SizedBox(height: 8),
          Wrap(spacing: 6, runSpacing: 6, children: [
            for (final f in EpubFont.values)
              ChoiceChip(
                label: Text(f.label, style: TextStyle(fontFamily: f.family, fontSize: 14)),
                selected: e.font == f,
                onSelected: (_) => set(e.copyWith(font: f)),
              ),
          ]),
        ]),
      ),
    ];

Widget _sizeRow(EpubPrefs e, ValueChanged<EpubPrefs> set) {
  final i = EpubPrefs.sizes.indexOf(e.size);
  final at = i < 0 ? EpubPrefs.sizes.indexWhere((s) => s >= e.size) : i;
  void size(int by) => set(e.copyWith(size: EpubPrefs.sizes[(at + by).clamp(0, EpubPrefs.sizes.length - 1)]));
  return SettingRow(
    title: 'Font size',
    trailing: Row(mainAxisSize: MainAxisSize.min, children: [
      IconButton(icon: const Icon(Icons.text_decrease), tooltip: 'Smaller', onPressed: at > 0 ? () => size(-1) : null),
      SizedBox(width: 40, child: Text('${e.size.round()}', textAlign: TextAlign.center)),
      IconButton(icon: const Icon(Icons.text_increase), tooltip: 'Larger',
          onPressed: at < EpubPrefs.sizes.length - 1 ? () => size(1) : null),
    ]),
  );
}

Widget _lineSpacingRow(EpubPrefs e, ValueChanged<EpubPrefs> set) => SegmentRow<double>(
      title: 'Line spacing',
      choices: const [Choice(1.25, 'Tight'), Choice(1.45, 'Normal'), Choice(1.7, 'Loose')],
      value: EpubPrefs.spacings.contains(e.lineSpacing) ? e.lineSpacing : 1.45,
      onChanged: (v) => set(e.copyWith(lineSpacing: v)),
    );

Widget _paragraphGapRow(EpubPrefs e, ValueChanged<EpubPrefs> set) => SegmentRow<EpubParagraphGap>(
      title: 'Paragraph spacing',
      choices: [for (final g in EpubParagraphGap.values) Choice(g, g.label)],
      value: e.paragraphGap,
      onChanged: (v) => set(e.copyWith(paragraphGap: v)),
    );

Widget _marginsRow(EpubPrefs e, ValueChanged<EpubPrefs> set) => SegmentRow<EpubMargins>(
      title: 'Margins',
      choices: [for (final m in EpubMargins.values) Choice(m, m.label)],
      value: e.margins,
      onChanged: (v) => set(e.copyWith(margins: v)),
    );

// "Book's formatting" in three (user, 2026-10-07)
List<Widget> _formattingRows(EpubPrefs e, ValueChanged<EpubPrefs> set) => [
      SegmentRow<EpubAlign>(
        title: 'Alignment',
        choices: [for (final a in EpubAlign.values) Choice(a, a.label)],
        value: e.align,
        onChanged: (v) => set(e.copyWith(align: v)),
      ),
      SegmentRow<EpubParagraphs>(
        title: 'Paragraphs',
        subtitle: 'Indents and the gaps between them',
        choices: [for (final p in EpubParagraphs.values) Choice(p, p.label)],
        value: e.paragraphs,
        onChanged: (v) => set(e.copyWith(paragraphs: v)),
      ),
      SwitchRow(
        title: 'Auto-hyphenation',
        value: e.hyphenate,
        onChanged: (v) => set(e.copyWith(hyphenate: v)),
      ),
    ];

// "Page colours", as comics' (user, 2026-10-07: it was "Theme")
Widget _coloursRow(EpubPrefs e, ValueChanged<EpubPrefs> set) => SettingRow(
      title: 'Page colours',
      trailing: Row(mainAxisSize: MainAxisSize.min, children: [
        for (final c in EpubColours.values)
          ColourSwatch(colour: c.background, label: c.label, selected: e.colours == c,
              onTap: () => set(e.copyWith(colours: c))),
      ]),
    );
