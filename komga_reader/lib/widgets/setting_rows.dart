import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

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

/// One settings row for the remote: Up and Down from anywhere in it go to the first control of the previous / next
/// row - not to whatever control is nearest straight up or down, which skipped a row when a wide control sat over a
/// short one (user, 2026-09-30). Left and Right still move within the row. Rows can nest (Home's sections inside
/// their group): the innermost counts. Where there's no row that way (the page list above the first row, say),
/// the usual navigation takes over.
class RowNav extends StatefulWidget {
  const RowNav({super.key, required this.child});
  final Widget child;

  /// The row [n] is in (its innermost), or null - from the rows' own list, never a debug label (see [_rows]).
  static FocusNode? rowOf(FocusNode n) => _RowNavState._rowOf(n);

  @override
  State<RowNav> createState() => _RowNavState();
}

class _RowNavState extends State<RowNav> {
  // (no debugLabel: Flutter keeps those in debug builds only, so nothing may tell rows apart by one)
  final _node = FocusNode(canRequestFocus: false, skipTraversal: true);

  /// Every row's focus node, as rows are told apart. Not by the node's debugLabel: Flutter keeps that in debug builds
  /// only - in the release app every label was empty, no row was ever found, and Up / Down fell back to Flutter's
  /// straight-down rule, skipping rows (user, 2026-10-07: the fix of 2026-09-30 never worked on the tablet; the tests
  /// run in debug mode and passed).
  static final Set<FocusNode> _rows = {};

  @override
  void initState() {
    super.initState();
    _rows.add(_node);
  }

  static FocusNode? _rowOf(FocusNode n) {
    for (final a in n.ancestors) {
      if (_rows.contains(a)) return a;
    }
    return null;
  }

  KeyEventResult _onKey(FocusNode _, KeyEvent e) {
    if (e is! KeyDownEvent && e is! KeyRepeatEvent) return KeyEventResult.ignored;
    final down = e.logicalKey == LogicalKeyboardKey.arrowDown;
    if (!down && e.logicalKey != LogicalKeyboardKey.arrowUp) return KeyEventResult.ignored;
    final current = FocusManager.instance.primaryFocus;
    final scope = current?.nearestScope;
    if (current == null || scope == null) return KeyEventResult.ignored;
    final mine = _rowOf(current); // the innermost row the focus is in (a nested row handles it first)
    if (mine != _node) return KeyEventResult.ignored;
    // every control in a row, in the order they're laid out: by their row's place on screen, then the focus order
    // within the row. The focus order alone is the order controls were attached - rows built later (the library
    // switches, after the libraries arrive) came after everything else. Controls outside rows (Settings' list of
    // pages beside them, the top bar) aren't part of it (missing-tests audit, 2026-09-30).
    final found = [
      for (final n in scope.traversalDescendants)
        if (n.canRequestFocus && !n.skipTraversal && _rowOf(n) != null) n,
    ];
    double top(FocusNode n) { // the outermost row's top: a row and the rows nested in it stay together, in focus order
      FocusNode at = n;
      for (final a in n.ancestors) {
        if (_rows.contains(a)) at = a;
      }
      return at.rect.top;
    }
    final order = {for (var i = 0; i < found.length; i++) found[i]: i};
    final all = [...found]..sort((a, b) {
        final byRow = top(a).compareTo(top(b));
        return byRow != 0 ? byRow : order[a]!.compareTo(order[b]!);
      });
    final at = all.indexOf(current);
    if (at < 0) return KeyEventResult.ignored;
    FocusNode? target;
    if (down) {
      for (var j = at + 1; j < all.length; j++) {
        if (_rowOf(all[j]) != mine) {
          target = all[j]; // the first control after this row: the next row's first
          break;
        }
      }
    } else {
      for (var j = at - 1; j >= 0; j--) {
        final row = _rowOf(all[j]);
        if (row != mine) {
          var k = j; // the previous row's last control: back to its first
          while (k > 0 && row != null && _rowOf(all[k - 1]) == row) {
            k--;
          }
          target = all[k];
          break;
        }
      }
    }
    if (target == null || _rowOf(target) == null) return KeyEventResult.ignored; // not a row: the usual way
    target.requestFocus();
    // and into view, as Flutter's own arrow navigation does: on a page taller than the screen, Down left the focus
    // on a row below the bottom edge (test audit, 2026-09-30)
    final ctx = target.context;
    if (ctx != null) {
      Scrollable.ensureVisible(ctx,
          duration: const Duration(milliseconds: 150),
          alignmentPolicy:
              down ? ScrollPositionAlignmentPolicy.keepVisibleAtEnd : ScrollPositionAlignmentPolicy.keepVisibleAtStart);
    }
    return KeyEventResult.handled;
  }

