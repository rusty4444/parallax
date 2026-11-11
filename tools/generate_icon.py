"""Generate the Parallax launcher icons and brand artwork; requires Pillow.

The mark is three offset message bubbles (crimson, vermilion, amber). Each layer is
separated by a thin background-coloured gap so the stack reads as depth — a
parallax shift — even at launcher sizes. Keep the geometry in sync with
`ParallaxMarkPainter` in lib/widgets.dart.
"""

from pathlib import Path

from PIL import Image, ImageChops, ImageDraw, ImageFilter

ROOT = Path(__file__).resolve().parents[1]
SCALE = 4  # supersampling factor for antialiasing
SIZE = 1024

BACKGROUND_TOP = (46, 12, 12)
BACKGROUND_BOTTOM = (16, 6, 8)
GAP = (20, 7, 9)

# (offset in mark units, gradient start, gradient end) back → front.
LAYERS = [
    ((-0.14, 0.14), (112, 8, 30), (170, 20, 48)),
    ((0.0, 0.0), (228, 44, 34), (255, 78, 46)),
    ((0.14, -0.14), (255, 132, 40), (255, 200, 76)),
]
# The tails add weight below the stack; lift the mark to centre it optically.
LIFT = 0.045


def bubble_mask(size: int, cx: float, cy: float, unit: float, grow: float = 0) -> Image.Image:
    """Rounded speech bubble centred on (cx, cy); `unit` is the mark width.

    `grow` dilates the silhouette geometrically (used to cut the layer gaps).
    """
    mask = Image.new("L", (size, size), 0)
    draw = ImageDraw.Draw(mask)
    w, h = unit * 0.62, unit * 0.48
    r = unit * 0.17
    left, top = cx - w / 2, cy - h / 2
    stroke = int(round(grow * 2))
    draw.rounded_rectangle(
        (left - grow, top - grow, left + w + grow, top + h + grow),
        radius=r + grow,
        fill=255,
    )
    # Tail: a short, broad wedge off the lower-right edge with a blunt tip, so
    # every layer's tail stays clear of the bubble in front of it.
    tail = [
        (left + w * 0.56, top + h * 0.80),
        (left + w * 0.82, top + h * 0.80),
        (left + w * 0.90, top + h * 1.17),
        (left + w * 0.85, top + h * 1.19),
    ]
    draw.polygon(tail, fill=255, outline=255 if stroke else None, width=max(stroke, 1))
    return mask


def gradient(size: int, start, end) -> Image.Image:
    """Diagonal top-left → bottom-right gradient."""
    small = Image.new("RGB", (256, 256))
    px = small.load()
    assert px is not None
    for y in range(256):
        for x in range(256):
            t = (x + y) / 510
            px[x, y] = tuple(int(s + (e - s) * t) for s, e in zip(start, end))
    return small.resize((size, size), Image.Resampling.BICUBIC)


def draw_mark(size: int, unit: float, centre: tuple[float, float], gap_px: float) -> Image.Image:
    """Return an RGBA image containing only the layered mark."""
    out = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    occupied = Image.new("L", (size, size), 0)
    for (dx, dy), start, end in LAYERS:
        cx, cy = centre[0] + dx * unit, centre[1] + (dy - LIFT) * unit
        mask = bubble_mask(size, cx, cy, unit)
        # Cut a gap around the newer (front) layer from everything behind it.
        halo = bubble_mask(size, cx, cy, unit, grow=gap_px)
        out.putalpha(ImageChops.subtract(out.getchannel("A"), halo))
        occupied = ImageChops.subtract(occupied, halo)
        layer = gradient(size, start, end).convert("RGBA")
        layer.putalpha(mask)
        out = Image.alpha_composite(out, layer)
        occupied = ImageChops.lighter(occupied, mask)
    return out


def background(size: int) -> Image.Image:
    small = Image.new("RGB", (256, 256))
    px = small.load()
    assert px is not None
    for y in range(256):
        for x in range(256):
            t = y / 255
            px[x, y] = tuple(int(a + (b - a) * t) for a, b in zip(BACKGROUND_TOP, BACKGROUND_BOTTOM))
    img = small.resize((size, size), Image.Resampling.BICUBIC).convert("RGBA")
    glow = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    gd = ImageDraw.Draw(glow)
    gd.ellipse((size * 0.30, -size * 0.25, size * 1.15, size * 0.62), fill=(255, 92, 48, 70))
    gd.ellipse((-size * 0.30, size * 0.55, size * 0.55, size * 1.30), fill=(214, 38, 61, 60))
    glow = glow.filter(ImageFilter.GaussianBlur(size * 0.13))
    return Image.alpha_composite(img, glow)


