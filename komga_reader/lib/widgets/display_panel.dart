import 'package:flutter/material.dart';

import '../screen.dart';
import '../settings.dart';

/// The reader's two settings panels, opened from its bottom bar. The page stays visible above them so changes show
/// live. Remote: Up/Down move between rows, Left/Right adjust a slider, OK toggles a switch; "Done" closes the panel.
///
/// * Reader settings: fit mode (this series) + screen brightness and night mode (whole app, this device). Also opened
///   from the side menu, without the fit part.
/// * Image settings: page brightness / contrast / sharpen / auto-levels (this series).
///
/// A series you have never adjusted follows the defaults; the first change you make in a series gives it its own
/// settings (starting from the defaults), which the defaults no longer affect.
Future<void> showReaderPanel(BuildContext context, {String? seriesId, String? seriesTitle, String? komgaDirection}) =>
    _show(context, _ReaderPanel(seriesId: seriesId, seriesTitle: seriesTitle, komgaDirection: komgaDirection));

Future<void> showImagePanel(BuildContext context, {required String seriesId, String? seriesTitle}) =>
    _show(context, _ImagePanel(seriesId: seriesId, seriesTitle: seriesTitle));

Future<void> _show(BuildContext context, Widget panel) => showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      barrierColor: Colors.transparent,
      backgroundColor: const Color(0xF2141416),
      constraints: const BoxConstraints(maxWidth: 640),
      builder: (_) => panel,
    );

/// Shared frame: title row with Done, the rows, and any Komga sync problem at the bottom.
class _Panel extends StatelessWidget {
  const _Panel({required this.title, required this.rows});
  final String title;
  final List<Widget> Function(AppSettings s) rows;

  @override
  Widget build(BuildContext context) {
    final s = AppSettings.instance;
    return ListenableBuilder(
      listenable: s,
      builder: (context, _) => SafeArea(
        child: ConstrainedBox(
          constraints: BoxConstraints(maxHeight: MediaQuery.of(context).size.height * 0.7),
          child: ListView(shrinkWrap: true, padding: const EdgeInsets.fromLTRB(16, 4, 16, 16), children: [
            Row(children: [
              Expanded(child: Text(title, style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w500))),
              TextButton(autofocus: true, onPressed: () => Navigator.of(context).pop(), child: const Text('Done')),
            ]),
            ...rows(s),
            if (s.syncError != null)
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: Text(s.syncError!, style: const TextStyle(color: Color(0xFFFFB74D), fontSize: 12)),
              ),
          ]),
        ),
      ),
    );
  }
}

class _ReaderPanel extends StatelessWidget {
  const _ReaderPanel({this.seriesId, this.seriesTitle, this.komgaDirection});
  final String? seriesId;
  final String? seriesTitle;
  final String? komgaDirection; // the series' reading direction in Komga, for the Auto label

  static String _komgaLabel(String? d) => switch (d) {
        'RIGHT_TO_LEFT' => 'right to left',
        'VERTICAL' => 'vertical (read left to right)',
        'WEBTOON' => 'webtoon (read left to right)',
        _ => 'left to right',
      };

  @override
  Widget build(BuildContext context) {
    return _Panel(title: 'Reader settings', rows: (s) {
      final d = s.display;
      final id = seriesId;
      final p = s.prefsFor(id);
      final fitName = p.fit.label.toLowerCase();
      return [
        if (id != null) ...[
          _Heading('Fit · ${seriesTitle ?? 'this series'}'),
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: SegmentedButton<FitMode>(
              segments: [
                for (final f in FitMode.values) ButtonSegment(value: f, label: Text('Fit ${f.label.toLowerCase()}')),
              ],
              selected: {p.fit},
              showSelectedIcon: false,
              onSelectionChanged: (v) => s.setSeries(id, p.copyWith(fit: v.first)),
            ),
          ),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton(
              onPressed: () {
                s.setDefault(s.defaults.copyWith(fit: p.fit));
                _toast(context, "Series you haven't adjusted will open in fit $fitName");
              },
              child: Text('Make fit $fitName the default'),
            ),
          ),
          _Heading('Reading direction · ${seriesTitle ?? 'this series'}'),
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: SegmentedButton<ReadingDirection>(
              segments: [
                for (final r in ReadingDirection.values)
                  ButtonSegment(
                    value: r,
                    // Auto shows what it resolves to, from the series' reading direction in Komga
                    label: Text(r == ReadingDirection.auto ? 'Auto · ${_komgaLabel(komgaDirection)}' : r.label),
                  ),
              ],
              selected: {p.direction},
              showSelectedIcon: false,
              onSelectionChanged: (v) => s.setSeries(id, p.copyWith(direction: v.first)),
            ),
          ),
        ],
        const _Heading('Page turn · this device'),
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: SegmentedButton<PageTurn>(
            segments: [for (final t in PageTurn.values) ButtonSegment(value: t, label: Text(t.label))],
            selected: {d.pageTurn},
            showSelectedIcon: false,
            onSelectionChanged: (v) => s.setDisplay(d.copyWith(pageTurn: v.first)),
          ),
        ),
        const _Heading('Screen · whole app, this device'),
        if (!DisplayPrefs.backlightControl)
          // desktop: a monitor's backlight can't be set, so the slider only dims (right = no dimming)
          _SliderRow(
            label: 'Screen brightness',
            value: d.brightness ?? 1,
            valueText: (d.brightness ?? 1) >= 0.995 ? 'Full' : '${((d.brightness ?? 1) * 100).round()}%',
            onChanged: (v) => s.setDisplay(d.copyWith(brightness: () => v >= 0.995 ? null : v)),
          ),
        if (DisplayPrefs.backlightControl) ...[
        _SliderRow(
          label: 'Screen brightness',
          value: d.brightness ?? 0.6,
          enabled: d.brightness != null,
          valueText: d.brightness == null
              ? 'Auto'
              : d.brightness! < DisplayPrefs.dimZone ? 'Extra dim' : '${(d.brightness! * 100).round()}%',
          onChanged: (v) => s.setDisplay(d.copyWith(brightness: () => v)),
        ),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('Automatic brightness (tablet setting)'),
          value: d.brightness == null,
          onChanged: (auto) async {
            if (auto) return s.setDisplay(d.copyWith(brightness: () => null));
            // start from the current screen level, so nothing jumps until the slider moves
            final now = await getScreenBrightness();
            s.setDisplay(s.display.copyWith(brightness: () => now == null ? 0.6 : DisplayPrefs.sliderFor(now)));
          },
        ),
        ],
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('Night mode (warm colours)'),
          value: d.night,
          onChanged: (v) => s.setDisplay(d.copyWith(night: v)),
        ),
        _SliderRow(
          label: 'Warmth',
          value: d.warmth,
          enabled: d.night,
          valueText: '${(d.warmth * 100).round()}%',
          onChanged: (v) => s.setDisplay(d.copyWith(warmth: v)),
        ),
      ];
    });
  }
}

