"""Pull numbered pages out of a CBZ, numbered the way Komga shows them (image files in natural name order, 1-based).

    python tools\\extract_pages.py <book.cbz> <page> [<page> ...]

Writes <book name> p<N>.<ext> next to the CBZ and prints each page's size and pixel dimensions.
"""
import pathlib
import re
import sys
import zipfile

from PIL import Image

IMAGE = re.compile(r'\.(jpe?g|png|webp|gif|bmp)$', re.I)


def natural(name):
    return [int(t) if t.isdigit() else t.lower() for t in re.split(r'(\d+)', name)]


def main():
    cbz = pathlib.Path(sys.argv[1])
    wanted = [int(a) for a in sys.argv[2:]]
    with zipfile.ZipFile(cbz) as z:
        pages = sorted((n for n in z.namelist() if IMAGE.search(n) and not n.endswith('/')), key=natural)
        print(f'{cbz.name}: {len(pages)} pages')
        for p in wanted:
            name = pages[p - 1]
            out = cbz.with_name(f'{cbz.stem} p{p}{pathlib.Path(name).suffix.lower()}')
            out.write_bytes(z.read(name))
            with Image.open(out) as im:
                print(f'  page {p} = {name}: {im.width}x{im.height} {im.mode}, {out.stat().st_size // 1024} KB -> {out.name}')


if __name__ == '__main__':
    main()
