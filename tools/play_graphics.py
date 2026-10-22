"""Google Play's listing graphics, from the app icon's own geometry (tools/make_icon.py) - user, 2026-10-22: "let's
pursue getting this into the play store".

  <out>/play-icon-512.png        the store icon: 512 x 512, 32-bit PNG, full square (Play rounds the corners itself)
  <out>/play-feature-1024x500.png  the feature graphic: the icon, the name and "A library and reader for Komga"

Usage (from C:\\Claude\\KomgaClient): py -3.13 tools\\play_graphics.py <out folder>
"""
import pathlib
import sys

from PIL import Image, ImageDraw, ImageFont

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
from make_icon import BACKGROUND, raster  # noqa: E402

ROOT = pathlib.Path(__file__).resolve().parent.parent
FONT = ROOT / 'komga_reader' / 'assets' / 'fonts' / 'AtkinsonHyperlegibleNext.ttf'


def main():
    out = pathlib.Path(sys.argv[1])
    out.mkdir(parents=True, exist_ok=True)

    # the store icon: the launcher's page proportions, on the full square
    raster(512, 0.70).convert('RGBA').save(out / 'play-icon-512.png')

    # the feature graphic: dark, the icon on the left, the name and what it is beside it
    fg = Image.new('RGB', (1024, 500), BACKGROUND)
    icon = raster(300, 0.78, corner_frac=0.2)
    fg.paste(icon, (90, 100), icon)
    d = ImageDraw.Draw(fg)
    name = ImageFont.truetype(str(FONT), 92)
    tag = ImageFont.truetype(str(FONT), 38)
    d.text((440, 165), 'BeDeReader', font=name, fill='#FFFFFF')
    d.text((444, 290), 'A library and reader for Komga', font=tag, fill='#B8BCC6')
    fg.save(out / 'play-feature-1024x500.png')
    print('written to', out)


if __name__ == '__main__':
    main()
