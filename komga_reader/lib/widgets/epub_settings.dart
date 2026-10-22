import 'package:flutter/material.dart';

import '../api.dart';
import '../screen.dart';
import '../screens/app_settings.dart' show SettingsPage;
import '../settings.dart';
import 'display_panel.dart';
import 'setting_rows.dart';

/// The EPUB set's synced groups (one set for every book, through Komga) for Settings > eBooks: Text, Formatting, Page
/// and Two pages. Two pages (user, 2026-10-21: in one group, the rows that don't apply hidden): [insetRow] (this
/// device's Inset page, as [inset] is set), Dual page mode, then - two pages up - Chapters start on, and with an inset
/// page the Gutter between the sheets.
List<Widget> epubSettingRows(BuildContext context, EpubPrefs e, ValueChanged<EpubPrefs> set,
        {Widget? insetRow, InsetPage inset = InsetPage.wideScreen}) => [
      SettingsGroup(title: 'Text', synced: true, children: [
        ..._fontRows(e, set),
        _sizeRow(e, set),
        _lineSpacingRow(e, set),
        _paragraphGapRow(e, set),
        _marginsRow(e, set),
      ]),
      SettingsGroup(title: 'Formatting', synced: true, children: _formattingRows(e, set)),
      SettingsGroup(title: 'Page', synced: true, children: [_coloursRow(e, set)]),
      SettingsGroup(title: 'Two pages', synced: true, children: [
        if (insetRow != null) insetRow,
        _twoPagesRow(e, set),
        if (e.twoPages != TwoPages.off) _chapterStartRow(e, set),
        if (e.twoPages != TwoPages.off && inset != InsetPage.never) _gutterRow(e, set),
      ]),
    ];

/// The eBook reader's panel, "eBook settings": what's changed mid-book (user, 2026-10-21, trimmed): font, size, line
/// spacing, margins; page colours, dual page mode; brightness, rotation - the rest in Settings > eBooks ([api]: More
/// settings, a tap away).
List<Widget> epubPanelRows(BuildContext context, AppSettings s, {Komga? api}) {
  final e = s.epub;
  final set = s.setEpub;
  return [
    SettingsGroup(title: 'Text', children: [
      ..._fontRows(e, set),
      _sizeRow(e, set),
      _lineSpacingRow(e, set),
      _marginsRow(e, set),
    ]),
    SettingsGroup(title: 'Page', children: [
      _coloursRow(e, set),
      _twoPagesRow(e, set),
    ]),
    SettingsGroup(title: 'Screen', children: [
      ...brightnessRows(s),
      if (canRotate) rotationRow(s),
    ]),
    if (api != null) moreSettingsRow(context, api, SettingsPage.ebooks),
  ];
}

/// eBooks' page turn - this device's (user, 2026-10-21; it was synced), called as comics' is.
Widget epubTurnRow(AppSettings s) => SegmentRow<EpubTurn>(
      title: 'Page turn',
      choices: const [Choice(EpubTurn.none, 'None'), Choice(EpubTurn.slide, 'Slide'), Choice(EpubTurn.curl, 'Curl')],
      value: s.display.epubTurn,
      onChanged: (v) => s.setDisplay(s.display.copyWith(epubTurn: v)),
    );

/// Dual page mode (user, 2026-10-16: eBooks as comics - in the reader's panel, synced).
Widget _twoPagesRow(EpubPrefs e, ValueChanged<EpubPrefs> set) => SegmentRow<TwoPages>(
      title: 'Dual page mode',
      choices: const [
        Choice(TwoPages.off, 'Off'),
        Choice(TwoPages.wideScreen, 'Wide screen'),
        Choice(TwoPages.always, 'Always'),
      ],
      value: e.twoPages,
      onChanged: (t) => set(e.copyWith(twoPages: t)),
    );

/// Dual page mode with Inset page: the space between the two sheets (user, 2026-10-20; three steps since 2026-10-21).
Widget _gutterRow(EpubPrefs e, ValueChanged<EpubPrefs> set) => SegmentRow<double>(
      title: 'Gutter',
      choices: [for (final g in EpubPrefs.gutters) Choice(g, '${g.round()} px')],
      value: EpubPrefs.gutters.contains(e.gutter) ? e.gutter : EpubPrefs.defaultGutter,
      onChanged: (g) => set(e.copyWith(gutter: g)),
    );

