#!/usr/bin/env python3
"""
Renders a PNG preview of the world map from its configuration (MapData + SigilArt), so map edits
can be reviewed without Roblox Studio. It mirrors the in-game drawing rules of MapController:
flat sub-territory fills, thin sub-territory borders, thicker region borders, crests and two-line
great-house labels sized by zoom (MapStyle), location icons and labels past the label zoom.

Usage:
  lune run tests/map_dump.luau > build/map.json
  python3 tools/render_map_preview.py build/map.json build/map_preview.png [--zoom 0.5]
      [--crop x0,y0,x1,y1] [--no-sub-borders]

--zoom is screen pixels per map unit (the game's fit-to-screen zoom on a 1280x720 layout is about
0.35; location labels appear from 0.75). Requires Pillow.
"""

import argparse
import json
import math
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont

SUPERSAMPLE = 3

# Keep in sync with src/StarterPlayer/StarterPlayerScripts/UI/MapStyle.luau.
STYLE = {
    "sub_border": ((48, 48, 48), 1.0),
    "region_border": ((14, 14, 14), 2.0),
    "crest_units": 110, "crest_min": 40, "crest_max": 84, "crest_fade": (1.0, 1.8, 0.55),
    "house_text_units": 40, "house_text_min": 13, "house_text_max": 24,
    "location_icon_zoom": 0.45, "location_label_zoom": 0.75, "icon_px": 14, "location_text": 12,
}


def hex_rgb(value):
    value = value.lstrip("#")
    return tuple(int(value[i:i + 2], 16) for i in (0, 2, 4))


def luminance(rgb):
    r, g, b = (c / 255 for c in rgb)
    return 0.2126 * r + 0.7152 * g + 0.0722 * b


def font(size, bold=True):
    names = ["DejaVuSerif-Bold.ttf", "LiberationSerif-Bold.ttf"] if bold else ["DejaVuSerif.ttf", "LiberationSerif-Regular.ttf"]
    for name in names:
        try:
            return ImageFont.truetype(name, size)
        except OSError:
            continue
    return ImageFont.load_default()


def pairs(path):
    return [(path[i], path[i + 1]) for i in range(0, len(path), 2)]


class Canvas:
    def __init__(self, data, zoom, crop):
        self.data = data
        self.zoom = zoom
        mp = data["map"]
        self.x0, self.y0, x1, y1 = crop or (0, 0, mp["width"], mp["height"])
        self.k = zoom * SUPERSAMPLE
        self.size = (int((x1 - self.x0) * self.k), int((y1 - self.y0) * self.k))
        self.image = Image.new("RGBA", self.size, hex_rgb(mp["oceanColor"]) + (255,))
        self.draw = ImageDraw.Draw(self.image)

    def pt(self, x, y):
        return ((x - self.x0) * self.k, (y - self.y0) * self.k)

    def overlay(self):
        layer = Image.new("RGBA", self.size, (0, 0, 0, 0))
        return layer, ImageDraw.Draw(layer)

    def merge(self, layer):
        self.image = Image.alpha_composite(self.image, layer)
        self.draw = ImageDraw.Draw(self.image)


def text_with_halo(draw, xy, text, fnt, fill, halo, width, anchor="mm"):
    draw.text(xy, text, font=fnt, fill=fill, anchor=anchor, stroke_width=width, stroke_fill=halo)


