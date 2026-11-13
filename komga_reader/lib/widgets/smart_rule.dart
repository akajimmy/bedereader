import 'package:flutter/material.dart';

import '../offline/downloads.dart';
import '../offline/smart_downloads.dart';
import '../pins.dart';

/// A rule's mark (the poster's, the menus', the Smart downloads list's): kept topped up.
const smartIcon = Icons.autorenew;

/// The menu entry for a series', read list's or pin's rule (when downloads are available here): what it keeps now.
List<Widget> keepTiles(BuildContext ctx, SmartRule? rule) => !Downloads.instance.anyReady
    ? const []
    : [
        ListTile(
          leading: const Icon(smartIcon),
          title: const Text('Keep downloaded'),
          subtitle: Text(rule == null ? 'Off' : 'The next ${rule.keep} unread'),
          onTap: () => Navigator.pop(ctx, 'keep'),
        ),
      ];

/// How many unread books ahead to keep downloaded for [title]: 0 = off; null = cancelled.
Future<int?> pickKeep(BuildContext context, String title, int? now) => showDialog<int>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: Text('Keep downloaded: $title'),
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 0, 24, 8),
            child: Text('Its next unread books, topped up whenever the server or share answers. A book read goes at '
                'the next top-up; books you download yourself stay.', style: Theme.of(ctx).textTheme.bodySmall),
          ),
          for (final n in [0, for (var i = 1; i <= SmartRule.most; i++) i])
            ListTile(
              // (a new rule: the focus on the usual 3 - user, 11-12; the remote moves from there)
              autofocus: n == (now ?? SmartRule.defaultKeep),
              leading: SizedBox(width: 24, child: (now ?? 0) == n ? const Icon(Icons.check, size: 18) : null),
              title: Text(n == 0 ? 'Off' : 'The next $n'),
              onTap: () => Navigator.pop(ctx, n),
            ),
        ],
      ),
    );

/// Asks, then sets, a series' or read list's rule.
Future<void> editRule(BuildContext context, RuleKind kind, String id, String title) async {
  final s = SmartDownloads.instance;
  final n = await pickKeep(context, title, s.ruleFor(kind, id)?.keep);
  if (n != null) await s.setRule(kind, id, title, n);
}

/// Asks, then sets, a pin's rule.
Future<void> editPinRule(BuildContext context, Pin p) async {
  final s = SmartDownloads.instance;
  final n = await pickKeep(context, p.name, s.ruleForPin(p)?.keep);
  if (n != null) await s.setPinRule(p, n);
}
