"""Draw the Wolf Leader mark and write app-icon-source.png (the input to make_icons.py).

The mark is the minimal line wolf: an outline of the head with the brow and muzzle
lines inside it. It is defined on a 24 x 24 grid, the same as the inline SVG used in
the app, hub and wiki, so every size comes from one set of points.

Usage:  python installer/assets/make_logo.py      (needs `pip install pillow`)
        python installer/assets/make_icons.py     (then cut the icon sizes from it)
"""
from pathlib import Path

from PIL import Image, ImageDraw

HERE = Path(__file__).resolve().parent

# 24-unit grid. Keep in sync with WolfMark in the Mac app and the inline SVGs.
OUTLINE = [(3, 3), (7, 17), (12, 21), (17, 17), (21, 3), (15, 8), (12, 6), (9, 8)]
BROW = [(7, 12), (12, 16), (17, 12)]
MUZZLE = [(12, 16), (12, 21)]
STROKE = 1.6

CANVAS = 1024
TILE = 824          # macOS icon grid: the rounded tile inside a 1024 canvas
RADIUS = 185
MARK = 500          # size of the 24-unit grid inside the tile
SCALE = 4           # supersampling

TILE_TOP = (22, 32, 51)
TILE_BOTTOM = (11, 17, 29)
INK = (238, 243, 250)


def main() -> None:
    size = CANVAS * SCALE
    # Vertical gradient, clipped to the rounded tile.
    gradient = Image.new("RGB", (1, size))
    for y in range(size):
        t = y / (size - 1)
        gradient.putpixel((0, y), tuple(round(a + (b - a) * t) for a, b in zip(TILE_TOP, TILE_BOTTOM)))
    gradient = gradient.resize((size, size))
    mask = Image.new("L", (size, size), 0)
    inset = (CANVAS - TILE) // 2 * SCALE
    ImageDraw.Draw(mask).rounded_rectangle(
        (inset, inset, size - inset, size - inset), radius=RADIUS * SCALE, fill=255
    )
    icon = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    icon.paste(gradient, (0, 0), mask)

    unit = MARK * SCALE / 24
    origin = (size - MARK * SCALE) / 2
    # The mark's own box is 3..21 wide and 3..21 tall, so it is already centred on the grid.

    def at(points):
        return [(origin + x * unit, origin + y * unit) for x, y in points]

    draw = ImageDraw.Draw(icon)
    width = round(STROKE * unit)
    draw.line(at(OUTLINE + OUTLINE[:2]), fill=INK, width=width, joint="curve")
    draw.line(at(BROW), fill=INK, width=width, joint="curve")
    draw.line(at(MUZZLE), fill=INK, width=width)

    icon.resize((CANVAS, CANVAS), Image.LANCZOS).save(HERE / "app-icon-source.png")
    print("wrote app-icon-source.png")


if __name__ == "__main__":
    main()
