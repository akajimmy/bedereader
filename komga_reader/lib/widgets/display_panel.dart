import 'package:flutter/material.dart';

import '../api.dart';
import '../reader/position_row.dart';
import '../screens/app_settings.dart';
import '../synced_ids.dart';
import '../screen.dart';
import '../settings.dart';
import 'setting_rows.dart';

/// The reader's two settings panels, opened from its bottom bar: side sheets on a wide screen (the page stays in
/// view), bottom sheets on a narrow one. Changes show live. Remote: Up/Down move between rows, Left/Right adjust a
/// slider or move along segmented buttons, OK presses; "Done" closes the panel.
///
/// * Comic settings: Save / Copy page, this book's pairing, fit, reading direction and page colours (this series),
///   then the screen: brightness and rotation (user, 2026-10-21: trimmed - the rest is a tap away, "More settings").
///   Night mode is the top bar's moon.
/// * Image: Enhance, Enhance colours, crop, brightness, contrast (this series); Reset to original and Make default.
///
/// Each panel's series group starts with "Override defaults" (user, 2026-09-30; shorter, no line under it - 2026-10-07): off, the series follows the
/// defaults for that part (page layout, or image) and its controls are greyed out showing the default values; on,
/// they're the series' own - starting from the defaults, so nothing jumps. The two parts are separate.
///
/// The row builders below are shared with the Settings screen, so a setting looks the same in both places.
/// [page]: Save page / Copy page for the page shown (null where there's no page to save, or no way to).
/// [shiftBook]: two pages up, this book's "Shift pairing by one" ([shift] flips it) - null otherwise.
/// [api]: for More settings (null: no such row).
Future<void> showReaderPanel(BuildContext context, {String? seriesId, String? seriesTitle, String? komgaDirection,
        FitMode? bookFit, PageActions? page, String? shiftBook, VoidCallback? shift, Komga? api}) =>
    _show(context, (side) => _ReaderPanel(seriesId: seriesId, seriesTitle: seriesTitle, komgaDirection: komgaDirection,
        bookFit: bookFit, page: page, shiftBook: shiftBook, shift: shift, api: api, side: side));

/// The panels' last row, "More settings" (user, 2026-10-21: the panels trimmed to what's changed mid-book): closes the
/// panel and opens Settings at [page] - only the reading pages ([page] and Reading), so nothing there leaves the book
/// (no sign out, no server).
Widget moreSettingsRow(BuildContext context, Komga api, SettingsPage page) => SettingsGroup(children: [
      ActionRow(
        title: 'More settings',
        subtitle: 'Settings > ${page.label}',
        onTap: () {
          final nav = Navigator.of(context);
          nav.pop(); // the panel
          nav.push(MaterialPageRoute<void>(builder: (_) => AppSettingsScreen(api: api, onSignOut: () {},
              initialPage: page, only: [SettingsPage.reading, page])));
        },
      ),
    ]);

/// The reader's Save page and Copy page (user, 2026-10-02): on one line at the top of its panel.
class PageActions {
  const PageActions({required this.save, required this.copy});
  final VoidCallback save, copy;
}

class _PageActionsRow extends StatelessWidget {
  const _PageActionsRow(this.actions);
  final PageActions actions;
  @override
  Widget build(BuildContext context) => RowNav(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 6, 14, 10),
          child: Row(children: [
            Expanded(
              child: OutlinedButton.icon(onPressed: actions.save, icon: const Icon(Icons.save_alt, size: 20),
                  label: const Text('Save page')),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: OutlinedButton.icon(onPressed: actions.copy, icon: const Icon(Icons.copy, size: 20),
                  label: const Text('Copy page')),
            ),
          ]),
        ),
      );
}

Future<void> showImagePanel(BuildContext context, {required String seriesId, String? seriesTitle}) =>
    _show(context, (side) => _ImagePanel(seriesId: seriesId, seriesTitle: seriesTitle, side: side));

/// Any reader panel in the comic reader's look (user, 2026-10-06: the EPUB reader's panels should look like these):
/// a side sheet on a wide screen, a bottom sheet on a narrow one, [title] and Done, then [children] (rebuilt as
/// the settings change).
Future<void> showReaderPanelFrame(BuildContext context, {required String title,
        required List<Widget> Function(BuildContext context, AppSettings s) children}) =>
    _show(context, (side) => _Panel(title: title, side: side, groups: (s) => children(context, s)));

