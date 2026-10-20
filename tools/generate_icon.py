"""Generate the MatriXpress launcher icon; requires Pillow."""

from pathlib import Path
from PIL import Image, ImageDraw, ImageFilter

ROOT = Path(__file__).resolve().parents[1]
SIZE = 1024
image = Image.new("RGB", (SIZE, SIZE), (11, 9, 28))
pixels = image.load()
assert pixels is not None
for y in range(SIZE):
    for x in range(SIZE):
        t = (x + y) / (2 * SIZE)
        pixels[x, y] = (int(15 + t * 22), int(13 + t * 12), int(37 + t * 43))

haze = Image.new("RGBA", (SIZE, SIZE))
glow = ImageDraw.Draw(haze)
glow.ellipse((310, -180, 1150, 670), fill=(163, 103, 255, 92))
glow.ellipse((-320, 520, 570, 1370), fill=(103, 245, 214, 66))
image = Image.alpha_composite(image.convert("RGBA"), haze.filter(ImageFilter.GaussianBlur(135)))

stroke = Image.new("RGBA", (SIZE, SIZE))
draw = ImageDraw.Draw(stroke)
draw.rounded_rectangle((94, 94, 930, 930), radius=236,
                       outline=(207, 184, 255, 110), width=18)
draw.line((290, 267, 735, 757), fill=(120, 249, 220), width=118, joint="curve")
draw.line((730, 267, 287, 757), fill=(191, 147, 255), width=118, joint="curve")
for center, color in [((290, 267), (120, 249, 220)), ((735, 757), (120, 249, 220)),
                      ((730, 267), (191, 147, 255)), ((287, 757), (191, 147, 255))]:
    draw.ellipse((center[0] - 59, center[1] - 59, center[0] + 59, center[1] + 59),
                 fill=color)
image = Image.alpha_composite(image, stroke.filter(ImageFilter.GaussianBlur(18)))
image = Image.alpha_composite(image, stroke)

draw = ImageDraw.Draw(image)
draw.ellipse((451, 451, 573, 573), fill=(241, 232, 255))

assets = ROOT / "assets"
image.convert("RGB").save(assets / "matrixpress_icon.png", optimize=True)
for density, size in {"mdpi": 48, "hdpi": 72, "xhdpi": 96,
                      "xxhdpi": 144, "xxxhdpi": 192}.items():
    target = ROOT / "android/app/src/main/res" / f"mipmap-{density}" / "ic_launcher.png"
    image.resize((size, size), Image.Resampling.LANCZOS).convert("RGB").save(target, optimize=True)
    print(target)
