import 'package:flutter/material.dart';

import '../screen.dart';
import '../settings.dart';
import 'setting_rows.dart';

/// The reader's two settings panels, opened from its bottom bar: side sheets on a wide screen (the page stays in
/// view), bottom sheets on a narrow one. Changes show live. Remote: Up/Down move between rows, Left/Right adjust a
/// slider or move along segmented buttons, OK presses; "Done" closes the panel.
///
/// * Reader: fit and reading direction (this series), then the screen: brightness, night mode, background, page
///   turn animation (this device).
/// * Image: Enhance, Enhance colours, crop, brightness, contrast (this series); ⋮ has Reset to original, Make these
///   the default and Use the defaults.
///
/// A series you have never adjusted follows the defaults; the first change you make in a series gives it its own
/// settings (starting from the defaults), which the defaults no longer affect - until Use the defaults.
///
/// The row builders below are shared with the Settings screen, so a setting looks the same in both places.
Future<void> showReaderPanel(BuildContext context, {String? seriesId, String? seriesTitle, String? komgaDirection}) =>
    _show(context, (side) => _ReaderPanel(seriesId: seriesId, seriesTitle: seriesTitle, komgaDirection: komgaDirection,
        side: side));

Future<void> showImagePanel(BuildContext context, {required String seriesId, String? seriesTitle}) =>
    _show(context, (side) => _ImagePanel(seriesId: seriesId, seriesTitle: seriesTitle, side: side));

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

/// Shared frame: title (with an optional ⋮ menu) and Done, the groups, any Komga sync problem at the bottom.
class _Panel extends StatelessWidget {
  const _Panel({required this.title, required this.groups, required this.side, this.menu});
  final String title;
  final bool side;
  final Widget? menu;
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
            if (menu != null) menu!,
            TextButton(autofocus: true, onPressed: () => Navigator.of(context).pop(), child: const Text('Done')),
          ]),
          const SizedBox(height: 6),
          ...groups(s),
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

/// "Own settings" / "Follows the defaults", next to a series' name.
Widget _seriesChip(AppSettings s, String seriesId) =>
    s.hasOwn(seriesId) ? const StatusChip('Own settings', strong: true) : const StatusChip('Follows the defaults');

class _ReaderPanel extends StatelessWidget {
  const _ReaderPanel({this.seriesId, this.seriesTitle, this.komgaDirection, required this.side});
  final String? seriesId;
  final String? seriesTitle;
  final String? komgaDirection; // the series' reading direction in Komga, for Auto
  final bool side;

