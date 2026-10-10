"""Build every installer icon from app-icon-source.png (transparent background).

Usage:  python installer/assets/make_icons.py      (needs `pip install pillow`)
"""
from pathlib import Path

from PIL import Image

HERE = Path(__file__).resolve().parent
SRC = HERE / "app-icon-source.png"


def tile() -> Image.Image:
    img = Image.open(SRC).convert("RGBA")
    img = img.crop(img.getchannel("A").getbbox())
    side = max(img.size)
    square = Image.new("RGBA", (side, side), (0, 0, 0, 0))
    square.paste(img, ((side - img.width) // 2, (side - img.height) // 2))
    return square


def flatten(img: Image.Image, size: int, bg=(255, 255, 255)) -> Image.Image:
    out = Image.new("RGB", (size, size), bg)
    small = img.resize((size, size), Image.LANCZOS)
    out.paste(small, (0, 0), small)
    return out


def main() -> None:
    t = tile()
    t.resize((1024, 1024), Image.LANCZOS).save(HERE / "app-icon.png")
    t.resize((512, 512), Image.LANCZOS).save(HERE / "mac-icon.png")
    t.save(
        HERE / "wolfleader.ico",
        sizes=[(16, 16), (24, 24), (32, 32), (48, 48), (64, 64), (128, 128), (256, 256)],
    )
    flatten(t, 110).save(HERE / "wizard-small.bmp")
    print("wrote app-icon.png, mac-icon.png, wolfleader.ico, wizard-small.bmp")


if __name__ == "__main__":
    main()
