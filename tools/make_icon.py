"""App icon: a comic page with five panels (layout from the user's sketch, 2026-09-28) - two on top (wide | narrow),
one wide band, two at the bottom (narrow | wide) - tidied onto a grid: equal page margins, equal gutters, softly
rounded corners, flat colours.

One set of geometry drives every output:
  tools/icon.svg                                 the icon as SVG (source / preview)
  res/drawable/ic_launcher_foreground.xml        Android adaptive-icon foreground as a vector (crisp at any size)
  res/values/ic_launcher_background.xml          adaptive-icon background colour
  res/mipmap-*/ic_launcher.png                   pre-Android-8 launcher icons
  assets/icon.png                                the icon inside the app (Info screen)
  windows/runner/resources/app_icon.ico          Windows app icon
  tools/icon_preview.png                         how launchers show it
Usage (from C:\\Claude\\KomgaClient): py -3.13 tools\\make_icon.py

THE EXPERIMENT'S COPY (BeDeReader Exp, branch experimental/sources): the same page over yellow and black diagonal
stripes - "under construction" - instead of the dark background (user, 2026-10-26), so it can't be mistaken for the
real app. Here the script also
writes the iOS icons (ios/Runner/Assets.xcassets/AppIcon.appiconset) and the Android adaptive icon's background as a
vector (res/drawable/ic_launcher_background.xml). Not to go to 1.6.
"""
import pathlib

from PIL import Image, ImageDraw

ROOT = pathlib.Path(__file__).resolve().parent.parent
APP = ROOT / 'komga_reader'
RES = APP / 'android' / 'app' / 'src' / 'main' / 'res'

BACKGROUND = '#16181D'
STRIPES = ('#FACC15', '#111111')  # yellow ground, black bands: "under construction" (user, 2026-10-26)
STRIPE = 9.0  # each band's width across it, on the 108-unit canvas
PAGE = '#FFFFFF'
COLOURS = {'cyan': '#22D3EE', 'purple': '#A855F7', 'yellow': '#FACC15', 'red': '#EF4444', 'slate': '#475569'}


def layout(x, y, w, h):
    """Page at (x, y, w, h) -> list of (x, y, w, h, radius, colour), page first."""
    m = w * 0.075          # page margin
    g = w * 0.06           # gutter
    r_page = w * 0.07
    r = w * 0.03
    ix, iy, iw, ih = x + m, y + m, w - 2 * m, h - 2 * m
    top = ih * 0.30
    band = ih * 0.25
    bottom = ih - top - band - 2 * g
    col = iw - g
    shapes = [(x, y, w, h, r_page, PAGE)]
    shapes.append((ix, iy, col * 0.62, top, r, COLOURS['cyan']))
    shapes.append((ix + col * 0.62 + g, iy, col * 0.38, top, r, COLOURS['purple']))
    shapes.append((ix, iy + top + g, iw, band, r, COLOURS['yellow']))
    by = iy + top + band + 2 * g
    shapes.append((ix, by, col * 0.36, bottom, r, COLOURS['red']))
    shapes.append((ix + col * 0.36 + g, by, col * 0.64, bottom, r, COLOURS['slate']))
    return shapes


def dark_bands(canvas):
    """The black stripes on a square canvas: polygons between the lines x + y = c and c + step (running "/" at 45°),
    every other band, reaching past the edges (whatever draws them clips)."""
    step = STRIPE * canvas / 108 * 2 ** 0.5
    bands = []
    c = -step / 2
    k = 0
    while c < 2 * canvas:
        if k % 2:
            bands.append([(c, 0), (c + step, 0), (c + step - 2 * canvas, 2 * canvas), (c - 2 * canvas, 2 * canvas)])
        c += step
        k += 1
    return bands


def page_box(canvas, page_h):
    """Centred page of height page_h (aspect 0.77) on a square canvas."""
    w = page_h * 0.77
    return (canvas - w) / 2, (canvas - page_h) / 2, w, page_h


