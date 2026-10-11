#!/usr/bin/env python3
"""
Renders a PNG preview of the strategic map from content data, so map edits (positions, landmass,
labels, adjacency) can be reviewed without opening Roblox Studio. Mirrors the in-game drawing:
coastline and landmass circles, owner-coloured territory halos (same radius rule as
MapController), routes coloured by connection kind, province markers and labels.

Usage:
  lune run tests/map_dump.luau > build/map.json
  python3 tools/render_map_preview.py build/map.json build/map_preview.png

Requires Pillow (pip install pillow).
"""

import json
import math
import sys

from PIL import Image, ImageDraw, ImageFont

SCALE = 0.7
SEA = (124, 150, 152)
COAST = (176, 156, 112)
LAND = (228, 214, 180)
INK = (43, 33, 22)
LABEL = (92, 72, 48)
ROUTES = {
    "road": (128, 96, 64),
    "river": (70, 110, 150),
    "sea": (232, 240, 240),
    "pass": (90, 70, 60),
    "wild": (110, 120, 80),
}


def main(source, target):
    with open(source, encoding="utf-8") as handle:
        data = json.load(handle)
    world = data["map"]
    provinces = data["provinces"]
    by_id = {p["id"]: p for p in provinces}
    size = (int(world["width"] * SCALE), int(world["height"] * SCALE))
    image = Image.new("RGBA", size, SEA + (255,))
    draw = ImageDraw.Draw(image)

    def circle(layer, x, y, radius, colour):
        layer.ellipse([(x - radius) * SCALE, (y - radius) * SCALE, (x + radius) * SCALE, (y + radius) * SCALE], fill=colour)

    for blob in world["landmass"]:
        circle(draw, blob["x"], blob["y"], blob["r"] + 6, COAST)
    for blob in world["landmass"]:
        circle(draw, blob["x"], blob["y"], blob["r"], LAND)

    for province in provinces:
        nearest = min(math.hypot(province["x"] - other["x"], province["y"] - other["y"]) for other in provinces if other is not province)
        radius = max(34, min(82, nearest * 0.62))
        halo = Image.new("RGBA", size, (0, 0, 0, 0))
        circle(ImageDraw.Draw(halo), province["x"], province["y"], radius, tuple(province["color"]) + (120,))
        image = Image.alpha_composite(image, halo)
    draw = ImageDraw.Draw(image)

    for province in provinces:
        for neighbour_id, kind in province["adjacent"].items():
            if province["id"] < neighbour_id:
                other = by_id[neighbour_id]
                draw.line([(province["x"] * SCALE, province["y"] * SCALE), (other["x"] * SCALE, other["y"] * SCALE)], fill=ROUTES[kind], width=2)

    try:
        font = ImageFont.truetype("DejaVuSans.ttf", 11)
    except OSError:
        font = ImageFont.load_default()
    for province in provinces:
        x, y = province["x"] * SCALE, province["y"] * SCALE
        draw.rectangle([x - 8, y - 8, x + 8, y + 8], fill=tuple(province["color"]), outline=INK)
        width = draw.textlength(province["name"], font=font)
        draw.text((x - width / 2, y + 10), province["name"], fill=INK, font=font)
    for label in world["labels"]:
        width = draw.textlength(label["text"], font=font)
        draw.text((label["x"] * SCALE - width / 2, label["y"] * SCALE - 6), label["text"], fill=LABEL, font=font)

    image.convert("RGB").save(target)
    print(f"wrote {target} ({size[0]}x{size[1]})")


if __name__ == "__main__":
    if len(sys.argv) != 3:
        print(__doc__)
        sys.exit(2)
    main(sys.argv[1], sys.argv[2])
