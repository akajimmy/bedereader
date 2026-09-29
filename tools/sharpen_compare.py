"""Compare page sharpening / scaling methods as the tablet would show them.

    python tools\\sharpen_compare.py <page image> [--screen 1200x1920] [--crops x0,y0,x1,y1 ...] [--name NAME]

Renders the page fit-to-screen (the reader's default) on a screen of the given physical size with each method,
and writes into testpages\\compare\\:
  <name> - <method>.png        the full rendered screen, for flipping between methods at 100%
  <name> - crops.png           each crop region (source-pixel box) side by side per method, magnified 2x
and prints two numbers per method, relative to "now, sharpen off":
  edges  - mean gradient on the strongest 5% of edges (higher = crisper lines and lettering)
  noise  - mean |laplacian| where the page is flat (higher = more JPEG speckle / grain / halftone amplified)

Methods (all numpy, mirroring what a GPU shader would do - no ML):
  off         - now, Sharpen off: smooth filtered scaling (Flutter FilterQuality.medium, ~antialiased bilinear)
  on-now      - now, Sharpen on: the shipped shader - NEAREST sampling (setImageSampler defaults to
                FilterQuality.none) + 4-neighbour unsharp 0.36 in source pixels
  on-linear   - the same unsharp, but sampled with linear filtering (the one-line fix)
  cas         - AMD FidelityFX CAS (contrast-adaptive sharpening) at source resolution, then smooth scaling
  lanczos+cas - Lanczos-3 scaling to the screen, then CAS at screen resolution (FSR-1-like: upscale, then RCAS)
"""
import argparse
import pathlib

import numpy as np
from PIL import Image, ImageDraw, ImageFont

OUT = pathlib.Path(__file__).resolve().parent.parent / 'testpages' / 'compare'


# ---- scaling ---------------------------------------------------------------------------------------------------------
def sample(src, out_w, out_h, mode):
    """GPU-style sampling of src (HxWx3 float 0..1) at the centres of an out_w x out_h grid: 'nearest' or 'linear'
    (no mipmaps, like a shader sampler)."""
    h, w, _ = src.shape
    x = (np.arange(out_w) + 0.5) * w / out_w - 0.5
    y = (np.arange(out_h) + 0.5) * h / out_h - 0.5
    if mode == 'nearest':
        xi = np.clip(np.floor(x + 0.5).astype(int), 0, w - 1)
        yi = np.clip(np.floor(y + 0.5).astype(int), 0, h - 1)
        return src[yi][:, xi]
    x0 = np.clip(np.floor(x).astype(int), 0, w - 1)
    y0 = np.clip(np.floor(y).astype(int), 0, h - 1)
    x1 = np.clip(x0 + 1, 0, w - 1)
    y1 = np.clip(y0 + 1, 0, h - 1)
    fx = np.clip(x - x0, 0, 1)[None, :, None]
    fy = np.clip(y - y0, 0, 1)[:, None, None]
    top = src[y0][:, x0] * (1 - fx) + src[y0][:, x1] * fx
    bot = src[y1][:, x0] * (1 - fx) + src[y1][:, x1] * fx
    return top * (1 - fy) + bot * fy


def pil_resize(src, out_w, out_h, resample):
    im = Image.fromarray((np.clip(src, 0, 1) * 255 + 0.5).astype(np.uint8))
    return np.asarray(im.resize((out_w, out_h), resample), dtype=np.float32) / 255


# ---- sharpening ------------------------------------------------------------------------------------------------------
def shifted(a, dx, dy):
    """a shifted by (dx, dy) with edge pixels repeated."""
    p = np.pad(a, ((1, 1), (1, 1), (0, 0)), mode='edge')
    h, w = a.shape[:2]
    return p[1 + dy:1 + dy + h, 1 + dx:1 + dx + w]


def unsharp4(src, amount):
    """The shipped shader's filter: c + amount * (4c - left - right - up - down)."""
    n = shifted(src, 1, 0) + shifted(src, -1, 0) + shifted(src, 0, 1) + shifted(src, 0, -1)
    return src + amount * (4 * src - n)


def cas(src, sharpness):
    """AMD FidelityFX Contrast Adaptive Sharpening (the non-scaling path), per channel. sharpness 0..1.
    Sharpens less where the local contrast is already high or the pixel is near black/white, so it lifts soft
    edges without ringing on strong ones or boosting flat-area noise as much as a plain unsharp mask."""
    b, d, e, f, h = (shifted(src, 0, -1), shifted(src, -1, 0), src, shifted(src, 1, 0), shifted(src, 0, 1))
    a, c, g, i = (shifted(src, -1, -1), shifted(src, 1, -1), shifted(src, -1, 1), shifted(src, 1, 1))
    mn = np.minimum.reduce([b, d, e, f, h])
    mn = mn + np.minimum(mn, np.minimum.reduce([a, c, g, i]))
    mx = np.maximum.reduce([b, d, e, f, h])
    mx = mx + np.maximum(mx, np.maximum.reduce([a, c, g, i]))
    amp = np.sqrt(np.clip(np.minimum(mn, 2 - mx) / np.maximum(mx, 1e-5), 0, 1))
    peak = -1.0 / (8.0 + (5.0 - 8.0) * sharpness)  # lerp(8, 5, sharpness)
    w = amp * peak
    return (w * (b + d + f + h) + e) / (1 + 4 * w)


