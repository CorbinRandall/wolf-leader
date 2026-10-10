"""Draw the drag-to-Applications DMG background at 1x (600x380) and 2x (1200x760).

Icons sit at x=150 (app) and x=450 (Applications), y=190 in 1x points; build-app.sh positions
them to match. Colors are the app's Parakeet palette.

    python installer/assets/make_dmg_background.py
"""

from pathlib import Path

from PIL import Image, ImageDraw, ImageFilter, ImageFont

HERE = Path(__file__).resolve().parent
W, H = 600, 380
BG = (0x1C, 0x1C, 0x1F)
GLOW = (0x2B, 0x2B, 0x2E)
ACCENT = (0xFF, 0x8A, 0x5C)
TEXT = (0xA1, 0xA1, 0xA6)
FONTS = [
    "C:/Windows/Fonts/segoeuisl.ttf",
    "C:/Windows/Fonts/segoeui.ttf",
    "/System/Library/Fonts/SFNS.ttf",
    "/System/Library/Fonts/Helvetica.ttc",
]


def font(size: int) -> ImageFont.ImageFont:
    for path in FONTS:
        if Path(path).exists():
            return ImageFont.truetype(path, size)
    return ImageFont.load_default()


def draw(scale: int) -> Image.Image:
    w, h = W * scale, H * scale
    img = Image.new("RGB", (w, h), BG)

    glow = Image.new("L", (w, h), 0)
    ImageDraw.Draw(glow).ellipse((w * 0.12, h * 0.05, w * 0.88, h * 0.95), fill=255)
    glow = glow.filter(ImageFilter.GaussianBlur(90 * scale))
    img = Image.composite(Image.new("RGB", (w, h), GLOW), img, glow)

    arrow = Image.new("RGBA", (w, h), (0, 0, 0, 0))
    d = ImageDraw.Draw(arrow)
    y = 190 * scale
    x0, x1 = 238 * scale, 352 * scale
    lw = max(2, round(2.5 * scale))
    color = ACCENT + (190,)
    d.line((x0, y, x1, y), fill=color, width=lw)
    head = 11 * scale
    d.line((x1 - head, y - head, x1, y), fill=color, width=lw)
    d.line((x1 - head, y + head, x1, y), fill=color, width=lw)
    img.paste(arrow, (0, 0), arrow)

    d = ImageDraw.Draw(img)
    label = "Drag Wolf Leader to Applications"
    f = font(15 * scale)
    tw = d.textlength(label, font=f)
    d.text(((w - tw) / 2, 318 * scale), label, font=f, fill=TEXT)
    return img


def main() -> None:
    for scale, name in ((1, "dmg-drag.png"), (2, "dmg-drag@2x.png")):
        out = HERE / name
        draw(scale).save(out, dpi=(72 * scale, 72 * scale))
        print(out)


if __name__ == "__main__":
    main()