const _sheetColour = Color(0xF2141416);
// (user, 2026-10-21: 380 broke most rows onto two lines - "the look is cluttered")
const sideWidth = 460.0;

Future<void> _show(BuildContext context, Widget Function(bool side) panel) {
  if (MediaQuery.sizeOf(context).width < 700) {
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      barrierColor: Colors.transparent,
      backgroundColor: _sheetColour,
      constraints: const BoxConstraints(maxWidth: 640),
      builder: (_) => panel(false),
    );
  }
  return showGeneralDialog<void>(
    context: context,
    barrierDismissible: true, // a tap on the page closes it, like the bottom sheet
    barrierLabel: 'Close',
    barrierColor: Colors.transparent,
    transitionDuration: const Duration(milliseconds: 200),
    pageBuilder: (context, _, __) => Align(
      alignment: Alignment.centerRight,
      child: SizedBox(
        width: sideWidth,
        height: double.infinity,
        child: Material(color: _sheetColour, child: SafeArea(left: false, child: panel(true))),
      ),
    ),
    transitionBuilder: (context, a, _, child) => SlideTransition(
      position: Tween(begin: const Offset(1, 0), end: Offset.zero).animate(CurvedAnimation(parent: a, curve: Curves.easeOut)),
      child: child,
    ),
  );
}

/// Shared frame: title and Done, the groups, any Komga sync problem at the bottom.
class _Panel extends StatelessWidget {
  const _Panel({required this.title, required this.groups, required this.side});
  final String title;
  final bool side;
  final List<Widget> Function(AppSettings s) groups;

  @override
  Widget build(BuildContext context) {
    final s = AppSettings.instance;
    return ListenableBuilder(
      listenable: s,
      builder: (context, _) {
        final list = ListView(shrinkWrap: !side, padding: const EdgeInsets.fromLTRB(14, 4, 14, 16), children: [
          Row(children: [
            Expanded(child: Text(title, style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w500))),
            TextButton(autofocus: true, onPressed: () => Navigator.of(context).pop(), child: const Text('Done')),
          ]),
          const SizedBox(height: 6),
          // the panel's segmented choices share one width
          Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: groups(s)),
          if (s.syncError != null)
            Text(s.syncError!, style: const TextStyle(color: Color(0xFFFFB74D), fontSize: 12)),
        ]);
        if (side) return list;
        return SafeArea(
          child: ConstrainedBox(
            constraints: BoxConstraints(maxHeight: MediaQuery.of(context).size.height * 0.7),
            child: list,
          ),
        );
      },
    );
  }
}

/// "Settings for Series: *name*" - both panels' series group (user, 2026-09-30).
String _seriesHeading(String? title) => title == null ? 'Settings for this series' : 'Settings for Series: $title';

class _ReaderPanel extends StatelessWidget {
  const _ReaderPanel({this.seriesId, this.seriesTitle, this.komgaDirection, this.bookFit, this.page, this.shiftBook,
      this.shift, this.api, required this.side});
  final Komga? api;
  final PageActions? page;
  final String? shiftBook;
  final VoidCallback? shift;
  final String? seriesId;
  final String? seriesTitle;
  final String? komgaDirection; // the series' reading direction in Komga, for Auto
  final FitMode? bookFit; // a fit for this book only, from the top bar (while the series follows the defaults)
  final bool side;

