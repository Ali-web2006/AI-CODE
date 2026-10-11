#!/usr/bin/env python3
"""
Generates the geometry of the world map (src/ReplicatedStorage/Shared/Data/World/MapData.luau)
by tracing a reference political map of Westeros.

Only the block between "-- BEGIN GENERATED GEOMETRY" and "-- END GENERATED GEOMETRY" in MapData.luau
is rewritten. Houses, colours, locations and every other hand-written part of the file are kept.

Pipeline:
  1. Classify each pixel of the reference into sea or one of the nine regions, using hue rules
     gated by coarse zones (so a red crest in the North is not mistaken for the Westerlands).
  2. Remove what is printed over the map (crests, labels): unknown pixels and the shields they
     enclose are refilled from the nearest classified pixel; specks and enclosed sea are dropped.
  3. Apply hand corrections (crests drawn on open sea, Dragonstone, Skagos).
  4. Impose the special bands of the spec: Beyond the Wall above y=80, the Wall from 80 to 130
     across the whole continent, the Gift below it.
  5. Split each region into 4-10 sub-territories with a noise-warped Voronoi diagram seeded at the
     game's provinces, so borders are jagged and every sub-territory maps to one province.
  6. Vectorise all areas as one polygon coverage (shared borders are identical in both
     neighbours), simplify it with shapely.coverage_simplify and write it out in map units
     (viewBox 0 0 1000 1900).

Usage (requires numpy, scipy, scikit-image, shapely >= 2.1, Pillow):
  python3 tools/mapgen/generate_map.py path/to/reference.webp [--preview build/mapgen_labels.png]

The reference image is not part of the repository. It must be the 1072x2000 political map the
geometry was traced from (a black frame of 36 px on the left and right is cropped).
"""

import argparse
import math
import re
import sys
from pathlib import Path

import numpy as np
import shapely
from PIL import Image, ImageDraw
from scipy import ndimage as ndi
from shapely.geometry import MultiPolygon, Polygon, box
from skimage.morphology import remove_small_holes

ROOT = Path(__file__).resolve().parents[2]
MAP_DATA = ROOT / "src/ReplicatedStorage/Shared/Data/World/MapData.luau"

FRAME_LEFT = 36
IMAGE_WIDTH = 1000  # after cropping the frame
SCALE = 0.95  # image px -> map units
OFFSET_X = 25.0  # centres the 950-unit-wide image in the 1000-unit viewBox
WALL_TOP, WALL_BOTTOM, GIFT_BOTTOM = 80.0, 130.0, 188.0
SIMPLIFY_TOLERANCE = 2.8  # image px

REGIONS = ["north", "vale", "riverlands", "iron_islands", "westerlands", "reach", "stormlands", "crownlands", "dorne"]
CLASSES = ["ocean"] + REGIONS + ["beyond", "black", "stepstones"]
C = {name: index for index, name in enumerate(CLASSES)}
UNKNOWN = 255

# Sub-territory counts per region (the spec asks for 4-10).
SUB_COUNTS = {
    "north": 10, "iron_islands": 6, "riverlands": 7, "vale": 6, "westerlands": 6,
    "crownlands": 5, "stormlands": 6, "reach": 9, "dorne": 7,
}

# Province seeds in image coordinates (cropped). They place each province's sub-territory and its
# holding marker; the generator prints the matching map coordinates for ProvinceDefinitions.
PROVINCE_SEEDS = {
    "north": {
        "winterfell": (490, 447), "wolfswood": (300, 385), "dreadfort": (660, 385),
        "white_harbor": (560, 640), "barrowlands": (320, 600), "moat_cailin": (453, 700),
    },
    "iron_islands": {"harlaw": (250, 1015), "pyke": (176, 1052)},
    "riverlands": {"seagard": (345, 990), "the_twins": (440, 968), "riverrun": (418, 1112), "harrenhal": (565, 1222)},
    "vale": {"bloody_gate": (610, 1040), "the_eyrie": (690, 1005), "gulltown": (868, 1035)},
    "westerlands": {"golden_tooth": (305, 1190), "casterly_rock": (182, 1305), "lannisport": (168, 1345), "crakehall": (170, 1430)},
    "crownlands": {"duskendale": (690, 1222), "dragonstone": (838, 1238), "kings_landing": (655, 1345)},
    "stormlands": {"bronzegate": (655, 1480), "storms_end": (800, 1525), "the_marches": (560, 1600)},
    "reach": {"bitterbridge": (465, 1455), "highgarden": (305, 1635), "horn_hill": (300, 1740), "oldtown": (178, 1808), "the_arbor": (130, 1930)},
    "dorne": {"kingsgrave": (440, 1760), "yronwood": (575, 1780), "the_greenblood": (745, 1868), "sunspear": (850, 1840)},
}

