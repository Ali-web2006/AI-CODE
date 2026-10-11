"""House Tully: a silver trout leaping, on a field per fess wavy blue and red."""

import math

import numpy as np

from sigil_kit import FIELD, bezier, circle, poly, taper, union

BLUE = "#1F3FB8"
RED = "#B5141E"
SILVER = "#D6D9DE"
SHADE = "#9EA5AE"


def _wave_top():
    """Everything above the gently wavy line of division near y = 60."""
    xs = np.linspace(0, 100, 26)
    ys = 60 + 3.2 * np.sin((xs - 8) / 86 * 3 * math.pi)
    return poly([(0, 0), (100, 0)] + [(x, y) for x, y in zip(xs[::-1], ys[::-1])])


class _Spine:
    """A curved centre line with unit tangents and unit normals (pointing to the belly)."""

    def __init__(self, points):
        self.p = np.array(points, float)
        tan = np.gradient(self.p, axis=0)
        self.d = tan / np.hypot(*tan.T)[:, None]
        self.n = np.stack([-self.d[:, 1], self.d[:, 0]], axis=1)

    def at(self, t):
        i = min(len(self.p) - 1, int(round(t * (len(self.p) - 1))))
        return self.p[i], self.d[i], self.n[i]


def _fin(spine, half_width, t0, t1, side, height, sweep):
    """A swept-back fin rooted inside the body between t0 and t1 (side +1 belly, -1 back)."""
    a, _, na = spine.at(t0)
    b, d, nb = spine.at(t1)
    wa, wb = half_width(t0), half_width(t1)
    root0 = a + side * na * (wa - 2.5)
    root1 = b + side * nb * (wb - 2.5)
    tip = b + side * nb * (wb + height) + d * sweep
    lead = bezier(root0, a + side * na * (wa + height * 0.9), tip, None, 6)
    return poly([tuple(q) for q in lead] + [tuple(root1)])


def build():
    spine = _Spine(bezier((22, 17), (38, 38), (70, 46), (58, 80), 18))
    keys_t = [0, 0.03, 0.1, 0.24, 0.4, 0.6, 0.82, 1.0]
    keys_w = [0.6, 3.4, 7.2, 10.4, 10.8, 8.6, 5.0, 2.9]

    def half_width(t):
        return float(np.interp(t, keys_t, keys_w))

    w = np.array([half_width(t) for t in np.linspace(0, 1, len(spine.p))])
    back = spine.p - spine.n * w[:, None]
    belly = spine.p + spine.n * w[:, None]
    body = poly([tuple(q) for q in back] + [tuple(q) for q in belly[::-1]])

    # forked tail, flicked a little downwards, its root tucked into the end of the body
    T, ds, ns = spine.at(1.0)
    r0, r1 = T - ds * 3 - ns * 2.9, T - ds * 3 + ns * 2.9
    d = ds + (0.2, 0.35)
    d = d / np.hypot(*d)
    n = np.array([-d[1], d[0]])
    up, lo, notch = T + d * 15 - n * 12.5, T + d * 15 + n * 12.5, T + d * 7.5
    tail = poly(bezier(r0, T + d * 6 - n * 6, up, None, 6)
                + [tuple(notch)] + bezier(lo, T + d * 6 + n * 6, r1, None, 6))

    fins = union(
        _fin(spine, half_width, 0.34, 0.56, -1, 8, 5),     # dorsal
        _fin(spine, half_width, 0.20, 0.27, +1, 7, 5),     # pectoral
        _fin(spine, half_width, 0.52, 0.60, +1, 6, 4),     # pelvic
        _fin(spine, half_width, 0.74, 0.82, +1, 6, 4),     # anal
    )

    p, d, n = spine.at(0.17)
    gill = taper(bezier(p - n * 7, p + d * 3.5, p + n * 7, None, 8), 1.8, 1.0)
    p, d, n = spine.at(0.0)
    mouth = taper([tuple(p + d * 0.3 + n * 0.3), tuple(p + d * 7.5 + n * 2.2)], 1.4, 0.7)
    p, d, n = spine.at(0.06)
    eye = circle(*(p - n * 1.8), 2.2, n=16)
    spots = []
    for t, k in ((0.30, 5.5), (0.42, 3.0), (0.50, 6.5), (0.62, 3.5), (0.70, 5.5)):
        p, d, n = spine.at(t)
        spots.append(circle(*(p - n * k), 1.1, n=8))          # trout speckles along the back

    fish = union(body, tail).difference(eye)
    return [
        (RED, FIELD),
        (BLUE, FIELD.intersection(_wave_top())),
        (SHADE, fins),
        (SILVER, fish),
        (SHADE, union(gill, mouth, *spots)),
    ]
