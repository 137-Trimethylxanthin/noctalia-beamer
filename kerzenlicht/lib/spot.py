"""The flashlight's pixels, without Wayland: pure byte arithmetic, so the tests
can run it anywhere.

The overlay is one ARGB8888 buffer per output, filled with a background (fully
transparent for the glow, a sheet of translucent black to dim the screen), with
a round stamp where the cursor is: white glow, a hole in the dimming, or both.
Moving the light never redraws the whole screen: the stamp's old square gets
the background again and the stamp goes on at its new square, row by row. Both
squares are what the compositor is told to repaint.

ARGB8888 is little-endian B, G, R, A in memory and premultiplied, so white at
opacity a is (a, a, a, a), black at opacity a is (0, 0, 0, a), and a cleared
pixel is all zeros.
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


def dark(alpha: int) -> bytes:
    """One premultiplied black pixel: the dimming."""
    a = max(0, min(255, alpha))
    return bytes((0, 0, 0, a))


def over(white: int, black: int) -> bytes:
    """White at opacity `white` composited over black at opacity `black`,
    premultiplied: the glow lying on top of the dimming."""
    w = max(0, min(255, white))
    b = max(0, min(255, black))
    a = w + round(b * (255 - w) / 255)
    return bytes((w, w, w, a))


def background(dim: int, width: int) -> bytes:
    """One row of the buffer outside the stamp: clear, or dimmed."""
    return (dark(dim) if dim > 0 else CLEAR) * width


def spotlight(radius: int, softness: int, glow_alpha: int, dim_alpha: int) -> tuple[int, list[bytes]]:
    """The stamp: a square of side 2 * (radius + softness). Inside `radius` it
    is white at `glow_alpha`, and the dimming is gone; over the next
    `softness` pixels the white fades out and the dimming (black at
    `dim_alpha`) fades in, so the corners are exactly the background.
    Returns the half size and the rows, top to bottom.

    Only one quarter is computed: the other three are the same pixels in
    mirrored order, since the stamp is round."""
    half = max(1, radius + softness)
    cache: dict[tuple[int, int], bytes] = {}
    top = []
    for y in range(half):
        dy = y + 0.5 - half
        left = []
        for x in range(half):
            dx = x + 0.5 - half
            inside = 1.0 - smoothstep(radius, radius + softness, math.hypot(dx, dy))
            key = (round(glow_alpha * inside), round(dim_alpha * (1.0 - inside)))
            px = cache.get(key)
            if px is None:
                px = cache[key] = over(*key)
            left.append(px)
        top.append(b"".join(left) + b"".join(reversed(left)))
    return half, top + top[::-1]


def glow(radius: int, softness: int, alpha: int) -> tuple[int, list[bytes]]:
    """The plain glow: white at `alpha` inside `radius`, fading out over
    `softness` pixels, clear in the corners."""
    return spotlight(radius, softness, alpha, 0)


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
    """Paints rect (x, y, w, h) with the start of `row`, a run of background
    pixels."""
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


def spotlight_frame(width: int, height: int, cx: float, cy: float, radius: float, softness: float,
                    white: int, dim: int) -> bytes:
    """One whole buffer: dimmed, with a round spot of `radius` at (cx, cy),
    fading over `softness` pixels. For the closing-in animation, where the
    spot starts bigger than the screen: a stamp that size would take seconds
    to build, but a row is only runs of equal pixels with a short soft edge
    at each end, so it is sliced together instead, and only the edge pixels
    are worked out one by one."""
    outer = radius + max(0.0, softness)
    dim_row = dark(dim) * width
    inside = pixel(white) if white > 0 else CLEAR
    cache: dict[tuple[int, int], bytes] = {}
    rows = []
    for y in range(height):
        dy = y + 0.5 - cy
        if abs(dy) >= outer:
            rows.append(dim_row)
            continue
        xo = math.sqrt(outer * outer - dy * dy)
        lo = max(0, min(width, math.floor(cx - xo)))
        ro = max(lo, min(width, math.ceil(cx + xo)))
        if abs(dy) < radius:
            xi = math.sqrt(radius * radius - dy * dy)
            li = max(lo, min(ro, math.ceil(cx - xi)))
            ri = max(li, min(ro, math.floor(cx + xi)))
        else:
            li = ri = max(lo, min(ro, round(cx)))

        def edge(a, b):
            out = []
            for x in range(a, b):
                t = 1.0 - smoothstep(radius, outer, math.hypot(x + 0.5 - cx, dy))
                key = (round(white * t), round(dim * (1.0 - t)))
                px = cache.get(key)
                if px is None:
                    px = cache[key] = over(*key)
                out.append(px)
            return b"".join(out)

        rows.append(dim_row[: lo * BPP] + edge(lo, li) + inside * (ri - li) + edge(ri, ro) + dim_row[ro * BPP:])
    return b"".join(rows)


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
