#!/usr/bin/env python3
"""Generate Murmur's app icon: a blue squircle with a centered voice waveform."""
from PIL import Image, ImageDraw, ImageFilter

SS = 2048          # supersample canvas
OUT = 1024         # final master size
MARGIN = 0.075     # transparent margin fraction around the squircle
CORNER = 0.2237    # Apple-ish squircle corner radius (fraction of squircle side)

# Diagonal blue gradient (top-left -> bottom-right).
C0 = (94, 168, 255)   # bright sky blue
C1 = (58, 70, 216)    # deep indigo-blue


def lerp(a, b, t):
    return tuple(round(a[i] + (b[i] - a[i]) * t) for i in range(3))


def diagonal_gradient(size):
    """Per-pixel diagonal gradient built small, upscaled smoothly by the caller."""
    g = Image.new("RGB", (size, size))
    px = g.load()
    denom = 2 * (size - 1)
    for y in range(size):
        for x in range(size):
            px[x, y] = lerp(C0, C1, (x + y) / denom)
    return g


def squircle_mask(size, box):
    m = Image.new("L", (size, size), 0)
    d = ImageDraw.Draw(m)
    side = box[2] - box[0]
    d.rounded_rectangle(box, radius=CORNER * side, fill=255)
    return m


def waveform(size, box):
    """A centered, symmetric voice waveform in white, with a soft shadow."""
    heights = [0.30, 0.44, 0.60, 0.74, 0.88, 0.97, 1.00,
               0.97, 0.88, 0.74, 0.60, 0.44, 0.30]
    n = len(heights)
    bar_w = 0.028 * size
    gap = 0.70 * bar_w
    content_w = n * bar_w + (n - 1) * gap
    cx, cy = size / 2, size / 2
    max_h = 0.46 * size
    x0 = cx - content_w / 2

    bars = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    bd = ImageDraw.Draw(bars)
    for i, hf in enumerate(heights):
        h = max(hf * max_h, bar_w)
        left = x0 + i * (bar_w + gap)
        top = cy - h / 2
        bd.rounded_rectangle([left, top, left + bar_w, top + h],
                             radius=bar_w / 2, fill=(255, 255, 255, 255))

    # Soft drop shadow beneath the bars for depth.
    shadow = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    sd = ImageDraw.Draw(shadow)
    off = 0.010 * size
    for i, hf in enumerate(heights):
        h = max(hf * max_h, bar_w)
        left = x0 + i * (bar_w + gap)
        top = cy - h / 2
        sd.rounded_rectangle([left, top + off, left + bar_w, top + h + off],
                             radius=bar_w / 2, fill=(14, 24, 70, 120))
    shadow = shadow.filter(ImageFilter.GaussianBlur(0.012 * size))

    out = Image.alpha_composite(shadow, bars)
    return out


def build():
    box = (round(SS * MARGIN), round(SS * MARGIN),
           round(SS * (1 - MARGIN)), round(SS * (1 - MARGIN)))

    grad = diagonal_gradient(512).resize((SS, SS), Image.LANCZOS).convert("RGBA")
    mask = squircle_mask(SS, box)

    icon = Image.new("RGBA", (SS, SS), (0, 0, 0, 0))
    icon.paste(grad, (0, 0), mask)

    # Subtle top sheen for a little gloss.
    sheen = Image.new("RGBA", (SS, SS), (0, 0, 0, 0))
    shd = ImageDraw.Draw(sheen)
    side = box[2] - box[0]
    shd.rounded_rectangle([box[0], box[1], box[2], box[1] + side * 0.5],
                          radius=CORNER * side, fill=(255, 255, 255, 26))
    icon = Image.alpha_composite(icon, Image.composite(
        sheen, Image.new("RGBA", (SS, SS), (0, 0, 0, 0)), mask))

    icon = Image.alpha_composite(icon, waveform(SS, box))
    # Clip everything to the squircle.
    icon.putalpha(Image.composite(icon.getchannel("A"),
                                  Image.new("L", (SS, SS), 0), mask))

    icon = icon.resize((OUT, OUT), Image.LANCZOS)
    icon.save("/private/tmp/claude-501/-Users-aariacarterweir-Projects-batch-whisper/57dd3aea-deda-48d8-b32d-89cd4cb1aaa1/scratchpad/icon_master.png")
    print("wrote icon_master.png")


build()
