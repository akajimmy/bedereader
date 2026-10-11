"""Builds the app's offline English dictionary (komga_reader/assets/dictionary/en.txt.gz) from Open English WordNet.

Source: english-wordnet-2025-json.zip, from https://github.com/globalwordnet/english-wordnet/releases (2025-edition),
unpacked into tools/dictionary/source/json/ (the source isn't kept in git - download it again to rebuild).
Licence: CC BY 4.0 (Open English WordNet) over the WordNet License (Princeton) - both credited in
THIRD_PARTY_NOTICES.md.

The asset, UTF-8, gzipped, two sections split by an empty line:
  1. one meaning per line: "<part of speech>\t<definition>\t<one example or nothing>" (n, v, a, r; s -> a)
  2. one word per line, lower case: "<word>\t<meaning numbers, comma-separated, in WordNet's order>"
     then, for irregular forms, "<form>\t=<word>[,<word>...]" (mice =mouse, went =go)
Run from the repository root: python -I tools/dictionary/build_dictionary.py
"""
import glob
import gzip
import json
import os
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
SRC = os.path.join(ROOT, 'tools', 'dictionary', 'source', 'json')
OUT = os.path.join(ROOT, 'komga_reader', 'assets', 'dictionary', 'en.txt.gz')


def clean(s):
    return ' '.join(s.replace('\t', ' ').split())


def main():
    synsets = {}
    for f in sorted(glob.glob(os.path.join(SRC, '*.json'))):
        name = os.path.basename(f)
        if name.startswith('entries-') or name == 'frames.json':
            continue
        with open(f, encoding='utf-8') as fh:
            synsets.update(json.load(fh))
    order = sorted(synsets)
    number = {sid: i for i, sid in enumerate(order)}

    words = {}  # lower-case word -> meaning numbers, in order, no repeats
    forms = {}  # lower-case irregular form -> words
    for f in sorted(glob.glob(os.path.join(SRC, 'entries-*.json'))):
        with open(f, encoding='utf-8') as fh:
            entries = json.load(fh)
        for word, parts in entries.items():
            key = word.lower()
            seen = words.setdefault(key, [])
            for part in parts.values():
                for sense in part.get('sense', []):
                    n = number.get(sense['synset'])
                    if n is not None and n not in seen:
                        seen.append(n)
                for form in part.get('form', []):
                    fl = form.lower()
                    if fl != key:
                        forms.setdefault(fl, [])
                        if key not in forms[fl]:
                            forms[fl].append(key)

    lines = []
    for sid in order:
        s = synsets[sid]
        pos = s.get('partOfSpeech', sid[-1])
        pos = 'a' if pos == 's' else pos
        definition = clean('; '.join(s.get('definition', [])))
        examples = s.get('example', [])
        example = examples[0] if examples else ''
        if isinstance(example, dict):  # some examples carry a source
            example = example.get('text', '')
        lines.append(f'{pos}\t{definition}\t{clean(example)}')
    lines.append('')
    for w in sorted(words):
        if words[w]:
            lines.append(f'{w}\t{",".join(map(str, words[w]))}')
    for fm in sorted(forms):
        lines.append(f'{fm}\t={",".join(forms[fm])}')

    os.makedirs(os.path.dirname(OUT), exist_ok=True)
    data = ('\n'.join(lines) + '\n').encode('utf-8')
    with open(OUT, 'wb') as raw, gzip.GzipFile(fileobj=raw, mode='wb', compresslevel=9, mtime=0) as fh:
        fh.write(data)  # mtime 0: the same source gives the same file
    print(f'{len(order)} meanings, {len(words)} words, {len(forms)} irregular forms; '
          f'{len(data) / 1e6:.1f} MB, {os.path.getsize(OUT) / 1e6:.1f} MB gzipped -> {OUT}')


if __name__ == '__main__':
    sys.exit(main())