def draw_icon(draw, x, y, kind, s):
    ink, paper = (24, 20, 16), (244, 236, 216)
    h = s / 2
    if kind == "seat":  # castle: keep with three merlons
        draw.rectangle([x - h, y - h * 0.3, x + h, y + h], fill=paper, outline=ink, width=max(1, int(s / 9)))
        for dx in (-h, -h * 0.2 + 0.1, h * 0.6):
            draw.rectangle([x + dx, y - h, x + dx + h * 0.4, y - h * 0.3], fill=paper, outline=ink, width=max(1, int(s / 9)))
        draw.rectangle([x - h * 0.2, y + h * 0.3, x + h * 0.2, y + h], fill=ink)
    elif kind == "city":  # house with a pitched roof
        draw.polygon([(x - h, y - h * 0.05), (x, y - h), (x + h, y - h * 0.05)], fill=ink)
        draw.rectangle([x - h * 0.75, y - h * 0.05, x + h * 0.75, y + h], fill=paper, outline=ink, width=max(1, int(s / 9)))
        draw.rectangle([x - h * 0.2, y + h * 0.35, x + h * 0.2, y + h], fill=ink)
    elif kind == "port":  # anchor
        w = max(1, int(s / 7))
        draw.ellipse([x - h * 0.28, y - h, x + h * 0.28, y - h * 0.45], outline=ink, width=w)
        draw.line([(x, y - h * 0.45), (x, y + h)], fill=ink, width=w)
        draw.line([(x - h * 0.55, y - h * 0.2), (x + h * 0.55, y - h * 0.2)], fill=ink, width=w)
        draw.arc([x - h, y - h * 0.2, x + h, y + h], 20, 160, fill=ink, width=w)
    else:  # landmark: a tower
        draw.polygon([(x - h * 0.55, y + h), (x - h * 0.35, y - h * 0.5), (x + h * 0.35, y - h * 0.5), (x + h * 0.55, y + h)], fill=paper, outline=ink)
        draw.polygon([(x - h * 0.5, y - h * 0.5), (x, y - h), (x + h * 0.5, y - h * 0.5)], fill=ink)


