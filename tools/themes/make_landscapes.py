#!/usr/bin/env python3
"""Draws the landscape theme pictures (flat, calm, dark enough for white labels).
   tools/themes/make_landscapes.py  ->  entry/src/main/resources/rawfile/themes/*.jpg"""
import math, os, random
from PIL import Image, ImageDraw, ImageFilter

W, H = 2200, 1000
OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', '..', 'entry', 'src', 'main', 'resources',
                   'rawfile', 'themes')


def vgrad(stops):
    """Vertical gradient from (pos, (r,g,b)) stops."""
    im = Image.new('RGB', (W, H))
    px = im.load()
    for y in range(H):
        t = y / (H - 1)
        for i in range(len(stops) - 1):
            p0, c0 = stops[i]
            p1, c1 = stops[i + 1]
            if p0 <= t <= p1:
                f = (t - p0) / (p1 - p0)
                c = tuple(int(c0[k] + (c1[k] - c0[k]) * f) for k in range(3))
                break
        for x in range(W):
            px[x, y] = c
    return im


def ridge(d, base, amp, freqs, color, seed, jag=0.0):
    rnd = random.Random(seed)
    phases = [rnd.random() * 6.28 for _ in freqs]
    pts = []
    for x in range(0, W + 10, 10):
        y = base
        for (f, a), ph in zip(freqs, phases):
            y -= a * amp * math.sin(x / W * f * 6.28 + ph)
        if jag:
            y += rnd.uniform(-jag, jag)
        pts.append((x, y))
    d.polygon(pts + [(W, H), (0, H)], fill=color)


def stars(d, n, ymax, seed):
    rnd = random.Random(seed)
    for _ in range(n):
        x, y = rnd.randrange(W), rnd.randrange(int(ymax))
        r = rnd.choice([1, 1, 1, 2])
        d.ellipse([x - r, y - r, x + r, y + r], fill=(255, 255, 255))


def mountains():
    im = vgrad([(0, (18, 24, 58)), (0.45, (74, 52, 110)), (0.62, (214, 120, 98)), (1, (240, 170, 110))])
    d = ImageDraw.Draw(im)
    stars(d, 120, H * 0.35, 1)
    ridge(d, H * 0.62, 90, [(2, 1), (5, .5), (11, .25)], (92, 66, 120), 2, 6)
    ridge(d, H * 0.72, 110, [(1.5, 1), (4, .6), (9, .3)], (58, 44, 92), 3, 8)
    ridge(d, H * 0.84, 90, [(1, 1), (3, .7), (7, .3)], (32, 28, 62), 4, 8)
    ridge(d, H * 0.95, 60, [(2, 1), (6, .5)], (18, 18, 40), 5, 4)
    return im


def lake():
    im = vgrad([(0, (8, 16, 36)), (0.55, (24, 46, 82)), (0.56, (18, 34, 60)), (1, (6, 12, 26))])
    d = ImageDraw.Draw(im)
    stars(d, 160, H * 0.4, 7)
    d.ellipse([1500, 110, 1640, 250], fill=(236, 232, 210))
    ridge(d, H * 0.56, 120, [(1.2, 1), (3.5, .5), (8, .25)], (20, 34, 56), 8, 5)
    # water below the mountains, with a faint mirror of the sky
    water = vgrad([(0, (22, 40, 70)), (1, (6, 12, 26))]).resize((W, H - int(H * 0.56)))
    im.paste(water, (0, int(H * 0.56)))
    d = ImageDraw.Draw(im)
    # moon reflection
    for i in range(14):
        y = int(H * 0.6 + i * 26)
        w = 70 - i * 3
        d.rounded_rectangle([1570 - w, y, 1570 + w, y + 6], radius=3, fill=(120, 130, 140))
    im = im.filter(ImageFilter.GaussianBlur(1))
    return im


def dunes():
    im = vgrad([(0, (64, 32, 46)), (0.35, (170, 78, 60)), (0.55, (236, 150, 82)), (1, (250, 196, 120))])
    d = ImageDraw.Draw(im)
    d.ellipse([980, 330, 1220, 570], fill=(255, 214, 140))
    ridge(d, H * 0.6, 70, [(1, 1), (2.5, .6)], (196, 104, 62), 11)
    ridge(d, H * 0.72, 80, [(0.8, 1), (2, .5)], (156, 76, 46), 12)
    ridge(d, H * 0.86, 70, [(1.1, 1), (2.7, .4)], (112, 52, 34), 13)
    ridge(d, H * 0.97, 40, [(1.5, 1)], (76, 36, 26), 14)
    return im


def forest():
    im = vgrad([(0, (40, 70, 66)), (0.5, (96, 130, 118)), (1, (30, 52, 46))])
    d = ImageDraw.Draw(im)
    rnd = random.Random(21)
    for layer, (base, color, size) in enumerate([(0.55, (70, 104, 94), 70), (0.7, (46, 76, 68), 95),
                                                 (0.86, (26, 48, 42), 125), (1.0, (14, 30, 26), 160)]):
        x = -40
        while x < W + 40:
            h = size * rnd.uniform(1.6, 2.6)
            y0 = H * base
            d.polygon([(x, y0), (x + size * 0.5, y0 - h), (x + size, y0)], fill=color)
            x += size * rnd.uniform(0.45, 0.8)
        d.rectangle([0, H * base - 2, W, H], fill=color)
        if layer < 2:
            im = im.filter(ImageFilter.GaussianBlur(2))
            d = ImageDraw.Draw(im)
    return im


def coast():
    im = vgrad([(0, (20, 60, 96)), (0.48, (120, 170, 196)), (0.5, (30, 104, 128)), (1, (10, 40, 60))])
    d = ImageDraw.Draw(im)
    d.ellipse([560, 330, 720, 490], fill=(255, 236, 196))
    for i in range(18):
        y = int(H * 0.53 + i * 24)
        d.line([(0, y), (W, y)], fill=(40 + i, 110 - i * 2, 136 - i * 3), width=2)
    pts = [(1400, H * 0.5), (1520, H * 0.42), (1640, H * 0.38), (1800, H * 0.34), (2000, H * 0.3), (W, H * 0.28),
           (W, H), (1300, H)]
    d.polygon(pts, fill=(18, 40, 52))
    d.polygon([(1250, H), (1420, H * 0.62), (1560, H * 0.58), (1700, H * 0.66), (1900, H)], fill=(12, 28, 38))
    return im


if __name__ == '__main__':
    os.makedirs(OUT, exist_ok=True)
    for name, fn in [('mountains', mountains), ('lake', lake), ('dunes', dunes), ('forest', forest), ('coast', coast)]:
        fn().save(os.path.join(OUT, name + '.jpg'), quality=86, optimize=True, progressive=True)
        print(name)
