"""House Greyjoy: a golden kraken on a black field.

A rounded mantle with two black eyes sits at the top centre; eight tentacles (mirrored four per
side) fan out below it and curl outwards at their tips.
"""

import math

import numpy as np
import shapely

from sigil_kit import FIELD, bezier, circle, ellipse, mirror_x, poly, union

BLACK = "#101010"
GOLD = "#D9B43A"


def _curl(points, r0, sweep, n=6):
    """Extends a path with a tightening spiral that keeps turning the way +angle goes (outwards
    for the left-hand tentacles, which are mirrored for the right-hand side)."""
    (x0, y0), (x1, y1) = points[-2], points[-1]
    ang = math.atan2(y1 - y0, x1 - x0)
    cx, cy = x1 - r0 * math.sin(ang), y1 + r0 * math.cos(ang)
    phi0 = ang - math.pi / 2
    out = []
    for i in range(1, n + 1):
        t = i / n
        phi = phi0 + math.radians(sweep) * t
        r = r0 * (1 - 0.55 * t)
        out.append((cx + r * math.cos(phi), cy + r * math.sin(phi)))
    return points + out


def _ribbon(points, w0, w1):
    """Like sigil_kit.taper, but built from two offset edges, so it costs far fewer triangles."""
    pts = np.array(points, float)
    seg = np.hypot(*np.diff(pts, axis=0).T)
    acc = np.concatenate([[0], np.cumsum(seg)]) / seg.sum()
    tang = np.gradient(pts, axis=0)
    tang /= np.hypot(*tang.T)[:, None]
    normal = np.stack([-tang[:, 1], tang[:, 0]], axis=1)
    half = (w0 + (w1 - w0) * acc)[:, None] / 2
    tip = pts[-1] + tang[-1] * half[-1]
    edge_a = [tuple(p) for p in pts + normal * half]
    edge_b = [tuple(p) for p in (pts - normal * half)[::-1]]
    return poly(edge_a + [tuple(tip)] + edge_b)


def _tentacle(p0, p1, p2, p3, r0, sweep=240, w0=5.6, w1=1.8):
    path = _curl(bezier(p0, p1, p2, p3, n=10), r0, sweep)
    return shapely.simplify(_ribbon(path, w0, w1), 0.5)


def build():
    mantle = union(
        ellipse(50, 29, 14, 17.5, n=32),
        poly([(39.5, 36), (60.5, 36), (57, 49), (43, 49)]),
    )
    mantle = shapely.simplify(mantle, 0.3)
    left = union(
        _tentacle((47, 47), (43, 62), (50, 78), (44, 93), 4.6),     # inner, straight down
        _tentacle((44.5, 45), (37, 58), (41, 72), (29, 86), 5.0),   # down and out
        _tentacle((41.5, 42), (31, 50), (29, 62), (17, 71), 5.0),   # out to the flank
        _tentacle((39.5, 35), (30, 30), (20, 26), (15.5, 40), 4.2),  # raised, outermost
    )
    body = union(mantle, left, mirror_x(left))
    eyes = union(circle(44, 32, 3.0, n=12), circle(56, 32, 3.0, n=12))
    return [
        (BLACK, FIELD),
        (GOLD, body),
        (BLACK, eyes),
    ]