# ---- methods ---------------------------------------------------------------------------------------------------------
def render(src, method, out_w, out_h):
    if method == 'off':
        return pil_resize(src, out_w, out_h, Image.BILINEAR)
    if method == 'on-now':
        return np.clip(sample(unsharp4(src, 0.36), out_w, out_h, 'nearest'), 0, 1)
    if method == 'on-linear':
        return np.clip(sample(unsharp4(src, 0.36), out_w, out_h, 'linear'), 0, 1)
    if method == 'cas':
        return np.clip(pil_resize(cas(src, 0.6), out_w, out_h, Image.BILINEAR), 0, 1)
    if method == 'lanczos+cas':
        return np.clip(cas(pil_resize(src, out_w, out_h, Image.LANCZOS), 0.5), 0, 1)
    raise ValueError(method)


METHODS = ['off', 'on-now', 'on-linear', 'cas', 'lanczos+cas']


# ---- measures --------------------------------------------------------------------------------------------------------
def luma(a):
    return a[..., 0] * 0.299 + a[..., 1] * 0.587 + a[..., 2] * 0.114


def measures(img, ref):
    """(edge strength, flat-area noise) of img, with edges and flat areas chosen on the reference render."""
    y, r = luma(img), luma(ref)
    gy, gx = np.gradient(y)
    g = np.hypot(gx, gy)
    rgy, rgx = np.gradient(r)
    rg = np.hypot(rgx, rgy)
    edges = rg >= np.quantile(rg, 0.95)
    lap = np.abs(4 * y - np.roll(y, 1, 0) - np.roll(y, -1, 0) - np.roll(y, 1, 1) - np.roll(y, -1, 1))
    # flat = low gradient on the reference, in a 5x5 neighbourhood
    k = np.ones(5) / 5
    smooth = np.apply_along_axis(lambda m: np.convolve(m, k, 'same'), 0, rg)
    smooth = np.apply_along_axis(lambda m: np.convolve(m, k, 'same'), 1, smooth)
    flat = smooth <= np.quantile(smooth, 0.4)
    return g[edges].mean(), lap[flat].mean()


# ---- output ----------------------------------------------------------------------------------------------------------
def to_image(a):
    return Image.fromarray((np.clip(a, 0, 1) * 255 + 0.5).astype(np.uint8))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('page')
    ap.add_argument('--screen', default='1200x1920')
    ap.add_argument('--crops', nargs='*', default=[])
    ap.add_argument('--name')
    args = ap.parse_args()

    page = pathlib.Path(args.page)
    name = args.name or page.stem
    src = np.asarray(Image.open(page).convert('RGB'), dtype=np.float32) / 255
    h, w, _ = src.shape
    sw, sh = (int(v) for v in args.screen.split('x'))
    scale = min(sw / w, sh / h)  # fit screen
    out_w, out_h = round(w * scale), round(h * scale)
    print(f'{name}: {w}x{h} on a {sw}x{sh} screen -> {out_w}x{out_h} (x{scale:.2f})')

    OUT.mkdir(parents=True, exist_ok=True)
    renders = {m: render(src, m, out_w, out_h) for m in METHODS}
    ref = renders['off']
    e0, n0 = measures(ref, ref)
    print(f'  {"method":12} {"edges":>6} {"noise":>6}   (relative to off)')
    for m, r in renders.items():
        e, n = measures(r, ref)
        print(f'  {m:12} {e / e0:6.2f} {n / n0:6.2f}')
        to_image(r).save(OUT / f'{name} - {m}.png')

    # crops: source-pixel boxes -> screen pixels, magnified 2x (nearest) so the difference is visible
    crops = [tuple(int(v) for v in c.split(',')) for c in args.crops]
    if crops:
        mag = 2
        font = ImageFont.load_default(size=20)
        tiles = []
        for (x0, y0, x1, y1) in crops:
            row = []
            for m in METHODS:
                box = tuple(round(v * scale) for v in (x0, y0, x1, y1))
                tile = to_image(renders[m]).crop(box)
                row.append(tile.resize((tile.width * mag, tile.height * mag), Image.NEAREST))
            tiles.append(row)
        label_h, gap = 30, 8
        col_w = [max(r[i].width for r in tiles) for i in range(len(METHODS))]
        row_h = [max(t.height for t in r) for r in tiles]
        sheet = Image.new('RGB', (sum(col_w) + gap * (len(METHODS) + 1), label_h + sum(row_h) + gap * (len(tiles) + 1)),
                          (40, 40, 44))
        d = ImageDraw.Draw(sheet)
        x = gap
        for i, m in enumerate(METHODS):
            d.text((x, 4), m, fill=(230, 230, 230), font=font)
            x += col_w[i] + gap
        y = label_h + gap
        for r_i, r in enumerate(tiles):
            x = gap
            for i, t in enumerate(r):
                sheet.paste(t, (x, y))
                x += col_w[i] + gap
            y += row_h[r_i] + gap
        sheet.save(OUT / f'{name} - crops.png')
        print(f'  crops -> {OUT / (name + " - crops.png")}')


if __name__ == '__main__':
    main()
