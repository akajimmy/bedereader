import 'package:flutter/material.dart';

/// The one visual language for settings (Settings screen and the reader's panels; user, 2026-09-30): groups with a
/// small accent label, rows inside a rounded box separated by hairlines, the label on the left and the control on
/// the right (a segmented control drops under its label when the row is too narrow), descriptions one short line.

const _boxColour = Color(0xFF17181C);
const _lineColour = Color(0xFF2A2C33);
const hintColour = Color(0xFF9A9A9A);

/// How wide [text] comes out at [fontSize] in this context's font and text size (the tablet's text size setting
/// included).
double textWidth(BuildContext context, String text, double fontSize) {
  final painter = TextPainter(
    text: TextSpan(text: text, style: DefaultTextStyle.of(context).style.copyWith(fontSize: fontSize)),
    textDirection: TextDirection.ltr,
    textScaler: MediaQuery.textScalerOf(context),
    maxLines: 1,
  )..layout();
  final w = painter.width;
  painter.dispose();
  return w;
}

/// A labelled box of rows.
class SettingsGroup extends StatelessWidget {
  const SettingsGroup({super.key, this.title, required this.children, this.trailing});
  final String? title;
  final Widget? trailing; // beside the label (a status chip, say)
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final accent = Theme.of(context).colorScheme.primary;
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        if (title != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 0, 4, 6),
            child: Row(children: [
              Flexible(child: Text(title!, overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: accent, fontSize: 12.5, fontWeight: FontWeight.w500))),
              if (trailing != null) ...[const SizedBox(width: 8), trailing!],
            ]),
          ),
        Material(
          color: _boxColour,
          clipBehavior: Clip.antiAlias,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12),
              side: const BorderSide(color: _lineColour)),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            for (var i = 0; i < children.length; i++) ...[
              if (i > 0) const Divider(height: 1, thickness: 1, color: _lineColour),
              children[i],
            ],
          ]),
        ),
      ]),
    );
  }
}

/// Label (and an optional one-line description) on the left, [trailing] on the right. With [stackWhenNarrow], a
/// wide control (segmented buttons) goes under the label when there isn't room beside it.
class SettingRow extends StatelessWidget {
  const SettingRow({super.key, required this.title, this.subtitle, this.trailing, this.stackWhenNarrow = false,
      this.trailingWidth = 240, this.enabled = true});
  final String title;
  final String? subtitle;
  final Widget? trailing;
  final bool stackWhenNarrow;
  final double trailingWidth; // about how wide [trailing] is: it goes under the label if the label would get cramped
  final bool enabled;

  // the least room a label gets beside a control: past this it wraps onto more lines, so controls can stay lined up
  // (user, 2026-09-30); only when even this is not left does a control move under its label
  static const _labelRoom = 120.0;

  @override
  Widget build(BuildContext context) {
    final label = Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
      Text(title, style: TextStyle(fontSize: 14.5, color: enabled ? null : const Color(0xFF6A6A6A))),
      if (subtitle != null)
        Padding(
          padding: const EdgeInsets.only(top: 2),
          child: Text(subtitle!, style: const TextStyle(fontSize: 12, color: hintColour)),
        ),
    ]);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      child: LayoutBuilder(builder: (context, box) {
        final t = trailing;
        if (t == null) return label;
        // a short label keeps its one line; a long one gets [_labelRoom] and wraps
        final room = textWidth(context, title, 14.5).clamp(0.0, _labelRoom) + 12;
        if (stackWhenNarrow && box.maxWidth - trailingWidth < room) {
          return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            label,
            const SizedBox(height: 8),
            Align(alignment: Alignment.centerLeft,
                child: SingleChildScrollView(scrollDirection: Axis.horizontal, child: t)),
          ]);
        }
        return Row(children: [
          Expanded(child: label),
          const SizedBox(width: 12),
          // flush with the right edge; if the measurement was off, the control shrinks a little rather than
          // overflow or crush the label
          ConstrainedBox(
            constraints: BoxConstraints(maxWidth: (box.maxWidth - room).clamp(0.0, double.infinity)),
            child: FittedBox(fit: BoxFit.scaleDown, alignment: Alignment.centerRight, child: t),
          ),
        ]);
      }),
    );
  }
}

