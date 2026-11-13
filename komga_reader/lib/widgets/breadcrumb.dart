import 'package:flutter/material.dart';

/// A screen title with where it sits (user, 2026-09-29): "Ongoing › Absolute Flash", "Read lists › Event". The
/// parent is dimmed and gives way first when space runs out; the title keeps the most room. With [onParent] the
/// parent is a link (user, 2026-10-02): a tap, or OK on it with the remote, goes there.
class Breadcrumb extends StatelessWidget {
  const Breadcrumb({super.key, required this.title, this.parent, this.onParent});
  final String title;
  final String? parent; // null (not known yet, or none): just the title
  final VoidCallback? onParent;

  @override
  Widget build(BuildContext context) {
    final p = parent;
    final alone = Text(title, overflow: TextOverflow.ellipsis, maxLines: 1);
    if (p == null || p.isEmpty) return alone;
    // too narrow for the parent and the › (a phone's bar beside its buttons - it overflowed: the phone-width round,
    // 2026-11-13): the title alone
    return LayoutBuilder(builder: (context, box) => box.maxWidth < _withParent ? alone : _trail(p));
  }

  /// The least room for "parent › title"; less, and the title shows alone.
  static const _withParent = 180.0;

  Widget _trail(String p) {
    final dim = TextStyle(color: Colors.white.withValues(alpha: 0.55));
    final name = Text(p, style: dim, overflow: TextOverflow.ellipsis, maxLines: 1);
    return Row(children: [
      Flexible(
        child: onParent == null
            ? name
            : Tooltip(
                message: 'Open $p',
                child: InkWell(
                  key: const ValueKey('breadcrumb-parent'),
                  onTap: onParent,
                  borderRadius: BorderRadius.circular(6),
                  child: Padding(padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2), child: name),
                ),
              ),
      ),
      Text('  ›  ', style: dim),
      Flexible(flex: 3, child: Text(title, overflow: TextOverflow.ellipsis, maxLines: 1)),
    ]);
  }
}
