import 'package:flutter/material.dart';

import '../reader/position_row.dart';
import '../screen.dart';
import '../settings.dart';
import 'setting_rows.dart';

/// The reader's two settings panels, opened from its bottom bar: side sheets on a wide screen (the page stays in
/// view), bottom sheets on a narrow one. Changes show live. Remote: Up/Down move between rows, Left/Right adjust a
/// slider or move along segmented buttons, OK presses; "Done" closes the panel.
///
/// * Comic settings: Save / Copy page, fit, reading direction and page colours (this series), then what's changed
///   mid-book (user, 2026-10-07): position text, brightness, rotation, keep the screen on. What's set once is in
///   Settings > Comics; night mode is the top bar's moon.
/// * Image: Enhance, Enhance colours, crop, brightness, contrast (this series); Reset to original and Make default.
///
/// Each panel's series group starts with "Override defaults" (user, 2026-09-30; shorter, no line under it - 2026-10-07): off, the series follows the
/// defaults for that part (page layout, or image) and its controls are greyed out showing the default values; on,
/// they're the series' own - starting from the defaults, so nothing jumps. The two parts are separate.
///
/// The row builders below are shared with the Settings screen, so a setting looks the same in both places.
/// [page]: Save page / Copy page for the page shown (null where there's no page to save, or no way to).
Future<void> showReaderPanel(BuildContext context, {String? seriesId, String? seriesTitle, String? komgaDirection,
        FitMode? bookFit, PageActions? page}) =>
    _show(context, (side) => _ReaderPanel(seriesId: seriesId, seriesTitle: seriesTitle, komgaDirection: komgaDirection,
        bookFit: bookFit, page: page, side: side));

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
const _sideWidth = 380.0;

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
        width: _sideWidth,
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
          SettingsColumn(child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: groups(s))),
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
  const _ReaderPanel({this.seriesId, this.seriesTitle, this.komgaDirection, this.bookFit, this.page,
      required this.side});
  final PageActions? page;
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
                    s.setDefault(s.defaults.copyWith(fit: p.fit, direction: p.direction, background: p.background));
                    _toast(context, "Series you haven't adjusted will open like this one");
                  },
                  child: const Text('Make default'),
                ),
              ),
          ]),
        // what's changed mid-book (user, 2026-10-07: not the settings set once - those are in Settings > Comics)
        SettingsGroup(title: 'Reading', children: [
          positionTextRow(s, BookKind.comics),
          ...brightnessRows(s),
          if (canRotate) rotationRow(s, BookKind.comics), // locked mid-book, lying down
          screenOnRow(s),
        ]),
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

String _signed(double v) {
  final n = (v * 100).round();
  return n == 0 ? '0' : (n > 0 ? '+$n' : '$n');
}

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

/// Enhance and Enhance colours first (the ones actually used), then crop, brightness and contrast.
List<Widget> imageRows(ReaderPrefs p, void Function(ReaderPrefs) setP, {bool enabled = true}) => [
      SwitchRow(title: 'Enhance', subtitle: 'Cleans up grain and speckle, then sharpens',
          value: p.sharpen, onChanged: enabled ? (v) => setP(p.copyWith(sharpen: v)) : null),
      SwitchRow(title: 'Enhance colours', subtitle: 'Whiter paper, deeper ink',
          value: p.autoLevels, onChanged: enabled ? (v) => setP(p.copyWith(autoLevels: v)) : null),
      SliderRow(label: 'Crop edges', enabled: enabled, value: p.crop, min: 0, max: ReaderPrefs.maxCrop, divisions: 10, // 1% steps
          valueText: p.crop == 0 ? 'Off' : '${(p.crop * 100).round()}%', onChanged: (v) => setP(p.copyWith(crop: v))),
      SliderRow(label: 'Brightness', enabled: enabled, value: p.brightness, min: -0.3, max: 0.3, divisions: 40, // steps of 5 (-100..+100)
          valueText: _signed(p.brightness / 0.3), onChanged: (v) => setP(p.copyWith(brightness: v))),
      SliderRow(label: 'Contrast', enabled: enabled, value: p.contrast, min: -0.5, max: 0.5, divisions: 40, // steps of 5
          valueText: _signed(p.contrast / 0.5), onChanged: (v) => setP(p.copyWith(contrast: v))),
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
  return [
    BrightnessPreview(child: SliderRow(
      label: 'Screen brightness',
      divisions: 20, // 5% steps
      value: d.brightness ?? 0.6,
      enabled: d.brightness != null,
      valueText: d.brightness == null
          ? 'Auto'
          : d.brightness! < DisplayPrefs.dimZone ? 'Extra dim' : '${(d.brightness! * 100).round()}%',
      onChanged: (v) => s.setDisplay(s.display.copyWith(brightness: () => v)),
    )),
    SwitchRow(
      title: 'Automatic brightness',
      value: d.brightness == null,
      onChanged: (auto) async {
        if (auto) return s.setDisplay(s.display.copyWith(brightness: () => null));
        // start from the current screen level, so nothing jumps until the slider moves
        final now = await getScreenBrightness();
        s.setDisplay(s.display.copyWith(brightness: () => now == null ? 0.6 : DisplayPrefs.sliderFor(now)));
      },
    ),
  ];
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
    title: 'Position text',
    subtitle: 'Over the slider - a tap on it there hides it too',
    chips: [
      for (final (spot, label) in spots)
        ToggleChip(label, !k.hiddenSpots.contains(spot.name), (on) => s.setDisplay(s.display.withKind(kind,
            k.copyWith(hiddenSpots: on ? (List.of(k.hiddenSpots)..remove(spot.name)) : [...k.hiddenSpots, spot.name])))),
    ],
  );
}