  @override
  void dispose() {
    _rows.remove(_node);
    _node.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Focus(focusNode: _node, onKeyEvent: _onKey, child: widget.child);
}

/// A labelled box of rows.
class SettingsGroup extends StatelessWidget {
  const SettingsGroup({super.key, this.title, required this.children, this.trailing, this.synced = false});
  final String? title;
  final Widget? trailing; // beside the label (a status chip, say)
  final List<Widget> children;

  /// Synced through Komga - every device: a cloud and "synced" beside the label (user, 2026-10-07).
  final bool synced;

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
              if (synced) ...[
                const SizedBox(width: 8),
                const Icon(Icons.cloud_outlined, size: 14, color: hintColour),
                const SizedBox(width: 4),
                const Text('synced', style: TextStyle(color: hintColour, fontSize: 12)),
              ],
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
              RowNav(child: children[i]), // Up / Down: row to row
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
            // under the label, a control too wide for the row shrinks to fit rather than scroll off the edge (it cut
            // off "Keep the screen on" in the reader's side sheet - tablet bug, 2026-09-30)
            Align(alignment: Alignment.centerLeft,
                child: FittedBox(fit: BoxFit.scaleDown, alignment: Alignment.centerLeft, child: t)),
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

/// One on/off choice of a [ToggleChipsRow].
class ToggleChip {
  const ToggleChip(this.label, this.on, this.onChanged);
  final String label;
  final bool on;
  final ValueChanged<bool> onChanged;
}

/// A few things that are each on or off, as chips under the label (user, 2026-10-07: the posters' three caption
/// lines; the position text's spots) - any combination.
class ToggleChipsRow extends StatelessWidget {
  const ToggleChipsRow({super.key, required this.title, this.subtitle, required this.chips});
  final String title;
  final String? subtitle;
  final List<ToggleChip> chips;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(14, 10, 14, 10),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(title, style: const TextStyle(fontSize: 14.5)),
          if (subtitle != null) Text(subtitle!, style: const TextStyle(fontSize: 12, color: hintColour)),
          const SizedBox(height: 8),
          Wrap(spacing: 6, runSpacing: 6, children: [
            for (final c in chips)
              FilterChip(label: Text(c.label), selected: c.on, onSelected: c.onChanged, visualDensity: VisualDensity.compact),
          ]),
        ]),
      );
}

/// One option of a [SegmentRow]: a short label, or an icon with a tooltip.
class Choice<T> {
  const Choice(this.value, this.label, {this.icon, this.iconWidget, this.mark});
  final T value;
  final String label;
  final IconData? icon; // shown instead of the label (the label becomes its tooltip)
  final Widget? iconWidget; // or a ready-made icon (a turned one, say)
  final IconData? mark; // a small icon beside the label (Rotation: the lock in force is a switch - tap to turn over)
}

/// A choice between a few options, as compact segmented buttons in the row.
class SegmentRow<T> extends StatelessWidget {
  const SegmentRow({super.key, required this.title, this.subtitle, required this.choices, required this.value,
      required this.onChanged, this.enabled = true, this.onReselect, this.markRoom = false});
  final bool enabled; // off: greyed out, showing the value (a series following the defaults)
  final String title;
  final String? subtitle;
  final List<Choice<T>> choices;
  final T value;
  final ValueChanged<T> onChanged;
  final ValueChanged<T>? onReselect; // the choice in force tapped again (Rotation: turns the lock over)
  final bool markRoom; // room for a mark kept whether one shows or not: the buttons never change size (user)

  /// How wide the buttons come out: every segment is as wide as the widest (its text, or an icon), plus padding
  /// and borders.
  double _width(BuildContext context) {
    var widest = 0.0;
    for (final c in choices) {
      final w = c.icon != null || c.iconWidget != null
          ? 22.0
          : textWidth(context, c.label, 13) + (c.mark != null || markRoom ? 22 : 0); // (a mark: 16 and a gap)
      if (w > widest) widest = w;
    }
    return choices.length * (widest + 28);
  }