# Crests and labels that the reference prints on open sea (image coordinates).
FORCE_OCEAN_BOXES = [
    (268, 145, 345, 236),  # Mormont crest over Bear Island (the island is redrawn below)
    (820, 159, 886, 177),  # a label underline off Skagos
    (766, 58, 816, 120), (814, 28, 866, 90), (812, 100, 872, 166),  # Stane, Crowl, Magnar crests
    (58, 956, 100, 1003), (190, 906, 223, 946), (153, 953, 181, 986), (256, 958, 294, 1001),  # Goodbrother, Blacktyde, Stonehouse, Harlaw
    (118, 1080, 216, 1162), (92, 1064, 118, 1099),  # Greyjoy crest and label, Saltcliffe crest
    (873, 835, 912, 873),  # Baelish crest
    (873, 1108, 906, 1160),  # Celtigar crest
    (788, 1196, 878, 1246),  # Velaryon and Dragonstone labels (the island is drawn below)
    (832, 1318, 868, 1360),  # Massey crest
    (862, 1428, 906, 1457),  # Tarth crest
    (842, 1553, 886, 1602),  # Wylde crest
    (148, 1618, 203, 1668),  # Florent crest
    (88, 1276, 128, 1313),  # Prester crest
]
FORCE_OCEAN_ELLIPSES = [
    (910, 1832, 40, 42),  # Martell crest at Dorne's eastern tip
]
# Land the reference leaves implicit (image coordinates): (class, polygon).
ADD_LAND = [
    ("crownlands", [(818, 1226), (830, 1218), (846, 1219), (858, 1226), (862, 1238), (855, 1250), (842, 1256), (826, 1253), (816, 1243)]),
    ("north", [(282, 206), (290, 198), (300, 200), (308, 193), (318, 197), (326, 194), (334, 202), (333, 213), (324, 222), (312, 227), (300, 224), (290, 228), (283, 219)]),
    ("north", [(806, 78), (822, 70), (842, 74), (858, 90), (864, 112), (858, 136), (846, 152), (828, 158), (812, 148), (806, 128), (800, 104)]),
]

# Zones that gate each class (image coordinates).
def zones(xx, yy):
    def zone(x0, y0, x1, y1):
        return (xx >= x0) & (xx < x1) & (yy >= y0) & (yy < y1)

    return {
        "north": (zone(0, 60, 1000, 760) | zone(0, 760, 600, 930)) & ~zone(0, 0, 744, 120),
        "skagos": zone(744, 0, 1000, 210),
        "beyond": zone(0, 0, 744, 150),
        "iron_islands": zone(0, 880, 280, 1100),
        "westerlands": zone(0, 1060, 520, 1500),
        "riverlands": zone(200, 860, 720, 1330),
        "vale": zone(520, 730, 1000, 1200),
        "crownlands": zone(540, 1030, 1000, 1420),
        "reach": zone(40, 1240, 760, 2000),
        "stormlands": zone(470, 1250, 1000, 1780),
        "dorne": zone(300, 1630, 1000, 2000),
        "stepstones": zone(880, 1600, 1000, 1850),
        "islands": zone(744, 0, 1000, 210) | zone(270, 140, 360, 240) | zone(0, 880, 280, 1100) | zone(880, 1600, 1000, 1850)
        | zone(800, 1100, 1000, 1260) | zone(820, 1400, 1000, 1560) | zone(60, 1800, 240, 2000) | zone(585, 745, 670, 800),
    }


# 1. Classification -----------------------------------------------------------------------------