/// Lines up the segmented choices of one page or panel: each reports how wide it needs to be, and all of them are
/// drawn as wide as the widest, in one column flush with the right edge (user, 2026-09-30). A row too narrow for
/// the shared width keeps its own; one too narrow for that goes under its label.
class SettingsColumn extends StatefulWidget {
  const SettingsColumn({super.key, required this.child});
  final Widget child;

  static _SettingsColumnState? _of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<_ColumnScope>()?.state;

  @override
  State<SettingsColumn> createState() => _SettingsColumnState();
}

class _SettingsColumnState extends State<SettingsColumn> {
  double width = 0;

  /// A control needs [w]: widen the column for everyone (after this frame - it's reported while building).
  void report(double w) {
    if (w <= width + 0.5) return;
    width = w;
    WidgetsBinding.instance.addPostFrameCallback((_) { if (mounted) setState(() {}); });
  }

  @override
  Widget build(BuildContext context) => _ColumnScope(state: this, width: width, child: widget.child);
}

class _ColumnScope extends InheritedWidget {
  const _ColumnScope({required this.state, required this.width, required super.child});
  final _SettingsColumnState state;
  final double width;
  @override
  bool updateShouldNotify(_ColumnScope old) => old.width != width;
}

/// On/off, the whole row tappable (and one focus stop for the remote).
class SwitchRow extends StatelessWidget {
  const SwitchRow({super.key, required this.title, this.subtitle, required this.value, required this.onChanged});
  final String title;
  final String? subtitle;
  final bool value;
  final ValueChanged<bool>? onChanged;

  @override
  Widget build(BuildContext context) => SwitchListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: 14),
        visualDensity: VisualDensity.compact,
        title: Text(title, style: const TextStyle(fontSize: 14.5)),
        subtitle: subtitle == null ? null : Text(subtitle!, style: const TextStyle(fontSize: 12, color: hintColour)),
        value: value,
        onChanged: onChanged,
      );
}

/// One option of a [SegmentRow]: a short label, or an icon with a tooltip.
class Choice<T> {
  const Choice(this.value, this.label, {this.icon});
  final T value;
  final String label;
  final IconData? icon; // shown instead of the label (the label becomes its tooltip)
}

/// A choice between a few options, as compact segmented buttons in the row.
class SegmentRow<T> extends StatelessWidget {
  const SegmentRow({super.key, required this.title, this.subtitle, required this.choices, required this.value,
      required this.onChanged});
  final String title;
  final String? subtitle;
  final List<Choice<T>> choices;
  final T value;
  final ValueChanged<T> onChanged;

  /// How wide the buttons come out: every segment is as wide as the widest (its text, or an icon), plus padding
  /// and borders.
  double _width(BuildContext context) {
    var widest = 0.0;
    for (final c in choices) {
      final w = c.icon != null ? 22.0 : textWidth(context, c.label, 13);
      if (w > widest) widest = w;
    }
    return choices.length * (widest + 28);
  }

  @override
  Widget build(BuildContext context) {
    final own = _width(context);
    final column = SettingsColumn._of(context);
    column?.report(own);
    final shared = column == null || column.width < own ? own : column.width;
    return LayoutBuilder(builder: (context, box) {
      // the page's shared width if it fits beside the label, else this control's own
      final room = textWidth(context, title, 14.5).clamp(0.0, SettingRow._labelRoom) + 12 + 28; // + row padding
      final w = box.maxWidth - shared >= room ? shared : own;
      return _row(context, w);
    });
  }

  Widget _row(BuildContext context, double w) => SettingRow(
        title: title,
        subtitle: subtitle,
        stackWhenNarrow: true,
        trailingWidth: w,
        trailing: SizedBox(width: w, child: SegmentedButton<T>(
          expandedInsets: EdgeInsets.zero, // fills [w]: every segment as wide as the others
          style: const ButtonStyle(
            visualDensity: VisualDensity.compact,
            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            textStyle: WidgetStatePropertyAll(TextStyle(fontSize: 13)),
            padding: WidgetStatePropertyAll(EdgeInsets.symmetric(horizontal: 10)),
          ),
          showSelectedIcon: false,
          segments: [
            for (final c in choices)
              ButtonSegment(
                value: c.value,
                label: c.icon == null ? Text(c.label) : null,
                icon: c.icon == null ? null : Icon(c.icon, size: 20),
                tooltip: c.icon == null ? null : c.label,
              ),
          ],
          selected: {value},
          onSelectionChanged: (v) => onChanged(v.first),
        )),
      );
}

