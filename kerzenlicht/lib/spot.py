"""The flashlight's pixels, without Wayland: pure byte arithmetic, so the tests
can run it anywhere.

The overlay is one ARGB8888 buffer per output, fully transparent, with a
round white glow stamped where the cursor is. Moving the light never redraws
the whole screen: the glow's old square is cleared again and the glow is
stamped at its new square, row by row. Both squares are what the compositor is
told to repaint.

ARGB8888 is little-endian B, G, R, A in memory and premultiplied, so white at
opacity a is (a, a, a, a), and a cleared pixel is all zeros.
"""

from __future__ import annotations

import math

BPP = 4
CLEAR = bytes(BPP)


def pixel(alpha: int) -> bytes:
    """One premultiplied white pixel."""
    a = max(0, min(255, alpha))
    return bytes((a, a, a, a))


def smoothstep(edge0: float, edge1: float, x: float) -> float:
    if edge1 <= edge0:
        return 0.0 if x < edge0 else 1.0
    t = max(0.0, min(1.0, (x - edge0) / (edge1 - edge0)))
    return t * t * (3.0 - 2.0 * t)


def glow(radius: int, softness: int, alpha: int) -> tuple[int, list[bytes]]:
    """The stamp: a square of side 2 * (radius + softness), white at `alpha`
    inside `radius`, fading out over `softness` pixels, clear in the corners.
    Returns the half size and the rows, top to bottom.

    Only one quarter is computed. A pixel is (a, a, a, a), so reversing a
    row's bytes mirrors it exactly, and the bottom half is the top half's rows
    in reverse order."""
    half = max(1, radius + softness)
    top = []
    for y in range(half):
        dy = y + 0.5 - half
        left = bytearray()
        for x in range(half):
            dx = x + 0.5 - half
            d = math.hypot(dx, dy)
            left += pixel(round(alpha * (1.0 - smoothstep(radius, radius + softness, d))))
        top.append(bytes(left) + bytes(left[::-1]))
    return half, top + top[::-1]


def clip(cx: int, cy: int, half: int, width: int, height: int):
    """The stamp's square centered on (cx, cy), cut to the buffer.

    Returns (x, y, w, h, sx, sy): where it lands, and where in the stamp that
    part starts; None when none of it is on the buffer."""
    x0, y0 = cx - half, cy - half
    x1, y1 = x0 + 2 * half, y0 + 2 * half
    lx0, ly0 = max(0, x0), max(0, y0)
    lx1, ly1 = min(width, x1), min(height, y1)
    if lx1 <= lx0 or ly1 <= ly0:
        return None
    return lx0, ly0, lx1 - lx0, ly1 - ly0, lx0 - x0, ly0 - y0


def fill(buf, width: int, height: int, rect, row: bytes) -> None:
    """Paints rect (x, y, w, h) with the start of `row`, a run of clear pixels."""
    x, y, w, h = rect
    stride = width * BPP
    run = row[: w * BPP]
    for yy in range(y, y + h):
        start = yy * stride + x * BPP
        buf[start : start + w * BPP] = run


def stamp(buf, width: int, rows: list[bytes], placed) -> None:
    """Copies the part of the stamp `clip` picked onto the buffer."""
    x, y, w, h, sx, sy = placed
    stride = width * BPP
    for i in range(h):
        start = (y + i) * stride + x * BPP
        buf[start : start + w * BPP] = rows[sy + i][sx * BPP : (sx + w) * BPP]


def to_local(x: float, y: float, width: int, height: int, physical: bool, factor: float):
    """A cursor position in the overlay's own (logical) pixels.

    Hyprland reports cursor-session positions in logical pixels; a compositor
    that follows the letter of ext-image-copy-capture might send buffer
    (physical) pixels instead. `physical` says which, `factor` is physical /
    logical for the output."""
    if physical and factor > 0:
        x, y = x / factor, y / factor
    return round(x), round(y)


# The cursor image may hang over an output's edge while the position is still
# reported for that output, so a little overshoot proves nothing.
OVERSHOOT = 256


def looks_physical(x: float, y: float, width: int, height: int, factor: float) -> bool:
    """A position well past the logical edge can only be a physical one."""
    return factor > 1.01 and (x > width + OVERSHOOT or y > height + OVERSHOOT)
