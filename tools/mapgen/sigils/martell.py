"""House Martell: a red sun pierced by a golden spear, on an orange field."""

from sigil_kit import FIELD, circle, poly, star, stroke, union

ORANGE = "#E8761A"
RED = "#C8161D"
GOLD = "#F2C230"


def build():
    sun = union(circle(50, 58, 19), star(50, 58, 31, 18, 16))
    shaft = stroke([(20, 102), (72, 34)], 5, cap="flat")
    # Leaf-shaped spearhead pointing up and to the right, with a short crossbar below it.
    head = poly([(68, 40), (70, 28), (84, 14), (80, 33), (72, 42)])
    guard = stroke([(63, 36), (75, 46)], 4.5, cap="round")
    butt = stroke([(17, 106), (23, 98)], 8, cap="round")
    return [
        (ORANGE, FIELD),
        (RED, sun),
        (GOLD, union(shaft, head, guard, butt)),
    ]