  @override
  Widget build(BuildContext context) {
    return _Panel(title: 'Reader', side: side, groups: (s) {
      final id = seriesId;
      final p = s.prefsFor(id);
      return [
        if (id != null)
          SettingsGroup(title: seriesTitle ?? 'This series', trailing: _seriesChip(s, id), children: [
            ...fitDirectionRows(p, (n) => s.setSeries(id, n), icons: true, komgaDirection: komgaDirection),
            ActionRow(
              title: 'Use this fit and direction for new series',
              button: TextButton(
                onPressed: () {
                  s.setDefault(s.defaults.copyWith(fit: p.fit, direction: p.direction));
                  _toast(context, "Series you haven't adjusted will open like this one");
                },
                child: const Text('Make default'),
              ),
            ),
          ]),
        SettingsGroup(title: 'Screen', children: [
          ...brightnessRows(s, compact: true),
          ...nightRows(s),
          backgroundRow(s),
          pageTurnRow(s),
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
    final s = AppSettings.instance;
    return _Panel(
      title: 'Image',
      side: side,
      menu: PopupMenuButton<String>(
        tooltip: 'More',
        icon: const Icon(Icons.more_vert),
        onSelected: (v) {
          final p = s.prefsFor(seriesId);
          switch (v) {
            case 'original':
              s.setSeries(seriesId, p.imageReset()); // the untouched scan for this series (fit is left alone)
            case 'default':
              s.setDefault(s.defaults.copyWith(brightness: p.brightness, contrast: p.contrast, sharpen: p.sharpen,
                  autoLevels: p.autoLevels, crop: p.crop));
              _toast(context, "Series you haven't adjusted will use these image settings");
            case 'defaults':
              s.useDefaults(seriesId);
              _toast(context, 'This series follows the defaults again');
          }
        },
        itemBuilder: (_) => [
          const PopupMenuItem(value: 'original', child: Text('Reset to original')),
          const PopupMenuItem(value: 'default', child: Text('Make these the default')),
          PopupMenuItem(
            value: 'defaults',
            enabled: s.hasOwn(seriesId),
            child: const Text('Use the defaults'),
          ),
        ],
      ),
      groups: (s) {
        final p = s.prefsFor(seriesId);
        return [
          SettingsGroup(title: seriesTitle ?? 'This series', trailing: _seriesChip(s, seriesId),
              children: imageRows(p, (n) => s.setSeries(seriesId, n))),
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

/// Fit and reading direction for [p] (a series, or the defaults). [icons]: fit as icons (the reader's narrow sheet).
List<Widget> fitDirectionRows(ReaderPrefs p, void Function(ReaderPrefs) setP, {bool icons = false,
    String? komgaDirection}) {
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
        Choice(FitMode.width, icons ? 'Fit width' : 'Width', icon: icons ? Icons.swap_horiz : null),
        Choice(FitMode.height, icons ? 'Fit height' : 'Height', icon: icons ? Icons.swap_vert : null),
      ],
      value: p.fit,
      onChanged: (f) => setP(p.copyWith(fit: f)),
    ),
    SegmentRow<ReadingDirection>(
      title: 'Direction',
      subtitle: komga == null ? 'Auto follows Komga' : 'Auto follows Komga: $komga',
      choices: const [
        Choice(ReadingDirection.auto, 'Auto'),
        Choice(ReadingDirection.ltr, 'Left to right'),
        Choice(ReadingDirection.rtl, 'Right to left'),
      ],
      value: p.direction,
      onChanged: (d) => setP(p.copyWith(direction: d)),
    ),
  ];
}

/// Enhance and Enhance colours first (the ones actually used), then crop, brightness and contrast.
List<Widget> imageRows(ReaderPrefs p, void Function(ReaderPrefs) setP) => [
      SwitchRow(title: 'Enhance', subtitle: 'Cleans up grain and speckle, then sharpens',
          value: p.sharpen, onChanged: (v) => setP(p.copyWith(sharpen: v))),
      SwitchRow(title: 'Enhance colours', subtitle: 'Whiter paper, deeper ink',
          value: p.autoLevels, onChanged: (v) => setP(p.copyWith(autoLevels: v))),
      SliderRow(label: 'Crop edges', value: p.crop, min: 0, max: ReaderPrefs.maxCrop, divisions: 10, // 1% steps
          valueText: p.crop == 0 ? 'Off' : '${(p.crop * 100).round()}%', onChanged: (v) => setP(p.copyWith(crop: v))),
      SliderRow(label: 'Brightness', value: p.brightness, min: -0.3, max: 0.3,
          valueText: _signed(p.brightness / 0.3), onChanged: (v) => setP(p.copyWith(brightness: v))),
      SliderRow(label: 'Contrast', value: p.contrast, min: -0.5, max: 0.5,
          valueText: _signed(p.contrast / 0.5), onChanged: (v) => setP(p.copyWith(contrast: v))),
    ];

/// Screen brightness (whole app, this device): the backlight plus extra dimming on Android, dimming only on a PC.
/// [compact]: an icon instead of the "Screen brightness" label (the reader's narrow sheet).
List<Widget> brightnessRows(AppSettings s, {bool compact = false}) {
  final d = s.display;
  final icon = compact ? Icons.brightness_6_outlined : null;
  if (!DisplayPrefs.backlightControl) {
    // a monitor's backlight can't be set, so the slider only dims (right = no dimming)
    return [
      SliderRow(
        label: 'Screen brightness',
        icon: icon,
        value: d.brightness ?? 1,
        valueText: (d.brightness ?? 1) >= 0.995 ? 'Full' : '${((d.brightness ?? 1) * 100).round()}%',
        onChanged: (v) => s.setDisplay(s.display.copyWith(brightness: () => v >= 0.995 ? null : v)),
      ),
    ];
  }
  return [
    SliderRow(
      label: 'Screen brightness',
      icon: icon,
      value: d.brightness ?? 0.6,
      enabled: d.brightness != null,
      valueText: d.brightness == null
          ? 'Auto'
          : d.brightness! < DisplayPrefs.dimZone ? 'Extra dim' : '${(d.brightness! * 100).round()}%',
      onChanged: (v) => s.setDisplay(s.display.copyWith(brightness: () => v)),
    ),
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

/// Night mode, and its warmth while it's on. It tints the whole app, so it's in Settings > Display as well.
List<Widget> nightRows(AppSettings s) {
  final d = s.display;
  return [
    SwitchRow(title: 'Night mode', subtitle: 'Warm colours, whole app', value: d.night,
        onChanged: (v) => s.setDisplay(s.display.copyWith(night: v))),
    if (d.night)
      SliderRow(label: 'Warmth', value: d.warmth, valueText: '${(d.warmth * 100).round()}%',
          onChanged: (v) => s.setDisplay(s.display.copyWith(warmth: v))),
  ];
}

Widget pageTurnRow(AppSettings s) => SegmentRow<PageTurn>(
      title: 'Page turn animation',
      choices: [for (final t in PageTurn.values) Choice(t, t.label)],
      value: s.display.pageTurn,
      onChanged: (t) => s.setDisplay(s.display.copyWith(pageTurn: t)),
    );

/// Black, dark grey or white around the page: three swatches.
Widget backgroundRow(AppSettings s) => SettingRow(
      title: 'Background',
      trailing: Row(mainAxisSize: MainAxisSize.min, children: [
        for (final b in ReaderBackground.values)
          _Swatch(background: b, selected: s.display.background == b,
              onTap: () => s.setDisplay(s.display.copyWith(background: b))),
      ]),
    );

class _Swatch extends StatelessWidget {
  const _Swatch({required this.background, required this.selected, required this.onTap});
  final ReaderBackground background;
  final bool selected;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) {
    final accent = Theme.of(context).colorScheme.primary;
    return Tooltip(
      message: background.label,
      child: Semantics(
        button: true,
        selected: selected,
        label: '${background.label} background',
        child: InkResponse(
          onTap: onTap,
          radius: 20,
          child: Padding(
            padding: const EdgeInsets.all(4),
            child: Container(
              width: 28,
              height: 28,
              decoration: BoxDecoration(
                color: background.colour,
                shape: BoxShape.circle,
                border: Border.all(color: selected ? accent : const Color(0xFF55585F), width: selected ? 3 : 1),
              ),
              child: selected
                  ? Icon(Icons.check, size: 16, color: background == ReaderBackground.white ? Colors.black : Colors.white)
                  : null,
            ),
          ),
        ),
      ),
    );
  }
}

/// "Keep the screen on" choices, short enough for segmented buttons.
String screenOnLabel(int minutes) => switch (minutes) {
      DisplayPrefs.alwaysOn => 'Always',
      0 => 'Off',
      _ => '$minutes min',
    };