# ---- vector outputs ------------------------------------------------------------------------------------------------
def rrect_path(x, y, w, h, r):
    f = lambda v: f'{v:.3f}'.rstrip('0').rstrip('.')
    return (f'M{f(x + r)},{f(y)} h{f(w - 2 * r)} a{f(r)},{f(r)} 0 0 1 {f(r)},{f(r)} v{f(h - 2 * r)} '
            f'a{f(r)},{f(r)} 0 0 1 {f(-r)},{f(r)} h{f(-(w - 2 * r))} a{f(r)},{f(r)} 0 0 1 {f(-r)},{f(-r)} '
            f'v{f(-(h - 2 * r))} a{f(r)},{f(r)} 0 0 1 {f(r)},{f(-r)} z')


def write_svg(path):
    # 108-unit canvas like Android's adaptive icon; the page fits the 66-unit safe circle
    shapes = layout(*page_box(108, 52))
    body = '\n'.join(f'  <path fill="{c}" d="{rrect_path(x, y, w, h, r)}"/>' for x, y, w, h, r, c in shapes)
    path.write_text(f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 108 108" width="432" height="432">\n'
                    f'  <rect width="108" height="108" fill="{STRIPES[0]}"/>\n{svg_bands()}\n{body}\n</svg>\n',
                    encoding='utf-8')


def poly_path(points):
    f = lambda v: f'{v:.3f}'.rstrip('0').rstrip('.')
    return 'M' + ' L'.join(f'{f(x)},{f(y)}' for x, y in points) + ' Z'


def svg_bands():
    return '\n'.join(f'  <path fill="{STRIPES[1]}" d="{poly_path(b)}"/>' for b in dark_bands(108))


def write_vector_background(path):
    paths = '\n'.join(f'    <path android:fillColor="{STRIPES[1]}" android:pathData="{poly_path(b)}"/>'
                      for b in dark_bands(108))
    path.write_text('<?xml version="1.0" encoding="utf-8"?>\n'
                    '<!-- generated by tools/make_icon.py (the experiment\'s stripes) -->\n'
                    '<vector xmlns:android="http://schemas.android.com/apk/res/android"\n'
                    '    android:width="108dp" android:height="108dp" android:viewportWidth="108" android:viewportHeight="108">\n'
                    f'    <path android:fillColor="{STRIPES[0]}" android:pathData="M0,0 H108 V108 H0 Z"/>\n'
                    f'{paths}\n</vector>\n', encoding='utf-8')


def write_vector_foreground(path):
    shapes = layout(*page_box(108, 52))
    paths = '\n'.join(f'    <path android:fillColor="{c}" android:pathData="{rrect_path(x, y, w, h, r)}"/>'
                      for x, y, w, h, r, c in shapes)
    path.write_text('<?xml version="1.0" encoding="utf-8"?>\n'
                    '<!-- generated by tools/make_icon.py -->\n'
                    '<vector xmlns:android="http://schemas.android.com/apk/res/android"\n'
                    '    android:width="108dp" android:height="108dp" android:viewportWidth="108" android:viewportHeight="108">\n'
                    f'{paths}\n</vector>\n', encoding='utf-8')


# ---- raster outputs (same geometry, drawn 8x and scaled down) --------------------------------------------------------
def raster(size, page_h_frac, corner_frac=0.0, bg=BACKGROUND):
    s = 8
    big = size * s
    im = Image.new('RGBA', (big, big), (0, 0, 0, 0))
    d = ImageDraw.Draw(im)
    if bg:
        # the stripes, cut to the icon's (rounded) square
        striped = Image.new('RGBA', (big, big), STRIPES[0])
        sd = ImageDraw.Draw(striped)
        for b in dark_bands(big):
            sd.polygon(b, fill=STRIPES[1])
        mask = Image.new('L', (big, big), 0)
        ImageDraw.Draw(mask).rounded_rectangle([0, 0, big - 1, big - 1], radius=round(big * corner_frac), fill=255)
        im.paste(striped, (0, 0), mask)
    for x, y, w, h, r, c in layout(*page_box(big, big * page_h_frac)):
        d.rounded_rectangle([x, y, x + w, y + h], radius=r, fill=c)
    return im.resize((size, size), Image.LANCZOS)


DENSITIES = {'mdpi': 1, 'hdpi': 1.5, 'xhdpi': 2, 'xxhdpi': 3, 'xxxhdpi': 4}