class _ImagePanel extends StatelessWidget {
  const _ImagePanel({required this.seriesId, this.seriesTitle});
  final String seriesId;
  final String? seriesTitle;

  @override
  Widget build(BuildContext context) {
    return _Panel(title: 'Image settings', rows: (s) {
      final p = s.prefsFor(seriesId);
      void setP(ReaderPrefs n) => s.setSeries(seriesId, n);
      return [
        _Heading('Pages · ${seriesTitle ?? 'this series'}'),
        _SliderRow(label: 'Page brightness', value: p.brightness, min: -0.3, max: 0.3,
            valueText: _signed(p.brightness / 0.3), onChanged: (v) => setP(p.copyWith(brightness: v))),
        _SliderRow(label: 'Contrast', value: p.contrast, min: -0.5, max: 0.5,
            valueText: _signed(p.contrast / 0.5), onChanged: (v) => setP(p.copyWith(contrast: v))),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('Sharpen'),
          subtitle: const Text('Light, for soft or low-resolution scans'),
          value: p.sharpen,
          onChanged: (v) => setP(p.copyWith(sharpen: v)),
        ),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('Auto-levels'),
          subtitle: const Text('Whitens yellowed paper, deepens grey blacks'),
          value: p.autoLevels,
          onChanged: (v) => setP(p.copyWith(autoLevels: v)),
        ),
        const SizedBox(height: 4),
        Wrap(spacing: 8, runSpacing: 8, children: [
          // back to the untouched scan for this series (fit is left alone)
          OutlinedButton(
            onPressed: () => setP(p.imageReset()),
            child: const Text('Reset to original'),
          ),
          // the image part of the defaults, used by every series you haven't adjusted
          OutlinedButton(
            onPressed: () {
              s.setDefault(s.defaults.copyWith(
                  brightness: p.brightness, contrast: p.contrast, sharpen: p.sharpen, autoLevels: p.autoLevels));
              _toast(context, "Series you haven't adjusted will use these image settings");
            },
            child: const Text('Make these the default'),
          ),
        ]),
      ];
    });
  }
}

void _toast(BuildContext context, String text) =>
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(content: Text(text)));

String _signed(double v) {
  final n = (v * 100).round();
  return n == 0 ? '0' : (n > 0 ? '+$n' : '$n');
}

class _Heading extends StatelessWidget {
  const _Heading(this.text);
  final String text;
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(top: 14, bottom: 2),
        child: Text(text, style: const TextStyle(color: Color(0xFF9A9A9A), fontSize: 12)),
      );
}

class _SliderRow extends StatelessWidget {
  const _SliderRow({required this.label, required this.value, required this.onChanged, required this.valueText,
      this.min = 0, this.max = 1, this.enabled = true});
  final String label;
  final double value, min, max;
  final String valueText;
  final bool enabled;
  final ValueChanged<double> onChanged;

  @override
  Widget build(BuildContext context) {
    return Row(children: [
      SizedBox(width: 120, child: Text(label, style: TextStyle(color: enabled ? null : const Color(0xFF6A6A6A)))),
      Expanded(
        child: Slider(value: value.clamp(min, max), min: min, max: max, onChanged: enabled ? onChanged : null),
      ),
      SizedBox(width: 64, child: Text(valueText, textAlign: TextAlign.right,
          style: const TextStyle(color: Color(0xFF9A9A9A), fontSize: 12))),
    ]);
  }
}