  @override
  Widget build(BuildContext context) {
    return _Panel(title: 'Comic settings', side: side, groups: (s) {
      final id = seriesId;
      final p = s.prefsFor(id);
      final own = id != null && s.ownsLayout(id);
      return [
        if (page != null) SettingsGroup(title: 'This page', children: [_PageActionsRow(page!)]),
        // two pages up: this book's pairing, a page off (user, 2026-10-22: "does not need to be a top level button" -
        // it was on the bottom bar)
        if (shiftBook != null && shift != null)
          SettingsGroup(title: 'This book', children: [
            ListenableBuilder(
              listenable: PairShift.instance,
              builder: (context, _) => SwitchRow(
                title: 'Shift pairing by one',
                subtitle: 'The pages up to the first spread pair the other way',
                value: PairShift.instance.shifted(shiftBook!),
                onChanged: (_) => shift!(),
              ),
            ),
          ]),
        if (id != null)
          SettingsGroup(title: _seriesHeading(seriesTitle), children: [
            // on: this series' own fit and direction; off: the defaults', greyed out (user, 2026-09-30)
            SwitchRow(
              title: 'Override defaults',
              value: own,
              onChanged: (v) {
                s.setOverride(id, layout: v);
                // on: it starts from what's on screen, including a fit picked for this book - nothing moves (review)
                final f = bookFit;
                if (v && f != null) s.setSeriesLayout(id, s.prefsFor(id).copyWith(fit: f));
              },
            ),
            ...layoutRows(p, (n) => s.setSeriesLayout(id, n), icons: true, komgaDirection: komgaDirection,
                enabled: own),
            if (own)
              ActionRow(
                title: 'Use this layout for new series',
                button: TextButton(
                  onPressed: () {
                    s.setDefault(s.defaults.copyWith(fit: p.fit, direction: p.direction, background: p.background,
                        twoPages: p.twoPages, gutter: p.gutter));
                    _toast(context, "Series you haven't adjusted will open like this one");
                  },
                  child: const Text('Make default'),
                ),
              ),
          ]),
        // what's changed mid-book (user, 2026-10-21: trimmed to these - position text and keep the screen on are in
        // Settings only)
        SettingsGroup(title: 'Screen', children: [
          ...brightnessRows(s),
          if (canRotate) rotationRow(s), // locked mid-book, lying down
        ]),
        if (api != null) moreSettingsRow(context, api!, SettingsPage.comics),
      ];
    });
  }
}

class _ImagePanel extends StatelessWidget {
  const _ImagePanel({required this.seriesId, this.seriesTitle, required this.side});
  final String seriesId;
  final String? seriesTitle;
  final bool side;

  @override
  Widget build(BuildContext context) {
    return _Panel(
      title: 'Image',
      side: side,
      groups: (s) {
        final p = s.prefsFor(seriesId);
        final own = s.ownsImage(seriesId);
        return [
          SettingsGroup(title: _seriesHeading(seriesTitle), children: [
            // on: this series' own image settings; off: the defaults', greyed out (user, 2026-09-30)
            SwitchRow(
              title: 'Override defaults',
              value: own,
              onChanged: (v) => s.setOverride(seriesId, image: v),
            ),
            ...imageRows(p, (n) => s.setSeriesImage(seriesId, n), enabled: own),
          ]),
          // the actions as buttons (user, 2026-09-30: not a ⋮ menu) - only with the override on
          if (own)
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: Wrap(spacing: 8, runSpacing: 8, children: [
                OutlinedButton(
                  // the untouched scan for this series (fit and direction are left alone)
                  onPressed: () => s.setSeriesImage(seriesId, p.imageReset()),
                  child: const Text('Reset to original'),
                ),
                OutlinedButton(
                  onPressed: () {
                    s.setDefault(s.defaults.withImageOf(p));
                    _toast(context, "Series you haven't adjusted will use these image settings");
                  },
                  child: const Text('Make default'),
                ),
              ]),
            ),
        ];
      },
    );
  }
}

void _toast(BuildContext context, String text) =>
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(content: Text(text)));

// ---- rows shared with the Settings screen ---------------------------------------------------------------------------

/// The fit modes' icon: fit screen as the usual frame, fit width and height as double-headed arrows, ↔ and ↕ (user,
/// 2026-09-30 - the swap icons' two arrows read as "swap"). Flutter has only the vertical one (Icons.height), so
/// width is it turned a quarter.
Widget fitIcon(FitMode f, {double size = 20, Color? color}) => switch (f) {
      FitMode.screen => Icon(Icons.fit_screen, size: size, color: color),
      FitMode.width => RotatedBox(quarterTurns: 1, child: Icon(Icons.height, size: size, color: color)),
      FitMode.height => Icon(Icons.height, size: size, color: color),
      // original size: "1:1" (no Material icon says it)
      FitMode.original => SizedBox(width: size, height: size, child: Center(child: Text('1:1',
          style: TextStyle(fontSize: size * 0.55, fontWeight: FontWeight.w800, color: color, height: 1)))),
    };

