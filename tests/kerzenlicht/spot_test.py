# /// script
# requires-python = ">=3.11"
# dependencies = []
# ///
"""The flashlight's pixel math: the glow stamp, clipping at the edges, and
clearing the old square again. Wayland is not involved; see run.sh."""

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "kerzenlicht" / "lib"))
import spot  # noqa: E402

fails = 0


def check(name, cond, extra=None):
    global fails
    if cond:
        print("  ok   " + name)
    else:
        fails += 1
        print("  FAIL " + name + (f"  -> {extra}" if extra is not None else ""))


def alpha_at(buf, width, x, y):
    return buf[(y * width + x) * spot.BPP + 3]


print("== pixels ==")
check("premultiplied white", spot.pixel(200) == bytes((200, 200, 200, 200)))
check("clear is all zeros", spot.CLEAR == bytes(4))
check("clamped", spot.pixel(300)[3] == 255 and spot.pixel(-5)[3] == 0)
check("smoothstep ends", spot.smoothstep(1, 2, 0) == 0 and spot.smoothstep(1, 2, 3) == 1)
check("smoothstep middle", abs(spot.smoothstep(0, 2, 1) - 0.5) < 1e-9)
check("hard edge", spot.smoothstep(5, 5, 4.9) == 0 and spot.smoothstep(5, 5, 5) == 1)

print("== glow ==")
half, rows = spot.glow(30, 15, 153)
check("size is radius + softness", half == 45 and len(rows) == 90 and len(rows[0]) == 90 * spot.BPP)
center = rows[45][45 * spot.BPP + 3]
check("full strength in the middle", center == 153, center)
check("clear in the corner", rows[0][3] == 0, rows[0][3])
edge = rows[45][(45 + 37) * spot.BPP + 3]
check("fading on the soft edge", 0 < edge < 153, edge)
check("white, not gray: color equals alpha", rows[45][45 * spot.BPP : 45 * spot.BPP + 4] == spot.pixel(153))
check("symmetric left-right", all(r == b"".join(r[i:i + 4] for i in range(len(r) - 4, -4, -4)) for r in rows))
check("symmetric top-bottom", rows == rows[::-1])
import math, time
ref_ok = True
for y in (0, 17, 44, 45, 60, 89):
    for x in (0, 12, 44, 45, 70, 89):
        d = math.hypot(x + 0.5 - 45, y + 0.5 - 45)
        want = round(153 * (1 - spot.smoothstep(30, 45, d)))
        ref_ok &= rows[y][x * 4 + 3] == want
check("mirrored quarter matches the full formula", ref_ok)
t = time.perf_counter(); spot.glow(400, 300, 255); took = time.perf_counter() - t
check("largest glow builds in under a second", took < 1.0, f"{took:.2f}s")
half2, rows2 = spot.glow(10, 0, 255)
check("no softness: sharp", rows2[10][10 * spot.BPP + 3] == 255 and rows2[0][3] == 0)

print("== clip ==")
check("inside", spot.clip(100, 100, 10, 200, 200) == (90, 90, 20, 20, 0, 0))
check("left edge", spot.clip(3, 100, 10, 200, 200) == (0, 90, 13, 20, 7, 0))
check("bottom right corner", spot.clip(195, 198, 10, 200, 200) == (185, 188, 15, 12, 0, 0))
check("off the buffer", spot.clip(-50, 100, 10, 200, 200) is None)

print("== stamp and fill ==")
w, h = 64, 48
clear_row = spot.CLEAR * w
buf = bytearray(clear_row * h)
half, rows = spot.glow(5, 2, 255)
placed = spot.clip(10, 10, half, w, h)
spot.stamp(buf, w, rows, placed)
check("glow at the cursor", alpha_at(buf, w, 10, 10) == 255)
check("clear beside it", alpha_at(buf, w, 30, 30) == 0)
spot.fill(buf, w, h, placed[:4], clear_row)
check("old square clear again", bytes(buf) == clear_row * h)
edge = spot.clip(0, 47, half, w, h)
spot.stamp(buf, w, rows, edge)
check("clipped stamp at the corner", alpha_at(buf, w, 0, 47) == 255 and len(buf) == w * h * spot.BPP)

print("== coordinates ==")
check("logical kept", spot.to_local(617, 876, 2048, 1280, False, 1.25) == (617, 876))
check("physical scaled down", spot.to_local(771, 1095, 2048, 1280, True, 1.25) == (617, 876))
check("well past the edge means physical", spot.looks_physical(2500, 10, 2048, 1280, 1.25))
check("inside means nothing", not spot.looks_physical(2000, 10, 2048, 1280, 1.25))
check("a cursor image over the edge means nothing", not spot.looks_physical(2080, 10, 2048, 1280, 1.25))
check("scale 1 never physical", not spot.looks_physical(5000, 10, 1920, 1080, 1.0))

print()
if fails:
    print(f"{fails} failed")
    sys.exit(1)
print("all passed")
