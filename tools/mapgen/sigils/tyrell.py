"""House Tyrell: a golden rose on a green field."""

import math

import numpy as np

from sigil_kit import FIELD, bezier, circle, poly, union

GREEN = "#2E8B2E"
GOLD = "#F2C230"
DARK = "#B8860B"

CX, CY = 50.0, 45.0


def polar(r, deg, cx=CX, cy=CY):
    a = math.radians(deg)
    return (cx + r * math.cos(a), cy + r * math.sin(a))


def scallop(r_notch, r_tip, k, phase, n=9, cx=CX, cy=CY):
    """A flower outline of k rounded petals: notches at r_notch, petal tips at r_tip."""
    step = 360.0 / k
    r_ctrl = (r_tip - 0.25 * r_notch * math.cos(math.radians(step / 2))) / (0.75 * math.cos(math.radians(0.35 * step)))
    pts = []
    for i in range(k):
        a = phase + i * step
        a0, a1 = a - step / 2, a + step / 2
        arc = bezier(polar(r_notch, a0, cx, cy), polar(r_ctrl, a0 + 0.15 * step, cx, cy),
                     polar(r_ctrl, a1 - 0.15 * step, cx, cy), polar(r_notch, a1, cx, cy), n)
        pts += arc[:-1]
    return poly(pts)


def ribbon(points, w0, w1):
    """A cheap tapered band along the points (flat ends)."""
    pts = np.array(points, float)
    d = np.gradient(pts, axis=0)
    d /= np.hypot(d[:, 0], d[:, 1])[:, None]
    nrm = np.stack([-d[:, 1], d[:, 0]], axis=1)
    w = np.linspace(w0, w1, len(pts))[:, None] / 2
    left = pts + nrm * w
    right = pts - nrm * w
    return poly([tuple(p) for p in left] + [tuple(p) for p in right[::-1]])


def leaf(base, tip, bulge):
    """A pointed leaf from base to tip; bulge widens it (negative bulges the other side)."""
    bx, by = base
    tx, ty = tip
    dx, dy = tx - bx, ty - by
    nx, ny = -dy, dx
    c1 = (bx + dx * 0.25 + nx * bulge, by + dy * 0.25 + ny * bulge)
    c2 = (bx + dx * 0.75 + nx * bulge, by + dy * 0.75 + ny * bulge)
    c3 = (bx + dx * 0.75 - nx * bulge, by + dy * 0.75 - ny * bulge)
    c4 = (bx + dx * 0.25 - nx * bulge, by + dy * 0.25 - ny * bulge)
    return poly(bezier(base, c1, c2, tip, 8)[:-1] + bezier(tip, c3, c4, base, 8)[:-1])


def build():
    notches = [-54 + 72 * i for i in range(5)]
    barbs = union(*[poly([polar(33.5, a), polar(19.0, a - 9), polar(19.0, a + 9)]) for a in notches])
    outer = scallop(17.5, 29.0, 5, -90, 8)
    seams = union(*[poly([polar(17.5, a), polar(11.0, a - 13), polar(11.0, a + 13)]) for a in notches])
    inner_back = scallop(11.5, 15.5, 5, -54, 7)
    inner = scallop(9.5, 13.2, 5, -54, 7)
    centre = circle(CX, CY, 6.4, 16)
    spiral = [polar(0.6 + 4.4 * t / (3 * math.pi), math.degrees(t) - 90) for t in np.linspace(0, 3 * math.pi, 11)]
    swirl = ribbon(spiral, 0.8, 2.4)

    stem = ribbon(bezier((50, 72), (47, 83), (53, 93), (50, 104), 8), 4.6, 3.4)
    leaf_l = leaf((49.5, 85), (23, 79), 0.30)
    leaf_r = leaf((51, 93), (76, 86), -0.30)
    ribs = union(ribbon([(48, 85), (35, 82), (25, 79.4)], 1.5, 0.3),
                 ribbon([(52.5, 93), (64, 89.6), (74, 86.5)], 1.5, 0.3))
    return [
        (GREEN, FIELD),
        (DARK, barbs),
        (GOLD, union(outer, stem, leaf_l, leaf_r)),
        (DARK, union(seams, inner_back, ribs)),
        (GOLD, inner),
        (DARK, centre),
        (GOLD, swirl),
    ]
