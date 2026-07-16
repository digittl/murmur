#!/usr/bin/env python3
"""Generate assets/AppIcon.icns for Murmur.

A macOS-style rounded squircle with a diagonal indigo->violet gradient and a row
of ascending, rounded audio bars — reading as both a voice waveform and the
diary's forward march of days. Rendered at 4x then downsampled for clean edges.
"""

import os
import subprocess
from PIL import Image, ImageDraw

HERE = os.path.dirname(os.path.abspath(__file__))
SS = 4                      # supersample factor
S = 1024 * SS              # working canvas
RADIUS = int(0.2237 * S)   # Apple corner ratio


def lerp(a, b, t):
    return tuple(round(a[i] + (b[i] - a[i]) * t) for i in range(3))


def make_gradient(size, top, bot):
    """Diagonal top-left -> bottom-right gradient, built small and upscaled (fast, smooth)."""
    try:
        import numpy as np
        n = 256
        yy, xx = np.mgrid[0:n, 0:n]
        t = (xx + yy) / (2 * (n - 1))
        arr = np.zeros((n, n, 3), dtype=np.uint8)
        for i in range(3):
            arr[..., i] = (top[i] + (bot[i] - top[i]) * t).astype(np.uint8)
        return Image.fromarray(arr, "RGB").resize((size, size), Image.BILINEAR)
    except ImportError:
        small = Image.new("RGB", (256, 256))
        px = small.load()
        for y in range(256):
            for x in range(256):
                px[x, y] = lerp(top, bot, (x + y) / 510)
        return small.resize((size, size), Image.BILINEAR)


def make_master():
    top = (91, 110, 245)     # indigo  #5B6EF5
    bot = (155, 93, 229)     # violet  #9B5DE5

    grad = make_gradient(S, top, bot)

    # Rounded-square alpha mask.
    mask = Image.new("L", (S, S), 0)
    ImageDraw.Draw(mask).rounded_rectangle([0, 0, S - 1, S - 1], radius=RADIUS, fill=255)

    icon = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    icon.paste(grad, (0, 0), mask)

    # Ascending bars.
    draw = ImageDraw.Draw(icon)
    n = 6
    margin_x = int(S * 0.20)
    usable_w = S - 2 * margin_x
    gap = int(usable_w * 0.045)
    bar_w = (usable_w - gap * (n - 1)) // n
    baseline = int(S * 0.72)          # bottoms align here
    h_min = int(S * 0.16)
    h_max = int(S * 0.44)
    bar_r = bar_w // 2

    # Soft shadow layer.
    shadow = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    sdraw = ImageDraw.Draw(shadow)

    for i in range(n):
        h = round(h_min + (h_max - h_min) * (i / (n - 1)))
        x0 = margin_x + i * (bar_w + gap)
        x1 = x0 + bar_w
        y0 = baseline - h
        y1 = baseline
        sdraw.rounded_rectangle([x0, y0 + int(S * 0.012), x1, y1 + int(S * 0.012)],
                                radius=bar_r, fill=(40, 20, 80, 90))

    from PIL import ImageFilter
    shadow = shadow.filter(ImageFilter.GaussianBlur(int(S * 0.010)))
    icon = Image.alpha_composite(icon, shadow)
    draw = ImageDraw.Draw(icon)

    for i in range(n):
        h = round(h_min + (h_max - h_min) * (i / (n - 1)))
        x0 = margin_x + i * (bar_w + gap)
        x1 = x0 + bar_w
        y0 = baseline - h
        y1 = baseline
        alpha = round(210 + 45 * (i / (n - 1)))  # brighter as they rise
        draw.rounded_rectangle([x0, y0, x1, y1], radius=bar_r, fill=(255, 255, 255, alpha))

    return icon.resize((1024, 1024), Image.LANCZOS)


def main():
    master = make_master()
    iconset = os.path.join(HERE, "AppIcon.iconset")
    os.makedirs(iconset, exist_ok=True)

    sizes = [16, 32, 128, 256, 512]
    for s in sizes:
        master.resize((s, s), Image.LANCZOS).save(os.path.join(iconset, f"icon_{s}x{s}.png"))
        master.resize((s * 2, s * 2), Image.LANCZOS).save(os.path.join(iconset, f"icon_{s}x{s}@2x.png"))
    master.save(os.path.join(iconset, "icon_512x512@2x.png"))  # 1024

    out = os.path.join(HERE, "AppIcon.icns")
    subprocess.run(["iconutil", "-c", "icns", iconset, "-o", out], check=True)
    print("wrote", out)


if __name__ == "__main__":
    main()