/// The page layout for [p] (a series, or the defaults): fit, reading direction and background. [icons]: fit and
/// direction as icons (the reader's narrow sheet).
List<Widget> layoutRows(ReaderPrefs p, void Function(ReaderPrefs) setP, {bool icons = false,
    String? komgaDirection, bool enabled = true}) {
  final komga = switch (komgaDirection) {
    'RIGHT_TO_LEFT' => 'right to left',
    'VERTICAL' => 'vertical (read left to right)',
    'WEBTOON' => 'webtoon (read left to right)',
    null => null,
    _ => 'left to right',
  };
  return [
    SegmentRow<FitMode>(
      title: 'Fit',
      choices: [
        Choice(FitMode.screen, icons ? 'Fit screen' : 'Screen', icon: icons ? Icons.fit_screen : null),
        Choice(FitMode.width, icons ? 'Fit width' : 'Width', iconWidget: icons ? fitIcon(FitMode.width) : null),
        Choice(FitMode.height, icons ? 'Fit height' : 'Height', iconWidget: icons ? fitIcon(FitMode.height) : null),
        Choice(FitMode.original, icons ? 'Original size' : 'Original',
            iconWidget: icons ? fitIcon(FitMode.original) : null),
      ],
      value: p.fit,
      onChanged: (f) => setP(p.copyWith(fit: f)),
      enabled: enabled,
    ),
    SegmentRow<ReadingDirection>(
      title: 'Direction',
      subtitle: komga == null ? 'Auto follows Komga' : 'Auto follows Komga: $komga',
      choices: [ // [icons]: a wand for Auto, arrows for the two directions (the names are their tooltips)
        Choice(ReadingDirection.auto, 'Auto', icon: icons ? Icons.auto_fix_high : null),
        Choice(ReadingDirection.ltr, 'Left to right', icon: icons ? Icons.arrow_forward : null),
        Choice(ReadingDirection.rtl, 'Right to left', icon: icons ? Icons.arrow_back : null),
      ],
      value: p.direction,
      onChanged: (d) => setP(p.copyWith(direction: d)),
      enabled: enabled,
    ),
    // two pages side by side (user, 2026-10-16: in the reader's panel, a default a series can override)
    SegmentRow<TwoPages>(
      title: 'Dual page mode',
      subtitle: switch (p.twoPages) {
        TwoPages.off => 'One page at a time',
        TwoPages.wideScreen => 'Two pages side by side when the screen is wider than tall',
        TwoPages.always => 'Two pages side by side, a tall screen too',
      },
      choices: const [
        Choice(TwoPages.off, 'Off'),
        Choice(TwoPages.wideScreen, 'Wide screen'),
        Choice(TwoPages.always, 'Always'),
      ],
      value: p.twoPages,
      onChanged: (t) => setP(p.copyWith(twoPages: t)),
      enabled: enabled,
    ),
    // the space between a pair's pages (user, 2026-10-20; in steps since 2026-10-21), with dual page mode on
    if (p.twoPages != TwoPages.off)
      SegmentRow<double>(
        title: 'Gutter',
        choices: [for (final g in ReaderPrefs.gutters) Choice(g, g == 0 ? 'None' : '${g.round()} px')],
        value: ReaderPrefs.gutters.contains(p.gutter) ? p.gutter : ReaderPrefs.defaultGutter,
        onChanged: (g) => setP(p.copyWith(gutter: g)),
        enabled: enabled,
      ),
    // black, dark grey or white around the page (user, 2026-10-05: a reading default, overridable per series)
    SettingRow(
      title: 'Page colours', // as eBooks' (user, 2026-10-07: it was "Background")
      trailing: IgnorePointer(
        ignoring: !enabled,
        child: Opacity(
          opacity: enabled ? 1 : 0.4, // following the defaults: shown, not set here
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            for (final b in ReaderBackground.values)
              ColourSwatch(colour: b.colour, label: '${b.label} background', selected: p.background == b,
                  onTap: () => setP(p.copyWith(background: b))),
          ]),
        ),
      ),
    ),
  ];
}

/// Enhance and Enhance colours, then Crop edges in four steps (user, 2026-10-21: brightness and contrast went).
List<Widget> imageRows(ReaderPrefs p, void Function(ReaderPrefs) setP, {bool enabled = true}) => [
      SwitchRow(title: 'Enhance', subtitle: 'Cleans up grain and speckle, then sharpens',
          value: p.sharpen, onChanged: enabled ? (v) => setP(p.copyWith(sharpen: v)) : null),
      SwitchRow(title: 'Enhance colours', subtitle: 'Whiter paper, deeper ink',
          value: p.autoLevels, onChanged: enabled ? (v) => setP(p.copyWith(autoLevels: v)) : null),
      SegmentRow<double>(
        title: 'Crop edges',
        choices: [for (final c in ReaderPrefs.crops) Choice(c, c == 0 ? 'Off' : '${(c * 100).round()}%')],
        value: ReaderPrefs.crops.contains(p.crop) ? p.crop : 0,
        onChanged: (c) => setP(p.copyWith(crop: c)),
        enabled: enabled,
      ),
    ];