def classify(rgb):
    H, W = rgb.shape[:2]
    r, g, b = rgb[..., 0], rgb[..., 1], rgb[..., 2]
    mx, mn = rgb.max(axis=2), rgb.min(axis=2)
    chroma = mx - mn
    safe = np.where(chroma > 0, chroma, 1)
    rc, gc, bc = (mx - r) / safe, (mx - g) / safe, (mx - b) / safe
    hue = np.where(r == mx, bc - gc, np.where(g == mx, 2.0 + rc - bc, 4.0 + gc - rc))
    hue = (hue / 6.0) % 1.0 * 360
    sat = np.where(mx > 0, chroma / np.maximum(mx, 1), 0)

    ocean = (b - r >= 12) & (b - r <= 60) & (g - r >= -2) & (g - r <= 30) & (b <= 125) & (b >= g + 4)
    achro = (chroma < 30) | ((sat < 0.16) & (mx > 60))
    chrom = ~achro & ~ocean
    yy, xx = np.mgrid[0:H, 0:W]
    Z = zones(xx, yy)

    def hue_in(a, z):
        return ((hue >= a) & (hue < z)) if a < z else ((hue >= a) | (hue < z))

    lab = np.full((H, W), UNKNOWN, np.uint8)
    lab[ocean] = C["ocean"]
    for name, (a, z) in {
        "westerlands": (345, 12), "dorne": (12, 42), "stormlands": (42, 70), "reach": (70, 165),
        "vale": (165, 205), "riverlands": (205, 258), "crownlands": (258, 345),
    }.items():
        lab[chrom & hue_in(a, z) & Z[name]] = C[name]
    # The Iron Islands are tan and olive; their crests are left unknown.
    lab[Z["iron_islands"] & chrom & hue_in(30, 75)] = C["iron_islands"]
    lab[achro & Z["north"] & ~Z["iron_islands"]] = C["north"]
    lab[achro & Z["skagos"]] = C["north"]
    lab[achro & Z["beyond"] & (mx >= 40)] = C["beyond"]
    lab[achro & Z["beyond"] & (mx < 40)] = C["black"]
    lab[achro & Z["north"] & (mx < 30) & (yy < 200) & (xx > 440) & (xx < 780)] = C["black"]
    lab[achro & Z["stepstones"] & (mx > 150)] = C["stepstones"]
    return lab, Z, iron_islands_mask(rgb, hue, chroma)


# 2. Clean-up -----------------------------------------------------------------------------------

def nearest_fill(lab):
    unknown = lab == UNKNOWN
    if unknown.any():
        idx = ndi.distance_transform_edt(unknown, return_distances=False, return_indices=True)
        lab = lab[idx[0], idx[1]]
    return lab


def mode_filter(lab, size=5):
    best = np.full(lab.shape, -1.0, np.float32)
    out = lab.copy()
    for ci in np.unique(lab):
        count = ndi.uniform_filter((lab == ci).astype(np.float32), size=size)
        better = count > best
        out[better] = ci
        best[better] = count[better]
    return out


def drop_small(lab, islands, big=6000, small=120):
    for ci in range(1, len(CLASSES)):
        mask = lab == ci
        if not mask.any():
            continue
        cc, n = ndi.label(mask)
        sizes = ndi.sum(mask, cc, range(1, n + 1))
        in_zone = ndi.maximum(islands, cc, range(1, n + 1)).astype(bool)
        # A small patch with no sea around it is a crest printed on another region, not an island.
        ring = ndi.binary_dilation(mask, iterations=2) & ~mask
        touches_sea = ndi.maximum(ring & (lab == C["ocean"]), ndi.grey_dilation(cc, size=5), range(1, n + 1)).astype(bool)
        bad = np.zeros(n + 1, bool)
        bad[1:] = (sizes < small) | ((sizes < big) & ~(in_zone & touches_sea))
        lab[bad[cc] & mask] = UNKNOWN
    # Sea enclosed by land (crest fields, shadows) is not sea: keep only the open sea.
    sea = lab == C["ocean"]
    cc, n = ndi.label(sea)
    sizes = ndi.sum(sea, cc, range(1, n + 1))
    lab[sea & (cc != np.argmax(sizes) + 1)] = UNKNOWN
    return lab


IRON_BOX = (40, 880, 290, 1110)  # x0, y0, x1, y1


