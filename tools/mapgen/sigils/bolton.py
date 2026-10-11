"""House Bolton: a flayed man, red and hung upside-down with limbs spread, on a darker pink saltire on a pink field."""

from sigil_kit import FIELD, circle, ellipse, poly, stroke, taper, union

PINK = "#E8A3A8"
SALTIRE = "#D98A91"
RED = "#A3161C"


def build():
    saltire = union(
        stroke([(2, 2), (98, 112)], 20, cap="flat"),
        stroke([(98, 2), (2, 112)], 20, cap="flat"),
    )
    # The figure hangs head-down: hips at the top, shoulders and head below.
    torso = poly([(40.5, 37), (59.5, 37), (57, 52), (63, 66), (58.5, 73), (41.5, 73), (37, 66), (43, 52)])
    neck = poly([(46, 70), (54, 70), (53.5, 77), (46.5, 77)])
    head = circle(50, 84, 9.5, n=24)
    legs = union(
        taper([(45, 41), (32, 27), (22, 15)], 14, 7.5),
        taper([(55, 41), (68, 27), (78, 15)], 14, 7.5),
        ellipse(19.5, 13, 6, 3.6, 40, n=12),         # feet, soles up
        ellipse(80.5, 13, 6, 3.6, -40, n=12),
    )
    arms = union(
        taper([(42, 65), (33, 76), (25, 86)], 11, 6.5),
        taper([(58, 65), (67, 76), (75, 86)], 11, 6.5),
        circle(23.5, 88, 5, n=12),                   # hands
        circle(76.5, 88, 5, n=12),
    )
    return [
        (PINK, FIELD),
        (SALTIRE, saltire),
        (RED, union(torso, neck, head, legs, arms)),
    ]
