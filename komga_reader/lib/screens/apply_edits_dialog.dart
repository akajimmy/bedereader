import 'dart:async';

import 'package:flutter/material.dart';

import '../local/apply_edits.dart';
import '../local/local_library.dart';
import '../local/local_meta.dart' show fileNameOf;
import '../local/local_source.dart';
import '../widgets/error_text.dart';

// Apply edits to files (user, 2026-10-27; reports\10-27-apply-edits-plan.md): from Settings > Libraries, a library's
// edits put into its files - after a confirmation that sums up what will change, then a count as it goes.

/// The fields' words, in the order they're listed.
const _fieldWords = {
  'title': 'title', 'series': 'series', 'number': 'number', 'releaseDate': 'release date', 'summary': 'summary',
  'authors': 'credits', 'tags': 'tags',
};

/// "a", "a and b", "a, b and c".
String _list(List<String> words) =>
    words.length < 2 ? words.join() : '${words.sublist(0, words.length - 1).join(', ')} and ${words.last}';

String _books(int n) => n == 1 ? '1 book' : '$n books';

/// What the confirmation says [plan] will do: a line for each kind of change it makes, and only those - the fields
/// written named only if edited, which files take them only when that's not all of them, what can't be done.
List<String> applySummary(ApplyPlan plan) {
  final lines = <String>[];
  final folders = plan.folders.length;
  if (folders == 1) {
    final f = plan.folders.single;
    lines.add('The folder "${fileNameOf(f.from)}" is renamed "${fileNameOf(f.to)}", after its series.');
  } else if (folders > 1) {
    lines.add('$folders series folders are renamed after their series.');
  }
  final moved = plan.moved.length;
  if (moved > 0) lines.add('${_books(moved)} ${moved == 1 ? 'moves' : 'move'} into ${moved == 1 ? 'its' : 'their'} series\' folder.');
  final renamed = plan.renamed.where((b) => !b.moved).toList();
  if (renamed.isNotEmpty) {
    final e = renamed.first;
    lines.add('${renamed.length == 1 ? 'A book file is' : '${renamed.length} book files are'} renamed after '
        '${renamed.length == 1 ? 'its' : 'their'} series and number - "${fileNameOf(e.from)}" becomes "${fileNameOf(e.to)}".');
  }
  final written = plan.written.toList();
  if (written.isNotEmpty) {
    final fields = [for (final MapEntry(:key, :value) in _fieldWords.entries) if (plan.fieldsWritten.contains(key)) value];
    final epubs = written.where((b) => b.book.epub).length, cbzs = written.length - epubs;
    final which = epubs == 0 ? 'CBZ' : cbzs == 0 ? 'EPUB' : 'CBZ and EPUB';
    lines.add(plan.cbrs.isEmpty
        ? 'The edited ${_list(fields)} ${fields.length == 1 ? 'is' : 'are'} written into the books themselves.'
        : 'In the $which files, the edited ${_list(fields)} ${fields.length == 1 ? 'is' : 'are'} written into the '
            'books themselves. CBR files can\'t be written to: theirs stay beside them only.');
  }
  return [...lines, for (final p in plan.problems) 'Not done: $p'];
}

/// Settings > Libraries' Apply edits to files on [library]: its plan worked out, confirmed, carried out with a count,
/// and what happened said.
Future<void> applyEditsTo(BuildContext context, LocalSource local, LocalLibrary library) async {
  final ApplyPlan plan;
  try {
    plan = await local.planApply(library);
  } catch (e, st) {
    if (context.mounted) showErrorSnack(context, "Couldn't look at ${library.name}'s edits", e, st);
    return;
  }
  if (!context.mounted) return;
  if (plan.isEmpty) {
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Nothing to apply'),
        content: Text(plan.problems.isEmpty
            ? '${library.name} has no edits that change its files.'
            : [...plan.problems].join('\n')),
        actions: [TextButton(autofocus: true, onPressed: () => Navigator.pop(ctx), child: const Text('OK'))],
      ),
    );
    return;
  }
  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text('Apply edits to ${library.name}?'),
      content: SizedBox(width: 460, child: SingleChildScrollView(child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('Your edits will be applied to the files:'),
          const SizedBox(height: 8),
          for (final line in applySummary(plan))
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                const Text('•  '),
                Expanded(child: Text(line)),
              ]),
            ),
          const SizedBox(height: 4),
          Text('Your edits are kept beside the books as well. Reading progress, pins and downloads stay with the books.',
              style: Theme.of(ctx).textTheme.bodySmall),
        ],
      ))),
      actions: [
        TextButton(autofocus: true, onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
        FilledButton(key: const ValueKey('apply-edits'), onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Apply')),
      ],
    ),
  );
  if (ok != true || !context.mounted) return;

  final progress = ValueNotifier<(int, int)>((0, plan.folders.length + plan.books.length));
  final nav = Navigator.of(context);
  unawaited(showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (_) => PopScope(
      canPop: false,
      child: AlertDialog(
        content: ValueListenableBuilder<(int, int)>(
          valueListenable: progress,
          builder: (_, p, __) => Row(children: [
            const SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2.5)),
            const SizedBox(width: 18),
            Expanded(child: Text('Applying edits… ${p.$1} of ${p.$2}')),
          ]),
        ),
      ),
    ),
  ));
  ApplyResult? result;
  Object? error;
  try {
    result = await local.applyEdits(plan, onStep: (done, all) => progress.value = (done, all));
  } catch (e) {
    error = e;
  }
  nav.pop();
  if (!context.mounted) return;
  final failures = [if (error != null) '$error', ...?result?.failures];
  if (failures.isEmpty) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Edits applied to ${library.name}')));
    return;
  }
  await showDialog<void>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('Some edits weren\'t applied'),
      content: SizedBox(width: 460, child: SingleChildScrollView(child: Text(failures.join('\n\n')))),
      actions: [TextButton(autofocus: true, onPressed: () => Navigator.pop(ctx), child: const Text('OK'))],
    ),
  );
}
