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

  static const _labelRoom = 220.0; // the least the label gets beside a control before the control moves under it

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
        // the label keeps its one line beside the control, up to [_labelRoom] (a longer one may wrap)
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
          // if the measurement was off, the control shrinks a little rather than overflow or crush the label
          Flexible(child: FittedBox(fit: BoxFit.scaleDown, alignment: Alignment.centerRight, child: t)),
        ]);
      }),
    );
  }
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
  Widget build(BuildContext context) => SettingRow(
        title: title,
        subtitle: subtitle,
        stackWhenNarrow: true,
        trailingWidth: _width(context),
        trailing: SegmentedButton<T>(
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
        ),
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
