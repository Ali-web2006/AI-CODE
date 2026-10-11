"""House Baratheon: a crowned black stag's head, caboshed (facing out), on a golden field."""

import numpy as np

from sigil_kit import FIELD, bezier, circle, diff, ellipse, mirror_x, poly, rect, scale, union

GOLD = "#F0C419"
BLACK = "#151515"


def _horn(points, w0, w1):
    """A ribbon along the points whose width runs from w0 to w1 (w1 near 0 gives a pointed tine)."""
    pts = np.array(points, float)
    seg = np.hypot(*np.diff(pts, axis=0).T)
    acc = np.concatenate([[0], np.cumsum(seg)]) / (seg.sum() or 1.0)
    tangent = np.gradient(pts, axis=0)
    tangent /= np.hypot(*tangent.T)[:, None]
    normal = np.stack([-tangent[:, 1], tangent[:, 0]], axis=1)
    half = ((w0 + (w1 - w0) * acc) / 2)[:, None]
    left, right = pts + normal * half, pts - normal * half
    return poly([tuple(p) for p in left] + [tuple(p) for p in right[::-1]])


def _antler():
    """The dexter (left) antler: a beam sweeping out and up with tines rising from it."""
    beam = _horn(bezier((44, 47), (24, 47), (12, 34), (20, 13), 14), 9.5, 2.0)
    tine_a = _horn(bezier((31, 46), (29, 39), (32, 31), None, 8), 6.5, 1.6)
    tine_b = _horn(bezier((22, 41), (22, 32), (28, 24), None, 8), 6.5, 1.6)
    tine_c = _horn(bezier((16, 32), (12, 27), (11, 20), None, 8), 6.0, 1.6)
    return union(beam, tine_a, tine_b, tine_c)


def _place(geom):
    """Drawn edge to edge; pull it in a little so gold shows all round."""
    return scale(geom, 0.94, origin=(50, 56))


def build():
    half_head = poly([(50, 45), (42, 46), (37.5, 52), (36, 60), (38.5, 70), (42.5, 82), (44.5, 91), (46, 96), (50, 97)])
    ear = poly([(39, 53.5), (30, 51.5), (19, 56), (27, 62.5), (38.5, 64)])
    left = union(half_head, ear, _antler())
    stag = union(left, mirror_x(left))

    crown_band = rect(41, 38, 59, 45)
    crown_points = union(
        poly([(41, 39), (41, 30), (46, 38)]),
        poly([(45, 38), (50, 27), (55, 38)]),
        poly([(54, 38), (59, 30), (59, 39)]),
    )
    crown = union(crown_band, crown_points, circle(41, 30, 1.9, n=12), circle(50, 27, 1.9, n=12), circle(59, 30, 1.9, n=12))
    stag = diff(stag, crown.buffer(2.6, join_style="mitre"))

    eyes = union(ellipse(41.5, 64, 3.3, 1.6, 25, n=12), ellipse(58.5, 64, 3.3, 1.6, -25, n=12))
    return [
        (GOLD, FIELD),
        (BLACK, _place(union(stag, crown)).simplify(0.3)),
        (GOLD, _place(eyes)),
    ]
