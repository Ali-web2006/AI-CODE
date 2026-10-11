"""House Frey: the Twins, two grey towers joined by an arched bridge over the river, on a dark blue field."""

import math

import numpy as np

from sigil_kit import FIELD, circle, diff, poly, rect, union

BLUE = "#1F3A6B"
WATER = "#3E64A3"
STONE = "#B9BEC4"
SHADOW = "#8C939B"


def _water():
    """Everything below a gentle wavy line near y = 88."""
    xs = np.linspace(4, 96, 19)
    ys = 88 + 2.0 * np.sin((xs - 7) / 86 * 6 * math.pi)
    return poly([(x, y) for x, y in zip(xs, ys)] + [(96, 120), (4, 120)])


def _tower(cx):
    body = rect(cx - 8, 26, cx + 8, 100)
    parapet = rect(cx - 10, 20, cx + 10, 27)
    merlons = union(*(rect(cx - 10 + i * 7.67, 12, cx - 10 + i * 7.67 + 4.67, 21) for i in range(3)))
    return union(body, parapet, merlons)


def _arched(cx, top, bottom, half_w):
    """A round-headed opening (door or window)."""
    return union(rect(cx - half_w, top + half_w, cx + half_w, bottom), circle(cx, top + half_w, half_w, n=8))


def build():
    towers = union(_tower(25), _tower(75))
    # Segmental arch springing from the inner tower faces at y = 78, its crown at y = 66.
    r = 18.04
    span = union(circle(50, 66 + r, r, n=48), rect(33, 78, 67, 100))
    bridge = diff(rect(30, 57, 70, 90), span)
    ring = diff(circle(50, 66 + r, r + 3.2, n=48), circle(50, 66 + r, r, n=48), rect(0, 78.5, 100, 120))
    openings = union(
        _arched(25, 72, 100, 4.0), _arched(75, 72, 100, 4.0),      # gates
        _arched(25, 35, 48, 3.0), _arched(75, 35, 48, 3.0),        # windows
        rect(17, 27, 33, 30.5), rect(67, 27, 83, 30.5),            # shadow under the parapets
    )
    return [
        (BLUE, FIELD),
        (STONE, union(towers, bridge)),
        (SHADOW, union(openings, ring.intersection(rect(33, 0, 67, 120)))),
        (WATER, FIELD.intersection(_water())),
    ]
