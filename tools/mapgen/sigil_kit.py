"""
Shared drawing kit for the house sigils (see build_sigils.py).

Sigil art lives in a 100 x 120 box (x right, y down) containing a heater shield with a pointed
bottom. Each house module in tools/mapgen/sigils/ defines `build()` returning layers, bottom to top:
    [(colour_hex, shapely_geometry), ...]
The first layer(s) paint the field (use FIELD, or parts of it); later layers are the charge.
Everything is clipped to FIELD; build_sigils.py adds the dark rim around the shield.
"""

import math

import numpy as np
import shapely
from shapely import affinity
from shapely.geometry import LineString, Point, Polygon, box

BOX_W, BOX_H = 100.0, 120.0
RIM_COLOR = "#1A1A1A"


def bezier(p0, p1, p2, p3=None, n=24):
    """Cubic (or quadratic when p3 is None) Bezier curve as a list of points."""
    t = np.linspace(0, 1, n)[:, None]
    p0, p1, p2 = np.array(p0, float), np.array(p1, float), np.array(p2, float)
    if p3 is None:
        pts = (1 - t) ** 2 * p0 + 2 * (1 - t) * t * p1 + t ** 2 * p2
    else:
        p3 = np.array(p3, float)
        pts = (1 - t) ** 3 * p0 + 3 * (1 - t) ** 2 * t * p1 + 3 * (1 - t) * t ** 2 * p2 + t ** 3 * p3
    return [tuple(p) for p in pts]


def _shield():
    left = [(4, 4)] + bezier((4, 60), (4, 92), (50, 116), None, 20)[:-1]
    right = bezier((50, 116), (96, 92), (96, 60), None, 20)[1:] + [(96, 4)]
    return Polygon(left + [(50, 116)] + right)


SHIELD = _shield()
FIELD = SHIELD.buffer(-3.2, join_style="mitre")


def poly(points):
    return shapely.make_valid(Polygon(points))


def rect(x0, y0, x1, y1):
    return box(x0, y0, x1, y1)


def circle(cx, cy, r, n=40):
    return Point(cx, cy).buffer(r, quad_segs=max(4, n // 4))


def ellipse(cx, cy, rx, ry, angle=0.0, n=40):
    e = affinity.scale(Point(0, 0).buffer(1, quad_segs=max(4, n // 4)), rx, ry)
    return affinity.translate(affinity.rotate(e, angle, origin=(0, 0)), cx, cy)


def star(cx, cy, r_out, r_in, points, angle=-90.0):
    pts = []
    for i in range(points * 2):
        r = r_out if i % 2 == 0 else r_in
        a = math.radians(angle + i * 180.0 / points)
        pts.append((cx + r * math.cos(a), cy + r * math.sin(a)))
    return Polygon(pts)


def stroke(points, width, cap="round"):
    """A line of constant width along the points."""
    return LineString(points).buffer(width / 2, cap_style=cap, join_style="round", quad_segs=4)


def taper(points, w0, w1):
    """A line whose width changes linearly from w0 to w1 along the points (tentacles, tails)."""
    pts = np.array(points, float)
    seg = np.hypot(*np.diff(pts, axis=0).T)
    total = seg.sum() or 1.0
    acc = np.concatenate([[0], np.cumsum(seg)]) / total
    parts = []
    for i in range(len(pts) - 1):
        a, b = pts[i], pts[i + 1]
        ra = (w0 + (w1 - w0) * acc[i]) / 2
        rb = (w0 + (w1 - w0) * acc[i + 1]) / 2
        parts.append(shapely.convex_hull(shapely.union(Point(a).buffer(ra, quad_segs=3), Point(b).buffer(rb, quad_segs=3))))
    return shapely.union_all(parts)


def union(*geoms):
    return shapely.union_all([g for g in geoms if g is not None])


def diff(a, *bs):
    for b in bs:
        a = a.difference(b)
    return a


def rotate(geom, angle, origin=(50, 60)):
    return affinity.rotate(geom, angle, origin=origin)


def translate(geom, dx, dy):
    return affinity.translate(geom, dx, dy)


def scale(geom, sx, sy=None, origin=(50, 60)):
    return affinity.scale(geom, sx, sy if sy is not None else sx, origin=origin)


def mirror_x(geom, cx=50.0):
    return affinity.scale(geom, -1, 1, origin=(cx, 0))


# Preview and statistics -------------------------------------------------------------------------

def finish(layers):
    """Clips the house's layers to the field and puts the rim underneath."""
    out = [(RIM_COLOR, SHIELD)]
    for colour, geom in layers:
        clipped = shapely.make_valid(geom).intersection(FIELD)
        if not clipped.is_empty:
            out.append((colour, clipped))
    return out


def triangulate(geom, tolerance=0.25):
    geom = shapely.make_valid(shapely.simplify(geom, tolerance, preserve_topology=True))
    polygons = [g for g in shapely.get_parts(geom) if g.geom_type == "Polygon" and g.area > 0.05]
    triangles = []
    for p in polygons:
        for t in shapely.get_parts(shapely.constrained_delaunay_triangles(p)):
            if t.area > 0.01:
                triangles.append(list(t.exterior.coords)[:3])
    return triangles


def render(layers, path, size=240):
    """Draws the finished layers into a PNG, through the same triangles the game draws."""
    from PIL import Image, ImageDraw

    k = size / BOX_H
    image = Image.new("RGB", (int(BOX_W * k), size), (61, 74, 99))
    draw = ImageDraw.Draw(image)
    count = 0
    for colour, geom in finish(layers):
        rgb = tuple(int(colour[i:i + 2], 16) for i in (1, 3, 5))
        for tri in triangulate(geom):
            draw.polygon([(x * k, y * k) for x, y in tri], fill=rgb)
            count += 1
    image.save(path)
    return count
