"""House Targaryen: a red three-headed dragon on a black field.

The dragon is displayed facing the viewer: two bat wings spread up and out behind it, three necks
fan out left / up / right from a compact body (each with a horned, open-jawed head in profile), and
clawed legs and a curled, barbed tail sit below. A thin gap of field separates heads from wings.
"""

import shapely

from sigil_kit import FIELD, bezier, diff, ellipse, mirror_x, poly, rotate, scale, taper, translate, union

BLACK = "#101010"
RED = "#C8161D"


def _place(g, x, y, angle, size):
    return translate(rotate(scale(g, size, size, origin=(0, 0)), angle, origin=(0, 0)), x, y)


def _head(x, y, angle, size=1.0, horn=(-5.5, -7)):
    """A horned dragon head in profile, snout along `angle` (degrees, y down), skull back at (x, y)."""
    skull = poly([
        (-2, -3), (0.5, -4.5), (4, -4.4), (5.5, -3.2), (12, -2.2), (13.5, -1), (13, 0.3),
        (7, 0.9),                                                     # mouth corner
        (12, 1.9), (11.5, 3.1), (5, 4.6), (0, 4.5), (-2, 2),          # lower jaw and throat
    ])
    horns = poly([(-1, -3), horn, (3.5, -4.4)])
    return _place(union(skull, horns), x, y, angle, size)


def _eye(x, y, angle, size=1.0):
    return _place(poly([(3.2, -2.4), (5.6, -2.0), (4, -1.0)]), x, y, angle, size)


def _wing():
    """Left wing: leading edge up from the shoulder to the wrist and tip, scalloped trailing edge."""
    lead = bezier((47, 53), (44, 41), (37, 28), (30, 15), n=8)
    tips = [(12, 9), (7.5, 22), (11, 31), (20, 37), (44, 50)]
    wrist = (31, 19)
    pts = lead + [tips[0]]
    for a, b in zip(tips, tips[1:]):
        mid = ((a[0] + b[0]) / 2, (a[1] + b[1]) / 2)
        ctrl = (mid[0] + (wrist[0] - mid[0]) * 0.3, mid[1] + (wrist[1] - mid[1]) * 0.3)
        pts += bezier(a, ctrl, b, n=6)[1:]
    return poly(pts)


def build():
    body = ellipse(50, 68, 10, 13, n=28)

    # right neck and head, mirrored for the left one
    side_neck = taper(bezier((54, 66), (61, 64), (63, 56), (68, 54), n=12), 8.5, 5.5)
    side = (67, 54, 5, 1.55)
    side_head = union(side_neck, _head(*side))
    # the middle neck rises; its head is built facing right, then mirrored to look up-left
    mid_neck = taper(bezier((50, 58), (50, 46), (46, 38), (49, 29), n=12), 8.5, 5.5)
    mid = (51, 28, -50, 1.5)
    heads = union(side_head, mirror_x(side_head), mid_neck, mirror_x(_head(*mid, horn=(-5.5, -6))))

    # wings sit behind the necks: cut a gap around heads and necks, drop leftover slivers
    wings = union(_wing(), mirror_x(_wing()))
    wings = diff(wings, shapely.simplify(heads.buffer(2.2, quad_segs=2), 0.4))
    wings = union(*[p for p in shapely.get_parts(wings) if p.area > 20])

    leg = union(
        taper([(56, 74), (62, 81), (59, 88)], 6, 4),
        poly([(56, 87), (63, 86), (67, 91), (62, 90), (62, 93), (59, 90), (56, 92)]),  # claws
    )
    # tail sweeps down, hooks left and curls back up, ending in a barb
    tail_path = (bezier((50, 79), (59, 88), (60, 104), (50, 106), n=12)
                 + bezier((50, 106), (42, 106), (41, 98), (47, 97), n=7)[1:])
    tail = union(taper(tail_path, 6, 2.2), poly([(45.5, 94), (53, 96), (46.5, 100)]))

    dragon = union(body, wings, heads, leg, mirror_x(leg), tail)
    eyes = union(_eye(*side), mirror_x(_eye(*side)), mirror_x(_eye(*mid)))
    return [
        (BLACK, FIELD),
        (RED, dragon),
        (BLACK, eyes),
    ]
