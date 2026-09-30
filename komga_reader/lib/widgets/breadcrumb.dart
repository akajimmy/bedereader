import 'package:flutter/material.dart';

/// A screen title with where it sits (user, 2026-09-29): "Ongoing › Absolute Flash", "Read lists › Event". The
/// parent is dimmed and gives way first when space runs out; the title keeps the most room.
class Breadcrumb extends StatelessWidget {
  const Breadcrumb({super.key, required this.title, this.parent});
  final String title;
  final String? parent; // null (not known yet, or none): just the title

  @override
  Widget build(BuildContext context) {
    final p = parent;
    if (p == null || p.isEmpty) return Text(title, overflow: TextOverflow.ellipsis);
    final dim = TextStyle(color: Colors.white.withValues(alpha: 0.55));
    return Row(children: [
      Flexible(child: Text(p, style: dim, overflow: TextOverflow.ellipsis, maxLines: 1)),
      Text('  ›  ', style: dim),
      Flexible(flex: 3, child: Text(title, overflow: TextOverflow.ellipsis, maxLines: 1)),
    ]);
  }
}
