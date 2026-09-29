import 'package:flutter/material.dart';

import '../offline/sync.dart';

/// After progress made offline reached Komga: the books whose progress had also changed on Komga, what each side
/// had and what was kept (further wins).
Future<void> showSyncConflicts(BuildContext context, SyncResult r) => showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        icon: const Icon(Icons.sync_problem, color: Color(0xFFFACC15)),
        title: Text(r.conflicts.length == 1
            ? 'Reading progress: 1 book had changed on Komga too'
            : 'Reading progress: ${r.conflicts.length} books had changed on Komga too'),
        content: SizedBox(
          width: 480,
          child: ListView(shrinkWrap: true, children: [
            const Padding(
              padding: EdgeInsets.only(bottom: 8),
              child: Text('The further one was kept in each case.', style: TextStyle(color: Color(0xFF9A9A9A))),
            ),
            for (final c in r.conflicts)
              ListTile(
                contentPadding: EdgeInsets.zero,
                dense: true,
                title: Text(c.title),
                subtitle: Text('Here: ${c.here}  ·  Komga: ${c.komga}\n'
                    'Kept: ${c.keptHere ? c.here : c.komga} (${c.keptHere ? 'this device' : 'Komga'})'),
                isThreeLine: true,
              ),
            if (r.sent > 0 || r.gone > 0)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(syncSummary(r, conflicts: false), style: const TextStyle(color: Color(0xFF9A9A9A))),
              ),
          ]),
        ),
        actions: [FilledButton(autofocus: true, onPressed: () => Navigator.of(context).pop(), child: const Text('OK'))],
      ),
    );

/// "Sent reading progress for 3 books to Komga" (+ books no longer on the server).
String syncSummary(SyncResult r, {bool conflicts = true}) => [
      if (r.sent > 0) 'Sent reading progress for ${r.sent} ${r.sent == 1 ? 'book' : 'books'} to Komga',
      if (conflicts && r.conflicts.isNotEmpty) '${r.conflicts.length} had changed on Komga too',
      if (r.gone > 0) '${r.gone} ${r.gone == 1 ? 'book is' : 'books are'} no longer on Komga',
    ].join(' · ');