def main():
    written = []
    for name, k in DENSITIES.items():
        f = RES / f'mipmap-{name}' / 'ic_launcher.png'
        raster(round(48 * k), 0.78, corner_frac=0.2).save(f)
        written.append(f)
        old_fg = RES / f'mipmap-{name}' / 'ic_launcher_foreground.png'  # from the first attempt, replaced by the vector
        if old_fg.exists():
            old_fg.unlink()

    fg = RES / 'drawable' / 'ic_launcher_foreground.xml'
    write_vector_foreground(fg)
    (RES / 'mipmap-anydpi-v26').mkdir(exist_ok=True)
    adaptive = RES / 'mipmap-anydpi-v26' / 'ic_launcher.xml'
    bg = RES / 'drawable' / 'ic_launcher_background.xml'
    write_vector_background(bg)
    written.append(bg)
    adaptive.write_text('<?xml version="1.0" encoding="utf-8"?>\n'
                        '<adaptive-icon xmlns:android="http://schemas.android.com/apk/res/android">\n'
                        '    <background android:drawable="@drawable/ic_launcher_background"/>\n'
                        '    <foreground android:drawable="@drawable/ic_launcher_foreground"/>\n'
                        '</adaptive-icon>\n', encoding='utf-8')
    colour = RES / 'values' / 'ic_launcher_background.xml'
    colour.write_text('<?xml version="1.0" encoding="utf-8"?>\n<resources>\n'
                      f'    <color name="ic_launcher_background">#FF{BACKGROUND[1:]}</color>\n</resources>\n',
                      encoding='utf-8')
    written += [fg, adaptive, colour]

    # Windows app icon (taskbar, title bar, Explorer): one .ico holding the sizes Windows asks for
    ico = APP / 'windows' / 'runner' / 'resources' / 'app_icon.ico'
    big = raster(256, 0.78, corner_frac=0.2)
    big.save(ico, format='ICO', sizes=[(16, 16), (24, 24), (32, 32), (48, 48), (64, 64), (128, 128), (256, 256)])
    written.append(ico)

    # in-app copy (Info screen)
    (APP / 'assets').mkdir(exist_ok=True)
    raster(256, 0.78, corner_frac=0.2).save(APP / 'assets' / 'icon.png')
    written.append(APP / 'assets' / 'icon.png')

    # iOS: every size the icon set lists, square and opaque (iOS rounds the corners itself)
    ios = APP / 'ios' / 'Runner' / 'Assets.xcassets' / 'AppIcon.appiconset'
    for f in sorted(ios.glob('Icon-App-*.png')):
        pt, scale = f.stem[len('Icon-App-'):].split('@')  # "83.5x83.5", "2x"
        px = round(float(pt.split('x')[0]) * int(scale[:-1]))
        raster(px, 0.78).convert('RGB').save(f)
        written.append(f)

    svg = ROOT / 'tools' / 'icon.svg'
    write_svg(svg)
    written.append(svg)

    # preview: round mask, squircle mask, legacy square - big and home-screen size - on a mid-grey wallpaper
    sheet = Image.new('RGBA', (1000, 430), (72, 80, 92, 255))
    d = ImageDraw.Draw(sheet)
    adaptive_full = raster(432, 52 / 108)  # background + foreground on the 108dp canvas
    x = 30
    for label in ('round', 'squircle', 'legacy'):
        for size, y in ((240, 30), (96, 300)):
            if label == 'legacy':
                tile = raster(size, 0.78, corner_frac=0.2)
            else:
                crop = adaptive_full.crop((72, 72, 360, 360)).resize((size, size), Image.LANCZOS)  # visible 72dp
                mask = Image.new('L', (size, size), 0)
                md = ImageDraw.Draw(mask)
                (md.ellipse if label == 'round' else
                 lambda b, fill: md.rounded_rectangle(b, radius=round(size * 0.3), fill=fill))([0, 0, size - 1, size - 1], fill=255)
                tile = Image.new('RGBA', (size, size), (0, 0, 0, 0))
                tile.paste(crop, (0, 0), mask)
            sheet.alpha_composite(tile, (x + (240 - size) // 2, y))
        d.text((x + 100, 408), label, fill='white')
        x += 320
    preview = ROOT / 'tools' / 'icon_preview.png'
    sheet.save(preview)
    for f in written:
        print('wrote', f.relative_to(ROOT))
    print('preview', preview.relative_to(ROOT))


if __name__ == '__main__':
    main()