def iron_islands_mask(rgb, hue, chroma):
    """The Iron Islands carry so many crests that they are traced separately: tan and olive pixels,
    closed and hole-filled, without the Greyjoy crest printed below Pyke."""
    x0, y0, x1, y1 = IRON_BOX
    r, b = rgb[..., 0], rgb[..., 2]
    iron = (chroma >= 30) & (hue >= 30) & (hue < 75) & (b < r - 20)
    sub = iron[y0:y1, x0:x1].copy()
    sub[1080 - y0:1165 - y0, 118 - x0:216 - x0] = False
    sub = ndi.binary_closing(sub, np.ones((5, 5), bool))
    sub = remove_small_holes(sub, max_size=400)
    cc, n = ndi.label(sub)
    sizes = ndi.sum(sub, cc, range(1, n + 1))
    small = np.zeros(n + 1, bool)
    small[1:] = sizes <= 60
    sub[small[cc]] = False
    mask = np.zeros(rgb.shape[:2], bool)
    mask[y0:y1, x0:x1] = sub
    return mask


def apply_iron_islands(lab, iron):
    x0, y0, x1, y1 = IRON_BOX
    window = lab[y0:y1, x0:x1]
    free = np.isin(window, [C["ocean"], C["iron_islands"]])
    window[free] = np.where(iron[y0:y1, x0:x1][free], C["iron_islands"], C["ocean"])


def clean(lab, Z):
    unknown = lab == UNKNOWN
    solid = ndi.binary_opening(unknown, structure=np.ones((3, 3), bool))
    lab[remove_small_holes(solid, max_size=2500) | unknown] = UNKNOWN
    apply_corrections(lab)
    lab = drop_small(lab, Z["islands"])
    lab = nearest_fill(lab)
    for _ in range(2):
        lab = mode_filter(lab, 5)
    apply_corrections(lab)
    lab = drop_small(lab, Z["islands"])
    lab = nearest_fill(lab)
    apply_corrections(lab)
    return lab


def apply_corrections(lab):
    H, W = lab.shape
    yy, xx = np.mgrid[0:H, 0:W]
    for x0, y0, x1, y1 in FORCE_OCEAN_BOXES:
        lab[y0:y1, x0:x1] = C["ocean"]
    for cx, cy, rx, ry in FORCE_OCEAN_ELLIPSES:
        lab[((xx - cx) / rx) ** 2 + ((yy - cy) / ry) ** 2 <= 1] = C["ocean"]
    canvas = Image.new("L", (W, H), 0)
    draw = ImageDraw.Draw(canvas)
    for index, (name, points) in enumerate(ADD_LAND):
        draw.polygon(points, fill=index + 1)
    added = np.asarray(canvas)
    for index, (name, _) in enumerate(ADD_LAND):
        lab[added == index + 1] = C[name]


# 3. The Wall, the Gift and Beyond the Wall -----------------------------------------------------

def map_y(rows):
    return SCALE * (rows + 0.5)


def special_bands(lab):
    H, W = lab.shape
    land = lab != C["ocean"]
    cc, n = ndi.label(land)
    sizes = ndi.sum(land, cc, range(1, n + 1))
    mainland = cc == (np.argmax(sizes) + 1)
    ys = map_y(np.arange(H))[:, None] * np.ones((1, W))
    gift_reference = (lab == C["black"]) & (ys >= WALL_BOTTOM)

    # The Wall is a straight band from the continent's west coast to its east coast, bridging the
    # bays that cut into the band.
    band = (ys >= WALL_TOP) & (ys < WALL_BOTTOM)
    cols = np.where((mainland & band).any(axis=0))[0]
    wall_rect = band & (np.arange(W)[None, :] >= cols.min()) & (np.arange(W)[None, :] <= cols.max())
    lab[mainland & (ys < WALL_TOP)] = C["beyond"]
    lab[wall_rect] = C["black"]
    mainland |= wall_rect
    below = mainland & (ys >= WALL_BOTTOM)
    lab[below & np.isin(lab, [C["beyond"], C["black"]])] = C["north"]

    # The Gift: the reference's black area below the Wall, stretched down to GIFT_BOTTOM.
    columns = np.where(gift_reference.any(axis=0))[0]
    depth = gift_reference.sum(axis=0).astype(float)
    depth = ndi.gaussian_filter1d(depth, 6)
    top_row = int(np.ceil(WALL_BOTTOM / SCALE - 0.5))
    stretch = (GIFT_BOTTOM - WALL_BOTTOM) / SCALE / max(depth.max(), 1)
    gift = np.zeros_like(land)
    for x in range(columns.min(), columns.max() + 1):
        d = int(round(depth[x] * stretch))
        if d > 2:
            gift[top_row:top_row + d, x] = True
    gift &= mainland
    return lab, wall_rect, gift, mainland


# 4. Sub-territories ----------------------------------------------------------------------------

