"""House Stark: a grey direwolf's head, erased, facing dexter, on a white field."""

from sigil_kit import FIELD, bezier, ellipse, poly, scale, taper, translate, union

WHITE = "#F4F4F4"
GREY = "#7D7D7D"
DARK = "#4A4A4A"


def _place(geom):
    """The head is drawn large and then shrunk into the middle of the field."""
    return translate(scale(geom, 0.86, origin=(50, 56)), 0, 2.5)


def build():
    outline = (
        [(11, 50)]
        + bezier((11, 50), (14, 46.5), (28, 44), (39, 38), 8)[1:]      # muzzle bridge
        + bezier((39, 38), (44, 35), (46, 30), (49, 26), 5)[1:]        # stop and forehead
        + [(55, 9), (62, 24), (66, 25), (75, 10), (78, 30)]            # ears
        + bezier((78, 30), (83, 36), (85, 42), (86, 48), 5)[1:]        # back of the skull
        + [(84, 54), (89, 60), (86, 64), (90, 71), (87, 75), (89, 83),  # mane down the nape
           (84, 86)]
        + [(80, 95), (75, 88), (70, 99), (65, 90), (59, 100), (55, 90),  # erased (torn) edge
           (49, 96), (48, 86)]
        + [(42, 87), (44, 80), (38, 79), (41, 73), (36, 70)]           # ruff under the jaw
        + bezier((36, 70), (28, 69), (22, 68), (17, 66), 5)[1:]        # underside of the jaw
        + [(16, 63), (35, 59.5), (12, 57)]                             # open mouth
        + bezier((12, 57), (10, 55), (10, 52), None, 3)[1:-1]
    )
    wolf = poly(outline)
    eye = poly([(38.5, 45.5), (42.5, 41.5), (49, 40), (45.5, 44)])
    nose = ellipse(12.8, 51.5, 3.2, 3.0, n=16)
    mouth = poly([(16.5, 63.2), (35, 59.5), (13, 57.2)])
    cheek = taper(bezier((35, 60), (44, 59), (50, 63), (54, 71), 6), 2.0, 0.6)
    fur = union(                                                     # locks of the mane
        taper(bezier((58, 47), (65, 51), (69, 58), (69, 66), 7), 2.4, 0.5),
        taper(bezier((58, 67), (63, 70), (66, 76), (65, 83), 7), 2.4, 0.5),
        taper(bezier((71, 62), (77, 66), (80, 72), (80, 80), 7), 2.4, 0.5),
    )
    fang = poly([(20, 57.6), (23.5, 58.1), (21.5, 61.5)])
    inner_ear = poly([(55, 15), (59.5, 25), (52, 28)])
    return [
        (WHITE, FIELD),
        (GREY, _place(wolf)),
        (DARK, _place(union(eye, nose, mouth, cheek, inner_ear, fur))),
        (WHITE, _place(fang)),
    ]