/// Dual page mode: where a chapter starts (user, 2026-10-18: "A setting") - the next page, or a right-hand one.
Widget _chapterStartRow(EpubPrefs e, ValueChanged<EpubPrefs> set) => SegmentRow<ChapterStart>(
      title: 'Chapters start on',
      choices: const [Choice(ChapterStart.nextPage, 'Next page'), Choice(ChapterStart.rightPage, 'Right-hand page')],
      value: e.chapterStart,
      onChanged: (v) => set(e.copyWith(chapterStart: v)),
    );

// the current font, in its own face; a tap (or OK) opens the list - each font drawn in itself with a line of sample
// text (user, 2026-10-21: "font face doesn't need to display all of them. show current, when tapped, give choice ...
// not just an ugly dropdown"). The six chips took three lines in the panel.
List<Widget> _fontRows(EpubPrefs e, ValueChanged<EpubPrefs> set) => [
      SettingRow(title: 'Font face', trailing: FontPicker(value: e.font, onChanged: (f) => set(e.copyWith(font: f)))),
    ];

/// The current font as a button in its own face; pressed, the fonts to pick from ([showFontMenu]).
class FontPicker extends StatelessWidget {
  const FontPicker({super.key, required this.value, required this.onChanged});
  final EpubFont value;
  final ValueChanged<EpubFont> onChanged;

  @override
  Widget build(BuildContext context) => TextButton(
        style: TextButton.styleFrom(
          backgroundColor: const Color(0xFF22242A),
          foregroundColor: const Color(0xFFDADADA),
          padding: const EdgeInsets.fromLTRB(12, 6, 8, 6),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
          visualDensity: VisualDensity.compact,
        ),
        onPressed: () async {
          final picked = await showFontMenu(context, value);
          if (picked != null && picked != value) onChanged(picked);
        },
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Text(value.label, style: TextStyle(fontFamily: value.family, fontSize: 15)),
          const SizedBox(width: 4),
          const Icon(Icons.expand_more, size: 18, color: hintColour),
        ]),
      );
}

/// The fonts as a list under [context]'s button: each name in its own face beside a line of sample text, the current
/// one marked. The font picked, or null.
Future<EpubFont?> showFontMenu(BuildContext context, EpubFont current) {
  final box = context.findRenderObject()! as RenderBox;
  final overlay = Navigator.of(context).overlay!.context.findRenderObject()! as RenderBox;
  final at = box.localToGlobal(Offset(0, box.size.height), ancestor: overlay);
  final accent = Theme.of(context).colorScheme.primary;
  return showMenu<EpubFont>(
    context: context,
    position: RelativeRect.fromLTRB(at.dx, at.dy, overlay.size.width - at.dx - box.size.width, 0),
    initialValue: current,
    color: const Color(0xFF202227),
    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
    items: [
      for (final f in EpubFont.values)
        PopupMenuItem(
          value: f,
          child: SizedBox(width: 300, child: Row(children: [
            SizedBox(width: 150, child: Text(f.label, style: TextStyle(fontFamily: f.family, fontSize: 17))),
            Expanded(child: Text('The quick brown fox', maxLines: 1, overflow: TextOverflow.ellipsis,
                style: TextStyle(fontFamily: f.family, fontSize: 13, color: hintColour))),
            if (f == current) Icon(Icons.check, size: 18, color: accent),
          ])),
        ),
    ],
  );
}

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

/// Line spacing's three steps (user, 2026-10-21).
Widget _lineSpacingRow(EpubPrefs e, ValueChanged<EpubPrefs> set) => SegmentRow<double>(
      title: 'Line spacing',
      choices: const [Choice(1.25, 'Tight'), Choice(1.5, 'Normal'), Choice(1.75, 'Loose')],
      value: nearestSpacing(e.lineSpacing),
      onChanged: (v) => set(e.copyWith(lineSpacing: v)),
    );

/// The line-spacing step nearest [spacing].
double nearestSpacing(double spacing) =>
    EpubPrefs.spacings.reduce((a, b) => (b - spacing).abs() < (a - spacing).abs() ? b : a);

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