/// Screen brightness in the reader (this device; everywhere else the screen follows the system): the backlight plus
/// extra dimming on Android, dimming only on a PC. Outside the reader (Settings), the screen takes it while the slider
/// is being used, so it can be seen ([BrightnessPreview]).
List<Widget> brightnessRows(AppSettings s) {
  final d = s.display;
  if (!DisplayPrefs.backlightControl) {
    // a monitor's backlight can't be set, so the slider only dims (right = no dimming)
    return [
      BrightnessPreview(child: SliderRow(
        label: 'Screen brightness',
        divisions: 20, // 5% steps
        value: d.brightness ?? 1,
        valueText: (d.brightness ?? 1) >= 0.995 ? 'Full' : '${((d.brightness ?? 1) * 100).round()}%',
        onChanged: (v) => s.setDisplay(s.display.copyWith(brightness: () => v >= 0.995 ? null : v)),
      )),
    ];
  }
  // one line (user, 2026-10-21: "keep the two, reconsider the layout for compactness"): the label, Auto, the slider
  // and its value. Auto before the slider: a remote's Left / Right move the slider, so it reaches Auto first (Up /
  // Down land on a row's first control)
  return [_BrightnessRow(s)];
}

/// Screen brightness on one line, with backlight control: [Auto] - the system's own - then the slider, greyed while
/// Auto is on. Auto off starts from the screen's level now, so nothing jumps until the slider moves.
class _BrightnessRow extends StatelessWidget {
  const _BrightnessRow(this.s);
  final AppSettings s;

  @override
  Widget build(BuildContext context) {
    final b = s.display.brightness;
    const label = Text('Brightness', style: TextStyle(fontSize: 14.5));
    // a slim button like every other choice, lit while on (user, 2026-10-22: the chip was "ugly and inconsistent")
    final auto = SegmentedButton<bool>(
      style: slimButtonStyle(Theme.of(context).colorScheme),
      showSelectedIcon: false,
      emptySelectionAllowed: true,
      segments: const [ButtonSegment(value: true, label: Text('Auto'))],
      selected: {if (b == null) true},
      onSelectionChanged: (now) async {
        if (now.isNotEmpty) return s.setDisplay(s.display.copyWith(brightness: () => null));
        final level = await getScreenBrightness();
        s.setDisplay(s.display.copyWith(brightness: () => level == null ? 0.6 : DisplayPrefs.sliderFor(level)));
      },
    );
    final slider = BrightnessPreview(child: Semantics(
      label: 'Screen brightness',
      child: MediaQuery(
        data: MediaQuery.of(context).copyWith(navigationMode: NavigationMode.directional),
        child: Slider(value: (b ?? 0.6).clamp(0.0, 1.0), divisions: 20, // 5% steps
            onChanged: b == null ? null : (v) => s.setDisplay(s.display.copyWith(brightness: () => v))),
      ),
    ));
    final value = Text(b == null ? 'Auto' : b < DisplayPrefs.dimZone ? 'Extra dim' : '${(b * 100).round()}%',
        textAlign: TextAlign.right, style: const TextStyle(color: hintColour, fontSize: 12.5));
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 4, 14, 4),
      child: LayoutBuilder(builder: (context, box) {
        // a phone's narrow sheet (or a large text size): the label and Auto on a line, the slider and its value under
        // them - on one line it ran off the edge (320 wide at 130%)
        if (box.maxWidth < 380) {
          return Column(children: [
            Row(children: [const Expanded(child: label), auto]),
            Row(children: [Expanded(child: slider), SizedBox(width: 62, child: value)]),
          ]);
        }
        return Row(children: [
          const SizedBox(width: 92, child: label),
          auto,
          Expanded(child: slider),
          SizedBox(width: 62, child: value),
        ]);
      }),
    );
  }
}

/// Shows the reader's brightness on the whole screen while [child] (its slider) is in use - a finger on it, or the
/// remote's focus on it - so in Settings, where it doesn't otherwise apply, moving it shows what it does (user,
/// 2026-10-07 QA). Let go or move on, and the screen follows the system again.
class BrightnessPreview extends StatefulWidget {
  const BrightnessPreview({super.key, required this.child});
  final Widget child;
  @override
  State<BrightnessPreview> createState() => _BrightnessPreviewState();
}

