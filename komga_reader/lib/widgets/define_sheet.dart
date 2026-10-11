import 'package:flutter/material.dart';

import '../dictionary.dart';

/// Whether [selected] is short enough to look up: a word or a phrase of up to three, with a letter in it.
bool definable(String selected) {
  final s = selected.trim();
  return s.isNotEmpty && s.length <= 40 && s.split(RegExp(r'\s+')).length <= 3 && RegExp(r'[A-Za-z]').hasMatch(s);
}

/// eBooks' Define (user, 2026-10-11): what the selected word means, from the offline English dictionary - a sheet
/// over the page; Back or a tap outside closes it.
Future<void> showDefinition(BuildContext context, String selected, {Future<EnglishDictionary>? dictionary}) =>
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      constraints: const BoxConstraints(maxWidth: 640),
      builder: (_) => DefineSheet(selected: selected, dictionary: dictionary ?? EnglishDictionary.load()),
    );

class DefineSheet extends StatelessWidget {
  const DefineSheet({super.key, required this.selected, required this.dictionary});
  final String selected;
  final Future<EnglishDictionary> dictionary;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    return ConstrainedBox(
      constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * 0.6),
      child: FutureBuilder<EnglishDictionary>(
        future: dictionary,
        builder: (context, snap) {
          if (snap.hasError) {
            return _padded(Text("Couldn't open the dictionary: ${snap.error}", key: const ValueKey('define.error')));
          }
          if (!snap.hasData) {
            return const SizedBox(height: 160, child: Center(child: CircularProgressIndicator()));
          }
          final found = snap.data!.lookup(selected);
          if (found.isEmpty) {
            return _padded(Text('"${selected.trim()}" isn\'t in the English dictionary.',
                key: const ValueKey('define.none')));
          }
          return ListView(
            key: const ValueKey('define.list'),
            shrinkWrap: true,
            padding: const EdgeInsets.fromLTRB(24, 20, 24, 28),
            children: [
              for (final d in found) ...[
                Text(d.word, key: ValueKey('define.word.${d.word}'), style: t.headlineSmall),
                const SizedBox(height: 4),
                for (final (i, m) in d.meanings.indexed)
                  Padding(
                    padding: const EdgeInsets.only(top: 10),
                    child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      SizedBox(width: 28, child: Text('${i + 1}.', style: t.bodyMedium)),
                      Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Text.rich(TextSpan(children: [
                          TextSpan(text: '${m.partOfSpeech}  ',
                              style: t.bodyMedium?.copyWith(color: scheme.primary, fontStyle: FontStyle.italic)),
                          TextSpan(text: m.definition, style: t.bodyMedium),
                        ])),
                        if (m.example.isNotEmpty)
                          Padding(
                            padding: const EdgeInsets.only(top: 2),
                            child: Text('"${m.example}"', style: t.bodySmall?.copyWith(
                                fontStyle: FontStyle.italic, color: scheme.onSurfaceVariant)),
                          ),
                      ])),
                    ]),
                  ),
                const SizedBox(height: 18),
              ],
              Text('Open English WordNet', style: t.labelSmall?.copyWith(color: scheme.onSurfaceVariant)),
            ],
          );
        },
      ),
    );
  }

  Widget _padded(Widget child) => Padding(padding: const EdgeInsets.fromLTRB(24, 28, 24, 36), child: child);
}