def draw_sigil(canvas, art, cx, cy, width_px, fallback):
    k = width_px * SUPERSAMPLE / 100.0
    ox, oy = canvas.pt(cx, cy)
    ox -= 50 * k
    oy -= 60 * k
    draw = canvas.draw
    if not art:
        shield = [(4, 4), (96, 4), (96, 60), (50, 116), (4, 60)]
        draw.polygon([(ox + x * k, oy + y * k) for x, y in shield], fill=hex_rgb(fallback), outline=(26, 26, 26))
        return
    for layer in art["layers"]:
        colour = hex_rgb(layer["color"])
        t = layer["tris"]
        for i in range(0, len(t), 6):
            draw.polygon([(ox + t[i] * k, oy + t[i + 1] * k), (ox + t[i + 2] * k, oy + t[i + 3] * k), (ox + t[i + 4] * k, oy + t[i + 5] * k)], fill=colour)


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("source")
    parser.add_argument("target")
    parser.add_argument("--zoom", type=float, default=0.5)
    parser.add_argument("--crop", help="x0,y0,x1,y1 in map units")
    parser.add_argument("--no-sub-borders", action="store_true")
    parser.add_argument("--no-crests", action="store_true", help="leave out crests and house labels")
    args = parser.parse_args()

    data = json.loads(Path(args.source).read_text(encoding="utf-8"))
    mp = data["map"]
    crop = tuple(float(v) for v in args.crop.split(",")) if args.crop else None
    cv = Canvas(data, args.zoom, crop)
    houses = {h["id"]: h for h in mp["houses"]}
    regions = {r["id"]: r for r in mp["regions"]}

    # Fills
    for sub in mp["subTerritories"]:
        house = houses[sub.get("houseId") or regions[sub["regionId"]]["houseId"]]
        colour = hex_rgb(house["shadeColors"][sub["shade"] - 1])
        for path in sub["paths"]:
            cv.draw.polygon([cv.pt(x, y) for x, y in pairs(path)], fill=colour)
    for feature in mp["specialFeatures"]:
        for path in feature["paths"]:
            cv.draw.polygon([cv.pt(x, y) for x, y in pairs(path)], fill=hex_rgb(feature["color"]))

    # Borders
    def outline(paths, style):
        colour, width = style
        for path in paths:
            pts = [cv.pt(x, y) for x, y in pairs(path)]
            cv.draw.line(pts + [pts[0]], fill=colour, width=max(1, int(round(width * SUPERSAMPLE))), joint="curve")

    if not args.no_sub_borders:
        outline([p for s in mp["subTerritories"] for p in s["paths"]], STYLE["sub_border"])
    outline([p for f in mp["specialFeatures"] for p in f["paths"]], STYLE["sub_border"])
    outline([p for r in mp["regions"] for p in r["paths"]], STYLE["region_border"])

    z = args.zoom
    # Crests (below everything else that is printed on the map)
    crest_px = max(STYLE["crest_min"], min(STYLE["crest_max"], STYLE["crest_units"] * z))
    fade_from, fade_to, fade_max = STYLE["crest_fade"]
    fade = fade_max * max(0.0, min(1.0, (z - fade_from) / (fade_to - fade_from)))
    if not args.no_crests:
        layer_before = cv.image
        cv.image = cv.image.copy()
        cv.draw = ImageDraw.Draw(cv.image)
        for house in mp["houses"]:
            if house.get("crest") and not house.get("minor"):
                draw_sigil(cv, data.get("sigils", {}).get(house["id"]), house["crest"]["x"], house["crest"]["y"], crest_px, house["primaryColor"])
        cv.image = Image.blend(cv.image, layer_before, fade)
        cv.draw = ImageDraw.Draw(cv.image)

    # Feature labels
    for feature in mp["specialFeatures"]:
        if feature.get("label"):
            size = int(max(11, min(18, 30 * z)) * SUPERSAMPLE)
            lum = luminance(hex_rgb(feature["color"]))
            fill = (245, 245, 245) if lum < 0.5 else (40, 40, 40)
            text_with_halo(cv.draw, cv.pt(feature["label"]["x"], feature["label"]["y"]), feature["name"].upper(), font(size), fill, (0, 0, 0) if lum < 0.5 else (255, 255, 255), SUPERSAMPLE)

    # Locations
    if z >= STYLE["location_icon_zoom"]:
        for loc in mp["locations"]:
            x, y = cv.pt(loc["x"], loc["y"])
            draw_icon(cv.draw, x, y, loc["type"], STYLE["icon_px"] * SUPERSAMPLE)
            if z >= STYLE["location_label_zoom"]:
                text_with_halo(cv.draw, (x, y + STYLE["icon_px"] * 0.6 * SUPERSAMPLE), loc["name"], font(STYLE["location_text"] * SUPERSAMPLE, False), (24, 20, 16), (244, 236, 216), SUPERSAMPLE, anchor="mt")

    # Great-house labels (always visible)
    for house in mp["houses"]:
        if house.get("minor") or args.no_crests or not house.get("label"):
            continue
        size = max(STYLE["house_text_min"], min(STYLE["house_text_max"], STYLE["house_text_units"] * z))
        dark_text = luminance(hex_rgb(house["primaryColor"])) > 0.55
        fill, halo = ((40, 40, 40), (255, 255, 255)) if dark_text else ((255, 255, 255), (20, 20, 20))
        x, y = cv.pt(house["label"]["x"], house["label"]["y"])
        name = house["name"].split(" ", 1)[1].upper()
        text_with_halo(cv.draw, (x, y - size * 0.55 * SUPERSAMPLE), "HOUSE", font(int(size * 0.62 * SUPERSAMPLE)), fill, halo, int(1.5 * SUPERSAMPLE))
        text_with_halo(cv.draw, (x, y + size * 0.35 * SUPERSAMPLE), name, font(int(size * SUPERSAMPLE)), fill, halo, int(1.5 * SUPERSAMPLE))

    out = cv.image.resize((cv.size[0] // SUPERSAMPLE, cv.size[1] // SUPERSAMPLE), Image.LANCZOS).convert("RGB")
    out.save(args.target)
    print(f"wrote {args.target} ({out.size[0]}x{out.size[1]})")


if __name__ == "__main__":
    main()