/// A slider with its label on the left and its value on the right.
class SliderRow extends StatelessWidget {
  const SliderRow({super.key, required this.label, required this.value, required this.onChanged,
      required this.valueText, this.min = 0, this.max = 1, this.enabled = true, this.divisions, this.icon});
  final String label;
  final IconData? icon; // shown instead of the label (the label is its tooltip)
  final double value, min, max;
  final int? divisions;
  final String valueText;
  final bool enabled;
  final ValueChanged<double> onChanged;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(14, 2, 14, 2),
        child: Row(children: [
          if (icon != null)
            Tooltip(message: label, child: Icon(icon, size: 20, color: enabled ? null : const Color(0xFF6A6A6A)))
          else
            SizedBox(width: 136, child: Text(label,
                style: TextStyle(fontSize: 14.5, color: enabled ? null : const Color(0xFF6A6A6A)))),
          Expanded(
            child: Semantics(
              label: label,
              child: Slider(value: value.clamp(min, max), min: min, max: max, divisions: divisions,
                  onChanged: enabled ? onChanged : null),
            ),
          ),
          SizedBox(width: 64, child: Text(valueText, textAlign: TextAlign.right,
              style: const TextStyle(color: hintColour, fontSize: 12.5))),
        ]),
      );
}

/// A row that goes somewhere (chevron) or does something (a button on the right).
class ActionRow extends StatelessWidget {
  const ActionRow({super.key, required this.title, this.subtitle, this.icon, this.onTap, this.button});
  final String title;
  final String? subtitle;
  final IconData? icon;
  final VoidCallback? onTap; // the whole row: opens something (chevron)
  final Widget? button; // or a button on the right
  @override
  Widget build(BuildContext context) => ListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: 14),
        visualDensity: VisualDensity.compact,
        leading: icon == null ? null : Icon(icon, size: 22),
        minLeadingWidth: 24,
        title: Text(title, style: const TextStyle(fontSize: 14.5)),
        subtitle: subtitle == null ? null : Text(subtitle!, style: const TextStyle(fontSize: 12, color: hintColour)),
        trailing: button ?? (onTap == null ? null : const Icon(Icons.chevron_right)),
        onTap: onTap,
      );
}

/// A line of small print inside a group (what a setting means, a count).
class NoteRow extends StatelessWidget {
  const NoteRow(this.text, {super.key});
  final String text;
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(14, 8, 14, 10),
        child: Text(text, style: const TextStyle(fontSize: 12, color: hintColour)),
      );
}

/// A round colour to pick (the reader's background, the accent colour): ringed and ticked when chosen.
class ColourSwatch extends StatelessWidget {
  const ColourSwatch({super.key, required this.colour, required this.label, required this.selected, required this.onTap});
  final Color colour;
  final String label; // tooltip and screen-reader name
  final bool selected;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) {
    final accent = Theme.of(context).colorScheme.primary;
    final tick = colour.computeLuminance() > 0.4 ? Colors.black : Colors.white;
    return Tooltip(
      message: label,
      child: Semantics(
        button: true,
        selected: selected,
        label: label,
        child: InkResponse(
          onTap: onTap,
          radius: 20,
          child: Padding(
            padding: const EdgeInsets.all(4),
            child: Container(
              width: 28,
              height: 28,
              decoration: BoxDecoration(
                color: colour,
                shape: BoxShape.circle,
                border: Border.all(color: selected ? accent : const Color(0xFF55585F), width: selected ? 3 : 1),
              ),
              child: selected ? Icon(Icons.check, size: 16, color: tick) : null,
            ),
          ),
        ),
      ),
    );
  }
}

/// A small status label ("Own settings", "Follows the defaults").
class StatusChip extends StatelessWidget {
  const StatusChip(this.text, {super.key, this.strong = false});
  final String text;
  final bool strong; // accent colours (own settings) vs grey (following the defaults)
  @override
  Widget build(BuildContext context) {
    final accent = Theme.of(context).colorScheme.primary;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: strong ? accent.withValues(alpha: 0.16) : const Color(0xFF26282E),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(text, style: TextStyle(fontSize: 11.5, color: strong ? accent : hintColour)),
    );
  }
}
