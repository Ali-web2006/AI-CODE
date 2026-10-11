"""House Arryn: a white crescent moon and falcon on a sky-blue field."""

import math

from sigil_kit import FIELD, circle, diff, ellipse, mirror_x, poly, union

BLUE = "#4FB7E8"
WHITE = "#FFFFFF"
GREY = "#C9DCE8"

SHOULDER = (43.5, 57.0)
WRIST = (26.0, 30.5)
# Dexter wing feathers, wrist to shoulder: (position along the arm, angle, length, half width).
WING = [(1.0, 224, 18, 2.8), (0.82, 208, 19.5, 3.0), (0.64, 192, 18.5, 3.2), (0.46, 176, 17, 3.4),
        (0.28, 160, 15, 3.6), (0.10, 145, 13.5, 3.8)]


def feather(origin, angle, length, half_w, sweep=0.25):
    """A long feather with a swept tip, from origin outwards along angle (degrees, y down)."""
    a = math.radians(angle)
    ux, uy = math.cos(a), math.sin(a)
    vx, vy = -uy, ux
    local = [(0, -half_w), (length - half_w * 1.4, -half_w), (length - half_w * 0.2, -half_w * 0.45),
             (length, sweep * half_w), (length - half_w * (1.25 - 0.6 * sweep), half_w), (0, half_w)]
    ox, oy = origin
    return poly([(ox + u * ux + v * vx, oy + u * uy + v * vy) for u, v in local])


def on_arm(t):
    sx, sy = SHOULDER
    wx, wy = WRIST
    return (sx + t * (wx - sx), sy + t * (wy - sy))


def wing():
    """The dexter (viewer's left) wing, raised: feathers hang outwards from the arm, longest at the wrist."""
    sx, sy = SHOULDER
    wx, wy = WRIST
    feathers = [feather(on_arm(t), a, l, w) for t, a, l, w in WING]
    arm = poly([(sx + 2, sy - 3), (wx + 2, wy - 2), (wx - 3, wy + 1), (wx - 4, wy + 8), (sx - 10, sy + 6),
                (sx + 2, sy + 9)])
    return union(arm, *feathers)


def wedge(origin, angle, r0, r1, width):
    """A thin sliver along angle from r0 (a point) to r1 (width wide): a feather parting line."""
    a = math.radians(angle)
    ux, uy = math.cos(a), math.sin(a)
    ox, oy = origin
    h = width / 2
    return poly([(ox + r0 * ux, oy + r0 * uy), (ox + r1 * ux - h * uy, oy + r1 * uy + h * ux),
                 (ox + r1 * ux + h * uy, oy + r1 * uy - h * ux)])


def wing_lines():
    """Parting lines running in from the gaps between the dexter wing's feathers."""
    lines = []
    for (t0, a0, l0, _), (t1, a1, l1, _) in zip(WING, WING[1:]):
        lines.append(wedge(on_arm((t0 + t1) / 2), (a0 + a1) / 2, 3.5, min(l0, l1) * 0.62, 1.0))
    return union(*lines)


def build():
    moon = diff(circle(50, 19.5, 18, 32), circle(50, 12.5, 16.5, 32))

    head = circle(51, 44.5, 5.6, 16)
    beak = poly([(48.5, 39.7), (44.5, 40.2), (41.5, 41.6), (39.5, 43.8), (38.8, 46.6), (39.6, 49.8), (40.8, 47.8),
                 (42.4, 46.8), (43.8, 48.0), (47.0, 49.2)])
    profile = union(head, beak)
    body = ellipse(50, 64, 8.4, 14.5, n=20)
    neck = ellipse(50, 52, 6.0, 7.0, n=16)
    fan = ((72, 28), (81, 29.5), (90, 30), (99, 29.5), (108, 28))
    tail = union(*[feather((50, 74), a, l, 3.4, 0.0) for a, l in fan])
    left = wing()
    wings = diff(union(left, mirror_x(left)), profile.buffer(1.5, quad_segs=3))
    falcon = union(profile, neck, body, tail, wings)
    eye = poly([(46.9, 42.4), (50.6, 43.0), (50.0, 44.7), (48.5, 45.2), (47.3, 44.3)])

    tail_lines = [wedge((50, 74), 76.5 + 9 * i, 13, 25, 0.8) for i in range(4)]
    details = union(wing_lines(), mirror_x(wing_lines()), *tail_lines)

    return [
        (BLUE, FIELD),
        (WHITE, diff(moon, falcon.buffer(1.8, quad_segs=3))),
        (WHITE, diff(falcon, eye)),
        (GREY, details),
    ]