/// The comic reader's page strip (the Pages button) as a setting too (user, 2026-10-07).
Widget pageStripRow(AppSettings s) => SwitchRow(
      title: 'Page strip',
      subtitle: 'Opens with the controls; the Pages button in the reader switches it too',
      value: s.display.pageStrip,
      onChanged: (v) => s.setDisplay(s.display.copyWith(pageStrip: v)),
    );

Widget pageTurnRow(AppSettings s) => SegmentRow<PageTurn>(
      title: 'Page turn animation',
      choices: [for (final t in PageTurn.values) Choice(t, t.label)],
      value: s.display.pageTurn,
      onChanged: (t) => s.setDisplay(s.display.copyWith(pageTurn: t)),
    );

/// Rotation in the reader (Android only: a PC window doesn't turn). Portrait / Landscape hold the way the tablet is
/// held when the lock starts; tapping the one in force again turns it upside down (user, 2026-10-07).
/// [kind]'s rotation (each kind its own - user, 2026-10-07).
Widget rotationRow(AppSettings s, BookKind kind) {
  final k = s.display.kind(kind);
  return SegmentRow<Rotation>(
      title: 'Rotation',
      subtitle: k.rotation == Rotation.auto
          ? 'Follow the device, or stay put'
          : 'Stays put - while reading, tap ${k.rotation.label} again to turn it upside down',
      // the lock in force marked as a switch: tapped again, it turns over (user, 2026-10-07)
      choices: [
        for (final r in Rotation.values)
          Choice(r, r.label, mark: r != Rotation.auto && r == k.rotation ? Icons.sync : null),
      ],
      markRoom: true, // the buttons the same size, mark or not (user, 2026-10-07: no resizing)
      value: k.rotation,
      onChanged: (r) => s.setDisplay(s.display.withKind(kind, k.copyWith(rotation: r))),
      onReselect: (r) {
        if (r != Rotation.auto) OrientationLock.instance.flip(); // (only while a book holds the lock)
      },
    );
}

Widget clockRow(AppSettings s, BookKind kind) => SegmentRow<ShowWhen>(
      title: 'Clock and battery',
      subtitle: switch (s.display.kind(kind).clock) {
        ShowWhen.off => 'Not shown',
        ShowWhen.withControls => 'On the top bar when you tap the page',
        ShowWhen.always => 'Top right, all the time',
      },
      choices: [for (final w in ShowWhen.values) Choice(w, w.label)],
      value: s.display.kind(kind).clock,
      onChanged: (w) => s.setDisplay(s.display.withKind(kind, s.display.kind(kind).copyWith(clock: w))),
    );

Widget progressBarRow(AppSettings s, BookKind kind) => SwitchRow(
      title: 'Progress bar',
      subtitle: 'A thin line along the bottom while the controls are hidden',
      value: s.display.kind(kind).progressBar,
      onChanged: (v) => s.setDisplay(s.display.withKind(kind, s.display.kind(kind).copyWith(progressBar: v))),
    );

Widget pagePreviewsRow(AppSettings s) => SwitchRow(
      title: 'Page previews',
      subtitle: s.display.pagePreviews
          ? 'A picture of the page over the slider while you pick one'
          : 'Just the page number - for a slow link to your books',
      value: s.display.pagePreviews,
      onChanged: (v) => s.setDisplay(s.display.copyWith(pagePreviews: v)),
    );

/// The note in the page's bottom-right corner, [kind]'s own - the same note for both kinds: the page of the book's
/// pages (user, 2026-10-07).
Widget pageNoteRow(AppSettings s, BookKind kind) => SegmentRow<PageNote>(
      title: 'Show page counter', // (it was "Page corner" - user, 2026-10-07 QA)
      subtitle: 'The page you\'re on, "12 / 36"',
      choices: const [
        Choice(PageNote.always, 'Always'),
        Choice(PageNote.afterTurn, 'After a turn'),
        Choice(PageNote.off, 'Off'),
      ],
      value: s.display.kind(kind).pageNote,
      onChanged: (v) => s.setDisplay(s.display.withKind(kind, s.display.kind(kind).copyWith(pageNote: v))),
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