class _BrightnessPreviewState extends State<BrightnessPreview> {
  bool _touched = false, _focused = false;

  void _set({bool? touched, bool? focused}) {
    _touched = touched ?? _touched;
    _focused = focused ?? _focused;
    AppSettings.instance.previewBrightness(this, _touched || _focused);
  }

  @override
  void dispose() {
    AppSettings.instance.previewBrightness(this, false); // never left on with the page gone
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Listener(
        onPointerDown: (_) => _set(touched: true),
        onPointerUp: (_) => _set(touched: false),
        onPointerCancel: (_) => _set(touched: false),
        child: Focus(
          canRequestFocus: false,
          skipTraversal: true,
          onFocusChange: (f) => _set(focused: f),
          child: widget.child,
        ),
      );
}

/// Night mode as one choice, Off / On / Scheduled (user, 2026-10-07: it was a switch and an "On a schedule" switch).
/// Scheduled, it goes on and off by itself at the times (the top bar's moon still switches it in between).
enum NightMode { off, on, scheduled }

NightMode nightModeOf(DisplayPrefs d) => d.nightSchedule ? NightMode.scheduled : d.night ? NightMode.on : NightMode.off;

/// Night mode, and its warmth while it's on or scheduled. It tints the whole app: Settings > Look.
List<Widget> nightRows(AppSettings s) {
  final d = s.display;
  final m = nightModeOf(d);
  return [
    SegmentRow<NightMode>(
      title: 'Night mode',
      subtitle: m == NightMode.scheduled ? 'On and off by itself; the moon in the reader still switches it' : null,
      choices: const [Choice(NightMode.off, 'Off'), Choice(NightMode.on, 'On'), Choice(NightMode.scheduled, 'Scheduled')],
      value: m,
      onChanged: (v) => s.setDisplay(switch (v) {
        NightMode.off => d.copyWith(night: false, nightSchedule: false),
        NightMode.on => d.copyWith(night: true, nightSchedule: false),
        NightMode.scheduled => d.copyWith(nightSchedule: true),
      }),
    ),
    if (m != NightMode.off)
      SliderRow(label: 'Warmth', value: d.warmth, divisions: 20, // 5% steps
          valueText: '${(d.warmth * 100).round()}%',
          onChanged: (v) => s.setDisplay(s.display.copyWith(warmth: v))),
  ];
}

/// Which of the position text's spots are shown, [kind]'s own (user, 2026-10-07: a setting as well as a tap on the
/// text itself). Comics fill two spots, EPUBs three.
Widget positionTextRow(AppSettings s, BookKind kind) {
  final k = s.display.kind(kind);
  final spots = kind == BookKind.comics
      ? const [(PositionSpot.centre, 'Book title'), (PositionSpot.left, 'Progress')]
      : const [(PositionSpot.right, 'Chapter progress'), (PositionSpot.left, 'Book progress'),
          (PositionSpot.centre, 'Chapter name')];
  return ToggleChipsRow(
    title: 'Over the slider (tap to hide)', // (user, 2026-10-21: "(tap to hide)" in the title, no description)
    chips: [
      for (final (spot, label) in spots)
        ToggleChip(label, !k.hiddenSpots.contains(spot.name), (on) => s.setDisplay(s.display.withKind(kind,
            k.copyWith(hiddenSpots: on ? (List.of(k.hiddenSpots)..remove(spot.name)) : [...k.hiddenSpots, spot.name])))),
    ],
  );
}

Widget pageTurnRow(AppSettings s) => SegmentRow<PageTurn>(
      title: 'Page turn', // as eBooks' (user, 2026-10-21: "the same name")
      choices: [for (final t in PageTurn.values) Choice(t, t.label)],
      value: s.display.pageTurn,
      onChanged: (t) => s.setDisplay(s.display.copyWith(pageTurn: t)),
    );

/// Rotation in the reader (Android only: a PC window doesn't turn). Portrait / Landscape hold the way the tablet is
/// held when the lock starts; tapping the one in force again turns it upside down (user, 2026-10-07). One for both
/// kinds of book (user, 2026-10-21).
Widget rotationRow(AppSettings s) {
  final rotation = s.display.rotation;
  return SegmentRow<Rotation>(
      title: 'Rotation',
      subtitle: rotation == Rotation.auto
          ? 'Follow the device, or stay put'
          : 'Stays put - while reading, tap ${rotation.label} again to turn it upside down',
      // the lock in force marked as a switch: tapped again, it turns over (user, 2026-10-07)
      choices: [
        for (final r in Rotation.values)
          Choice(r, r.label, mark: r != Rotation.auto && r == rotation ? Icons.sync : null),
      ],
      markRoom: true, // the buttons the same size, mark or not (user, 2026-10-07: no resizing)
      value: rotation,
      onChanged: (r) => s.setDisplay(s.display.copyWith(rotation: r)),
      onReselect: (r) {
        if (r != Rotation.auto) OrientationLock.instance.flip(); // (only while a book holds the lock)
      },
    );
}

/// What's over the page while the controls are hidden, one set for both kinds of book (user, 2026-10-21, the
/// mock-ups' A): the clock, the battery, the page counter and the progress bar, each on or off; while the page counter
/// is on, when it shows - after a turn, or always - its own small choice under them.
List<Widget> overPageRows(AppSettings s) {
  final d = s.display;
  return [
    ToggleChipsRow(
      title: 'With the controls hidden show:',
      chips: [
        ToggleChip('Clock', d.showClock, (v) => s.setDisplay(s.display.copyWith(showClock: v))),
        ToggleChip('Battery', d.showBattery, (v) => s.setDisplay(s.display.copyWith(showBattery: v))),
        ToggleChip('Page counter', d.pageNote != PageNote.off,
            (v) => s.setDisplay(s.display.copyWith(pageNote: v ? PageNote.afterTurn : PageNote.off))),
        ToggleChip('Progress bar', d.progressBar, (v) => s.setDisplay(s.display.copyWith(progressBar: v))),
      ],
    ),
    if (d.pageNote != PageNote.off)
      SegmentRow<PageNote>(
        title: 'Show the page counter',
        choices: const [Choice(PageNote.afterTurn, 'After a turn'), Choice(PageNote.always, 'Always')],
        value: d.pageNote,
        onChanged: (v) => s.setDisplay(s.display.copyWith(pageNote: v)),
      ),
  ];
}

/// eBooks: the page as a sheet on a surround - never, on a wide screen, or always - this device's own (user,
/// 2026-10-11: on the settings page, not the reader's panel; "inset page", three choices - 2026-10-12).
Widget insetPageRow(AppSettings s) => SegmentRow<InsetPage>(
      title: 'Inset page',
      subtitle: switch (s.display.insetPage) {
        InsetPage.never => 'The page colour across the whole screen (this device)',
        InsetPage.wideScreen => 'On a wide screen, the page in the middle, a shade apart from the screen round it '
            '(this device)',
        InsetPage.always => 'The page a shade apart from the screen round it, a narrow screen too (this device)',
      },
      choices: const [
        Choice(InsetPage.never, 'Never'),
        Choice(InsetPage.wideScreen, 'Wide screen'),
        Choice(InsetPage.always, 'Always'),
      ],
      value: s.display.insetPage,
      onChanged: (v) => s.setDisplay(s.display.copyWith(insetPage: v)),
    );

Widget doubleTapRow(AppSettings s) => SwitchRow(
      title: 'Double-tap to zoom',
      subtitle: 'Taps wait a moment for a second tap',
      value: s.display.doubleTapZoom,
      onChanged: (v) => s.setDisplay(s.display.copyWith(doubleTapZoom: v)),
    );

Widget screenOnRow(AppSettings s) {
  final d = s.display;
  return SegmentRow<int>(
    title: 'Keep the screen on',
    subtitle: d.screenOn == 0
        ? "The device's own timeout"
        : d.screenOn == DisplayPrefs.alwaysOn
            ? 'As long as a book is open'
            : 'After the last page turn or touch',
    choices: [for (final m in DisplayPrefs.screenOnChoices) Choice(m, screenOnLabel(m))],
    value: d.screenOn,
    onChanged: (m) => s.setDisplay(d.copyWith(screenOn: m)),
  );
}

/// "Keep the screen on" choices, short enough for segmented buttons.
String screenOnLabel(int minutes) => switch (minutes) {
      DisplayPrefs.alwaysOn => 'Always',
      0 => 'Off',
      _ => '$minutes min',
    };
