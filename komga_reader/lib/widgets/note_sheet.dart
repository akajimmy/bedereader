import 'package:flutter/material.dart';

/// eBooks' footnotes and endnotes: the note a marker ([marker]: "*", "12") points to, in a sheet over the page, as
/// Define shows a word (user, 2026-10-11: the dialog was ugly - "make it look more like the definition panel"); Back
/// or a tap outside closes it.
Future<void> showNote(BuildContext context, String marker, String note) => showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      constraints: const BoxConstraints(maxWidth: 640),
      builder: (_) => NoteSheet(marker: marker, note: note),
    );

class NoteSheet extends StatelessWidget {
  const NoteSheet({super.key, required this.marker, required this.note});
  final String marker, note;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    final mark = marker.replaceAll(RegExp(r'[\[\]()]'), '').trim();
    return ConstrainedBox(
      constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * 0.6),
      child: ListView(
        key: const ValueKey('note.sheet'),
        shrinkWrap: true,
        padding: const EdgeInsets.fromLTRB(24, 20, 24, 28),
        children: [
          Text.rich(TextSpan(children: [
            TextSpan(text: 'Note', style: t.headlineSmall),
            if (mark.isNotEmpty)
              TextSpan(text: '  $mark', style: t.headlineSmall?.copyWith(color: scheme.primary)),
          ])),
          const SizedBox(height: 14),
          Text(note, style: t.bodyLarge?.copyWith(height: 1.45)),
        ],
      ),
    );
  }
}