def shadowed(mark: Image.Image, size: int) -> Image.Image:
    shadow = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    alpha = mark.getchannel("A").filter(ImageFilter.GaussianBlur(size * 0.02))
    shadow.putalpha(alpha.point(lambda a: int(a * 0.55)))
    offset = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    offset.paste(shadow, (0, int(size * 0.012)))
    return offset


def full_icon(px: int) -> Image.Image:
    big = px * SCALE
    img = background(big)
    mark = draw_mark(big, big * 0.62, (big * 0.5, big * 0.5), big * 0.016)
    img = Image.alpha_composite(img, shadowed(mark, big))
    img = Image.alpha_composite(img, mark)
    return img.resize((px, px), Image.Resampling.LANCZOS)


def adaptive_foreground(px: int) -> Image.Image:
    # 108dp canvas, 66dp safe zone: keep the mark within ~58% of the canvas.
    big = px * SCALE
    mark = draw_mark(big, big * 0.46, (big * 0.5, big * 0.5), big * 0.012)
    canvas = Image.new("RGBA", (big, big), (0, 0, 0, 0))
    canvas = Image.alpha_composite(canvas, shadowed(mark, big))
    canvas = Image.alpha_composite(canvas, mark)
    return canvas.resize((px, px), Image.Resampling.LANCZOS)


def monochrome(px: int) -> Image.Image:
    big = px * SCALE
    mark = draw_mark(big, big * 0.46, (big * 0.5, big * 0.5), big * 0.016)
    out = Image.new("RGBA", (big, big), (255, 255, 255, 0))
    out.putalpha(mark.getchannel("A"))
    return out.resize((px, px), Image.Resampling.LANCZOS)


def notification_icon(px: int) -> Image.Image:
    big = px * SCALE
    mark = draw_mark(big, big * 0.78, (big * 0.5, big * 0.5), big * 0.07)
    out = Image.new("RGBA", (big, big), (255, 255, 255, 0))
    out.putalpha(mark.getchannel("A"))
    return out.resize((px, px), Image.Resampling.LANCZOS)


def main() -> None:
    assets = ROOT / "assets"
    res = ROOT / "android/app/src/main/res"
    full_icon(SIZE).convert("RGB").save(assets / "parallax_icon.png", optimize=True)
    mark = draw_mark(SIZE * SCALE, SIZE * SCALE * 0.82, (SIZE * SCALE * 0.5, SIZE * SCALE * 0.5), SIZE * SCALE * 0.02)
    mark.resize((SIZE, SIZE), Image.Resampling.LANCZOS).save(assets / "parallax_mark.png", optimize=True)

    legacy = {"mdpi": 48, "hdpi": 72, "xhdpi": 96, "xxhdpi": 144, "xxxhdpi": 192}
    adaptive = {"mdpi": 108, "hdpi": 162, "xhdpi": 216, "xxhdpi": 324, "xxxhdpi": 432}
    status = {"mdpi": 24, "hdpi": 36, "xhdpi": 48, "xxhdpi": 72, "xxxhdpi": 96}
    for density, px in legacy.items():
        folder = res / f"mipmap-{density}"
        folder.mkdir(parents=True, exist_ok=True)
        icon = full_icon(px).convert("RGB")
        icon.save(folder / "ic_launcher.png", optimize=True)
        # Round variant: same artwork under a circular mask.
        mask = Image.new("L", (px * SCALE, px * SCALE), 0)
        ImageDraw.Draw(mask).ellipse((0, 0, px * SCALE - 1, px * SCALE - 1), fill=255)
        rounded = full_icon(px)
        rounded.putalpha(mask.resize((px, px), Image.Resampling.LANCZOS))
        rounded.save(folder / "ic_launcher_round.png", optimize=True)
    for density, px in adaptive.items():
        folder = res / f"mipmap-{density}"
        adaptive_foreground(px).save(folder / "ic_launcher_foreground.png", optimize=True)
        monochrome(px).save(folder / "ic_launcher_monochrome.png", optimize=True)
    for density, px in status.items():
        folder = res / f"drawable-{density}"
        folder.mkdir(parents=True, exist_ok=True)
        notification_icon(px).save(folder / "ic_stat_parallax.png", optimize=True)
    print("generated Parallax icons")


if __name__ == "__main__":
    main()