  @override
  Widget build(BuildContext context) {
    final own = _width(context);
    final column = SettingsColumn._of(context);
    return LayoutBuilder(builder: (context, box) {
      final inner = box.maxWidth - 28; // inside the row's padding
      final room = textWidth(context, title, 14.5).clamp(0.0, SettingRow._labelRoom) + 12;
      if (inner - own >= room) {
        // beside the label, in the page's shared column: only controls that sit beside their label set its width -
        // one that has to go under its label counting made the column too wide for anyone (tablet, 2026-09-30)
        column?.report(own);
        final shared = column == null || column.width < own ? own : column.width;
        final w = inner - shared >= room ? shared : own;
        return SettingRow(title: title, enabled: enabled, subtitle: subtitle, trailingWidth: w,
            trailing: SizedBox(width: w, child: _buttons(context)));
      }
      // under the label: the full width of the row (shrunk to fit if even that's too narrow)
      return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        SettingRow(title: title, enabled: enabled, subtitle: subtitle),
        Padding(
          padding: const EdgeInsets.fromLTRB(14, 0, 14, 12),
          child: FittedBox(fit: BoxFit.scaleDown, alignment: Alignment.centerLeft,
              child: SizedBox(width: own > inner ? own : inner, child: _buttons(context))),
        ),
      ]);
    });
  }

  Widget _buttons(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return SegmentedButton<T>(
          expandedInsets: EdgeInsets.zero, // fills its width: every segment as wide as the others
          style: ButtonStyle(
            visualDensity: VisualDensity.compact,
            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            textStyle: const WidgetStatePropertyAll(TextStyle(fontSize: 13)),
            padding: const WidgetStatePropertyAll(EdgeInsets.symmetric(horizontal: 10)),
            // disabled (a series following the defaults), the choice in force stays highlighted - dimmed - so the
            // value shows; Flutter draws a disabled selection with no highlight at all (user, 2026-09-30)
            backgroundColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected)
                ? (s.contains(WidgetState.disabled) ? scheme.primary.withValues(alpha: 0.35) : scheme.primary)
                : null),
            foregroundColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected)
                ? (s.contains(WidgetState.disabled) ? Colors.white70 : scheme.onPrimary)
                : null),
          ),
          showSelectedIcon: false,
          segments: [
            for (final c in choices)
              ButtonSegment(
                value: c.value,
                label: c.icon == null && c.iconWidget == null ? Text(c.label) : null,
                icon: c.iconWidget ?? (c.icon != null ? Icon(c.icon, size: 20) : c.mark != null ? Icon(c.mark, size: 16) : null),
                tooltip: c.icon == null && c.iconWidget == null ? null : c.label,
              ),
          ],
          selected: {value},
          // a tap on the selected one empties the selection: that's the re-tap (it stays selected)
          emptySelectionAllowed: onReselect != null,
          onSelectionChanged: enabled ? (v) => v.isEmpty ? onReselect?.call(value) : onChanged(v.first) : null,
        );
  }
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
  Widget build(BuildContext context) {
    final muted = enabled ? null : const Color(0xFF6A6A6A);
    final value_ = Text(valueText, textAlign: TextAlign.right, style: const TextStyle(color: hintColour, fontSize: 12.5));
    final slider = Semantics(
      label: label,
      // directional navigation: Left/Right adjust, Up/Down move on to the next row - in Flutter's usual mode a slider
      // keeps all four arrows, and the remote couldn't get off it (tablet bug, 2026-09-30)
      child: MediaQuery(
        data: MediaQuery.of(context).copyWith(navigationMode: NavigationMode.directional),
        child: Slider(value: value.clamp(min, max), min: min, max: max, divisions: divisions,
            onChanged: enabled ? onChanged : null),
      ),
    );
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 2, 14, 2),
      child: LayoutBuilder(builder: (context, box) {
        // a narrow row (the reader's side sheet): the label and value on a line, the slider the full width under
        // them - beside a label it got only ~120 px there (tablet bug, 2026-09-30)
        if (icon == null && box.maxWidth < 440) {
          return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Row(children: [
                Expanded(child: Text(label, style: TextStyle(fontSize: 14.5, color: muted))),
                value_,
              ]),
            ),
            slider,
          ]);
        }
        return Row(children: [
          if (icon != null)
            Tooltip(message: label, child: Icon(icon, size: 20, color: muted))
          else
            SizedBox(width: 136, child: Text(label, style: TextStyle(fontSize: 14.5, color: muted))),
          Expanded(child: slider),
          SizedBox(width: 64, child: value_),
        ]);
      }),
    );
  }
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
                // a dark one keeps a lighter ring, or it's lost on the dark background (user, 2026-10-07: Black)
                border: selected
                    ? Border.all(color: accent, width: 3)
                    : colour.computeLuminance() < 0.05
                        ? Border.all(color: const Color(0xFF9A9A9A), width: 1.5)
                        : Border.all(color: const Color(0xFF55585F)),
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