def smooth_noise(shape, sigma, rng):
    field = ndi.gaussian_filter(rng.standard_normal(shape), sigma)
    return field / (np.abs(field).max() + 1e-9)


def farthest_points(mask, seeds, count):
    points = list(seeds)
    ys, xs = np.nonzero(mask)
    candidates = np.stack([xs, ys], axis=1)[:: max(1, len(xs) // 6000)]
    while len(points) < count:
        pts = np.array(points, float)
        d = np.min(np.hypot(candidates[:, None, 0] - pts[None, :, 0], candidates[:, None, 1] - pts[None, :, 1]), axis=1)
        x, y = candidates[np.argmax(d)]
        points.append((int(x), int(y)))
    return points


def build_subs(lab, region, warp_x, warp_y):
    H, W = lab.shape
    mask = lab == C[region]
    cc, n = ndi.label(mask)
    sizes = ndi.sum(mask, cc, range(1, n + 1))
    order = np.argsort(-sizes)
    main_id = order[0] + 1
    provinces = PROVINCE_SEEDS[region]
    province_ids = list(provinces.keys())
    seeds = [provinces[p] for p in province_ids]

    # Large islands that hold no province seed get a sub-territory of their own (every island of
    # the Iron Islands, otherwise only big ones such as Bear Island); the rest join the nearest one.
    min_island = 600 if region == "iron_islands" else 2500
    island_seeds = []
    for k in order[1:]:
        comp = k + 1
        if sizes[k] < min_island:
            continue
        if any(cc[min(H - 1, sy), min(W - 1, sx)] == comp for sx, sy in seeds):
            continue
        ys, xs = np.nonzero(cc == comp)
        i = np.argmin(np.hypot(xs - xs.mean(), ys - ys.mean()))
        island_seeds.append((int(xs[i]), int(ys[i])))
    target = SUB_COUNTS[region]
    seeds = seeds + island_seeds[: max(0, target - len(seeds))]
    seeds = farthest_points(cc == main_id, seeds, target) if len(seeds) < target else seeds

    # Province of each seed: its own, or the nearest province seed.
    province_of = []
    for i, (sx, sy) in enumerate(seeds):
        if i < len(province_ids):
            province_of.append(province_ids[i])
        else:
            d = [math.hypot(sx - provinces[p][0], sy - provinces[p][1]) for p in province_ids]
            province_of.append(province_ids[int(np.argmin(d))])

    ys, xs = np.nonzero(mask)
    wx = xs + warp_x[ys, xs]
    wy = ys + warp_y[ys, xs]
    pts = np.array(seeds, float)
    d = np.hypot(wx[:, None] - pts[None, :, 0], wy[:, None] - pts[None, :, 1])
    owner = np.argmin(d, axis=1)
    sub = np.full((H, W), -1, np.int32)
    sub[ys, xs] = owner

    # Each seed's own landmass piece must be connected: fragments go to a neighbouring sub.
    for _ in range(3):
        changed = False
        for k in range(len(seeds)):
            m = sub == k
            if not m.any():
                continue
            kcc, kn = ndi.label(m)
            if kn <= 1:
                continue
            sizes_k = ndi.sum(m, kcc, range(1, kn + 1))
            sx, sy = seeds[k]
            keep = kcc[sy, sx] if 0 <= sy < H and 0 <= sx < W and kcc[sy, sx] > 0 else np.argmax(sizes_k) + 1
            for j in range(1, kn + 1):
                if j == keep:
                    continue
                piece = kcc == j
                ring = ndi.binary_dilation(piece) & ~piece & mask
                neighbours = sub[ring]
                neighbours = neighbours[(neighbours >= 0) & (neighbours != k)]
                if len(neighbours):
                    sub[piece] = np.bincount(neighbours).argmax()
                    changed = True
        if not changed:
            break
    return sub, seeds, province_of


def pick_shades(rgb, sub_masks, adjacency, palette):
    palette_rgb = np.array([[int(c[i:i + 2], 16) for i in (1, 3, 5)] for c in palette], float)
    choice = {}
    for sid in sorted(sub_masks, key=lambda s: -sub_masks[s].sum()):
        colours = rgb[sub_masks[sid]]
        median = np.median(colours, axis=0)
        order = np.argsort(np.abs(palette_rgb - median).sum(axis=1))
        taken = {choice[n] for n in adjacency.get(sid, ()) if n in choice}
        pick = next((int(i) for i in order if int(i) not in taken), int(order[0]))
        choice[sid] = pick
    return choice


# 5. Vectorisation ------------------------------------------------------------------------------

def label_polygons(ids):
    """Exact pixel-boundary polygons for every positive id of an integer raster."""
    H, W = ids.shape
    rects = {}
    for y in range(H):
        row = ids[y]
        change = np.flatnonzero(np.diff(row)) + 1
        starts = np.concatenate([[0], change])
        ends = np.concatenate([change, [W]])
        for s, e in zip(starts, ends):
            v = int(row[s])
            if v > 0:
                rects.setdefault(v, []).append(box(s, y, e, y + 1))
    return {v: shapely.union_all(r) for v, r in rects.items()}


def to_map(geom):
    return shapely.transform(geom, lambda c: np.stack([OFFSET_X + SCALE * c[:, 0], SCALE * c[:, 1]], axis=1))


def rings(geom):
    polys = [geom] if isinstance(geom, Polygon) else list(geom.geoms)
    out = []
    for p in polys:
        if p.is_empty:
            continue
        if len(p.interiors):
            raise SystemExit(f"polygon with a hole near {p.representative_point()}: adjust the seeds")
        out.append(list(p.exterior.coords)[:-1])
    return out


def fmt_path(coords):
    return "{ " + ", ".join(f"{x:.1f}, {y:.1f}" for x, y in coords) + " }"


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("reference")
    parser.add_argument("--preview", help="write a PNG of the classified areas")
    parser.add_argument("--dry-run", action="store_true", help="do not rewrite MapData.luau")
    args = parser.parse_args()

    image = np.asarray(Image.open(args.reference).convert("RGB")).astype(np.float32)
    if image.shape[1] != IMAGE_WIDTH + 2 * FRAME_LEFT:
        sys.exit(f"expected a {IMAGE_WIDTH + 2 * FRAME_LEFT}px wide reference, got {image.shape[1]}px")
    rgb = image[:, FRAME_LEFT:FRAME_LEFT + IMAGE_WIDTH]
    H, W = rgb.shape[:2]

    lab, Z, iron = classify(rgb)
    lab = clean(lab, Z)
    apply_iron_islands(lab, iron)
    lab, wall, gift, mainland = special_bands(lab)
    north_or_gift = gift & (lab == C["north"])

    rng = np.random.default_rng(297)
    warp_x = smooth_noise((H, W), 22, rng) * 26 + smooth_noise((H, W), 5, rng) * 7
    warp_y = smooth_noise((H, W), 22, rng) * 26 + smooth_noise((H, W), 5, rng) * 7

    # Area ids: 1..k sub-territories, then the special features.
    ids = np.zeros((H, W), np.int32)
    subs = []
    next_id = 1
    for region in REGIONS:
        region_mask = lab == C[region]
        if region == "north":
            region_mask &= ~north_or_gift
        tmp = lab.copy()
        tmp[~region_mask & (tmp == C[region])] = C["ocean"]
        sub, seeds, province_of = build_subs(tmp, region, warp_x, warp_y)
        for k in range(len(seeds)):
            m = sub == k
            if not m.any():
                continue
            ids[m] = next_id
            subs.append({"id": next_id, "region": region, "province": province_of[k], "seed": seeds[k]})
            next_id += 1
    features = {}
    for name, mask in [
        ("beyond_the_wall", lab == C["beyond"]),
        ("the_wall", wall),
        ("the_gift", north_or_gift),
        ("stepstones", lab == C["stepstones"]),
    ]:
        ids[mask] = next_id
        features[name] = next_id
        next_id += 1

    if args.preview:
        rng_preview = np.random.default_rng(1)
        colours = rng_preview.integers(40, 255, size=(next_id + 1, 3)).astype(np.uint8)
        colours[0] = (61, 74, 99)
        Image.fromarray(colours[ids]).save(args.preview)

    # Adjacency between sub-territories (4-neighbourhood), for shading.
    adjacency = {}
    for a, b in [(ids[:, :-1], ids[:, 1:]), (ids[:-1, :], ids[1:, :])]:
        diff = (a != b) & (a > 0) & (b > 0)
        for u, v in set(zip(a[diff].tolist(), b[diff].tolist())):
            adjacency.setdefault(u, set()).add(v)
            adjacency.setdefault(v, set()).add(u)

    polygons = label_polygons(ids)
    order = sorted(polygons)
    simplified = shapely.coverage_simplify([polygons[k] for k in order], tolerance=SIMPLIFY_TOLERANCE, simplify_boundary=True)
    shapes = {k: to_map(shapely.make_valid(g)) for k, g in zip(order, simplified)}

    text = render_luau(subs, features, shapes, rgb, ids, adjacency)
    if args.dry_run:
        print(text[:2000])
    else:
        source = MAP_DATA.read_text(encoding="utf-8")
        pattern = re.compile(r"-- BEGIN GENERATED GEOMETRY.*?-- END GENERATED GEOMETRY", re.S)
        if not pattern.search(source):
            sys.exit(f"{MAP_DATA} has no generated-geometry markers")
        MAP_DATA.write_text(pattern.sub(lambda _: text, source), encoding="utf-8")
        print(f"rewrote the generated block of {MAP_DATA.relative_to(ROOT)}")

    vertices = sum(sum(len(r) for r in rings(shapes[s["id"]])) for s in subs)
    triangles = sum(sum(len(r) - 2 for r in rings(shapes[s["id"]])) for s in subs)
    print(f"{len(subs)} sub-territories, {vertices} vertices, {triangles} triangles")
    print("province positions (map units):")
    for region in REGIONS:
        for province, (x, y) in PROVINCE_SEEDS[region].items():
            print(f"  {province:16} x = {OFFSET_X + SCALE * x:.0f}, y = {SCALE * y:.0f}")


def render_luau(subs, features, shapes, rgb, ids, adjacency):
    house_palettes = read_palettes()
    lines = ["-- BEGIN GENERATED GEOMETRY (tools/mapgen/generate_map.py; do not edit by hand)"]
    lines.append("local GEOMETRY: Geometry = {")
    lines.append("\tsubTerritories = {")
    counters = {}
    shade_choice = {}
    for region in REGIONS:
        region_subs = [s for s in subs if s["region"] == region]
        masks = {s["id"]: ids == s["id"] for s in region_subs}
        palette = house_palettes[REGION_HOUSE[region]]
        shade_choice.update(pick_shades(rgb, masks, adjacency, palette))
    for s in subs:
        region = s["region"]
        counters[region] = counters.get(region, 0) + 1
        s["name"] = f"{region}_{counters[region]:02d}"
        paths = rings(shapes[s["id"]])
        lines.append(f'\t\t{{ id = "{s["name"]}", regionId = "{region}", provinceId = "{s["province"]}", shade = {shade_choice[s["id"]] + 1}, paths = {{')
        for p in paths:
            lines.append(f"\t\t\t{fmt_path(p)},")
        lines.append("\t\t} },")
    lines.append("\t},")
    lines.append("\tregions = {")
    for region in REGIONS:
        outline = shapely.union_all([shapes[s["id"]] for s in subs if s["region"] == region])
        lines.append(f"\t\t{region} = {{")
        for p in rings(outline):
            lines.append(f"\t\t\t{fmt_path(p)},")
        lines.append("\t\t},")
    lines.append("\t},")
    lines.append("\tfeatures = {")
    for name, fid in features.items():
        lines.append(f"\t\t{name} = {{")
        for p in rings(shapes[fid]):
            lines.append(f"\t\t\t{fmt_path(p)},")
        lines.append("\t\t},")
    lines.append("\t},")
    lines.append("}")
    lines.append("-- END GENERATED GEOMETRY")
    return "\n".join(lines)


REGION_HOUSE = {
    "north": "stark", "vale": "arryn", "riverlands": "tully", "iron_islands": "greyjoy", "westerlands": "lannister",
    "reach": "tyrell", "stormlands": "baratheon", "crownlands": "targaryen", "dorne": "martell",
}


def read_palettes():
    """Reads each house's shadeColors from the hand-written part of MapData.luau."""
    source = MAP_DATA.read_text(encoding="utf-8")
    palettes = {}
    for match in re.finditer(r'id = "(\w+)",.*?shadeColors = \{([^}]*)\}', source, re.S):
        palettes[match.group(1)] = re.findall(r'"(#[0-9A-Fa-f]{6})"', match.group(2))
    missing = [h for h in REGION_HOUSE.values() if not palettes.get(h)]
    if missing:
        sys.exit(f"MapData.luau lacks shadeColors for {missing}")
    return palettes


if __name__ == "__main__":
    main()
