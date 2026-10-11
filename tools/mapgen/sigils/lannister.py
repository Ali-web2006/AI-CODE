"""House Lannister: a golden lion rampant, facing dexter, on a crimson field."""

import math

from sigil_kit import FIELD, bezier, circle, ellipse, poly, scale, taper, translate, union

CRIMSON = "#A50E16"
GOLD = "#E9B526"
DARK_GOLD = "#B8860B"


def _flames(cx, cy, a0, a1, spikes, r_in, r_out, sweep, grow=0.0):
    """A fan of flame-like spikes from angle a0 to a1 (degrees, y down) around (cx, cy).

    Tips are swept sideways by `sweep`; `grow` lengthens the spikes that point right (backwards)."""
    pts = [(cx, cy)]
    step = (a1 - a0) / (spikes * 2)
    for i in range(spikes * 2 + 1):
        a = a0 + step * i
        if i % 2 == 0:
            pts.append((cx + r_in * math.cos(math.radians(a)), cy + r_in * math.sin(math.radians(a))))
            continue
        ro = r_out + grow * math.cos(math.radians(a))
        m = math.radians(a - step * 0.45)  # leading edge bulges outward
        rm = r_in + (ro - r_in) * 0.55
        pts.append((cx + rm * math.cos(m) + sweep * 0.4, cy + rm * math.sin(m)))
        t = math.radians(a + step * 0.35)
        pts.append((cx + ro * math.cos(t) + sweep, cy + ro * math.sin(t)))
    return poly(pts)


def _paw(x, y, angle, size=1.0):
    """A paw blob with three claws pointing along `angle` (degrees, y down)."""
    parts = [circle(x, y, 4.3 * size, n=16)]
    for spread in (-36, 0, 36):
        a = math.radians(angle + spread)
        b = math.radians(angle + spread + 90)
        tip = (x + 7.6 * size * math.cos(a), y + 7.6 * size * math.sin(a))
        bx, by = x + 3.2 * size * math.cos(a), y + 3.2 * size * math.sin(a)
        w = 1.9 * size
        parts.append(poly([(bx + w * math.cos(b), by + w * math.sin(b)), tip, (bx - w * math.cos(b), by - w * math.sin(b))]))
    return union(*parts)


def _tuft(ex, ey, dx, dy):
    """A three-tongued flame of hair at the tail's end (ex, ey), pointing along (dx, dy)."""
    n = math.hypot(dx, dy)
    dx, dy = dx / n, dy / n
    px, py = -dy, dx
    outline = [(-1, -3.4), (2, -6), (7, -10.5), (6.5, -4.5), (14, -1.5), (8, 3.5), (10, 9.5), (3, 6), (-1, 3.4)]
    return poly([(ex + u * dx + v * px, ey + u * dy + v * py) for u, v in outline])


def _place(geom):
    """Drawn a little oversize; shrink it to sit inside the field with a crimson margin."""
    return translate(scale(geom, 0.88, origin=(52, 58)), -1, -2)


def build():
    # head in profile, facing left, jaws open
    head = poly([
        (42, 14), (34, 12.5), (29, 14.5), (26, 17.5), (23.5, 19), (20.5, 20.5), (19, 23), (19.5, 26),
        (23, 27.5), (32, 29),
        (23, 31), (20.5, 32.5), (22, 35), (28, 36.5), (36, 37.5), (44, 34),
    ])
    fangs = union(poly([(21, 26.5), (24, 27.2), (22.2, 29.6)]), poly([(22, 31.5), (24.6, 30.8), (24, 28.8)]))
    mane = _flames(43, 31, -118, 140, 11, 13, 20, 4, 3.5)

    chest = ellipse(46, 51, 12, 10.5, 62, n=24)
    waist = taper([(46, 52), (56, 70)], 14, 11)
    haunch = ellipse(62, 80, 11, 13, -25, n=24)
    upper_arm = taper([(42, 47), (30, 50), (19, 42)], 10, 6.5)
    lower_arm = taper([(46, 58), (34, 66), (22, 64)], 10, 6.5)
    raised_leg = taper([(58, 82), (44, 90), (32, 88)], 13, 7)
    standing_leg = taper([(64, 84), (68, 96), (62, 104)], 13, 7)
    foot = taper([(63, 104), (52, 105)], 7, 6)
    tail_path = bezier((68, 74), (88, 82), (92, 60), (80, 52), 12) + bezier((80, 52), (70, 46), (74, 34), (84, 28), 12)[1:]
    tail = taper(tail_path, 7.5, 5)
    tuft = _tuft(83, 29, 0.55, -0.85)

    paws = union(
        _paw(17, 40, -150, 1.1), _paw(20, 63, -170, 1.1),
        _paw(30, 88, -175), _paw(50, 105, 180),
    )
    lion = union(head, fangs, mane, chest, waist, haunch, upper_arm, lower_arm, raised_leg, standing_leg, foot,
                 tail, tuft, paws)
    eye = poly([(24.5, 21.2), (29.5, 19.6), (28.6, 22.4)])
    cheek = taper(bezier((36, 15), (42, 21), (42, 30), (36, 36.5), 8), 1.2, 2.2)
    return [
        (CRIMSON, FIELD),
        (GOLD, _place(lion).simplify(0.3)),
        (DARK_GOLD, _place(cheek).simplify(0.3)),
        (CRIMSON, _place(eye)),
    ]
