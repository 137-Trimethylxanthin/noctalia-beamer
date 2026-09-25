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

print("== dimming ==")
check("premultiplied black", spot.dark(128) == bytes((0, 0, 0, 128)))
check("white over nothing is the glow", spot.over(153, 0) == spot.pixel(153))
check("nothing over black is the dimming", spot.over(0, 128) == spot.dark(128))
check("white over black: color is the white, alpha adds up", spot.over(100, 128) == bytes((100, 100, 100, 100 + round(128 * 155 / 255))))
check("clear background", spot.background(0, 3) == spot.CLEAR * 3)
check("dimmed background", spot.background(128, 3) == spot.dark(128) * 3)
half, rows = spot.spotlight(30, 15, 0, 128)
middle = rows[45][45 * spot.BPP : 46 * spot.BPP]
check("a hole in the middle", middle == spot.CLEAR, middle)
check("dimmed in the corner, like the background", rows[0][:4] == spot.dark(128), rows[0][:4])
ramp = rows[45][(45 + 37) * spot.BPP + 3]
check("the hole's edge fades", 0 < ramp < 128, ramp)
check("dimming only: never white", all(r[i] == 0 for r in rows for i in range(0, len(r), 4)))
half, rows = spot.spotlight(30, 15, 153, 128)
check("both: white in the middle", rows[45][45 * spot.BPP : 46 * spot.BPP] == spot.pixel(153))
check("both: dimmed in the corner", rows[0][:4] == spot.dark(128))
check("both: symmetric left-right", all(r == b"".join(r[i:i + 4] for i in range(len(r) - 4, -4, -4)) for r in rows))
check("both: symmetric top-bottom", rows == rows[::-1])
check("glow is the spotlight without dimming", spot.glow(12, 5, 200) == spot.spotlight(12, 5, 200, 0))
t = time.perf_counter(); spot.spotlight(400, 300, 255, 230); took = time.perf_counter() - t
check("largest spotlight builds in under a second", took < 1.0, f"{took:.2f}s")

w, h = 40, 30
dim_row = spot.background(128, w)
buf = bytearray(dim_row * h)
half, rows = spot.spotlight(4, 2, 0, 128)
placed = spot.clip(20, 15, half, w, h)
spot.stamp(buf, w, rows, placed)
check("hole at the cursor", alpha_at(buf, w, 20, 15) == 0)
check("dimmed beside it", alpha_at(buf, w, 2, 2) == 128)
spot.fill(buf, w, h, placed[:4], dim_row)
check("old square dimmed again", bytes(buf) == dim_row * h)

print("== closing in ==")
w, h = 200, 120
frame = spot.spotlight_frame(w, h, 100, 60, 30, 10, 0, 160)
check("a whole buffer", len(frame) == w * h * spot.BPP)
check("clear in the middle", alpha_at(frame, w, 100, 60) == 0)
check("dimmed far off", alpha_at(frame, w, 5, 5) == 160 and alpha_at(frame, w, 195, 110) == 160)
edge = alpha_at(frame, w, 100 + 35, 60)
check("soft on the edge", 0 < edge < 160, edge)
stamp_half, stamp_rows = spot.spotlight(30, 10, 0, 160)
same = True
for yy in range(20, 101, 7):
    for xx in range(60, 141, 7):
        sx, sy = xx - (100 - stamp_half), yy - (60 - stamp_half)
        want = stamp_rows[sy][sx * 4 + 3]
        same &= abs(alpha_at(frame, w, xx, yy) - want) <= 1
check("the same spot the stamp draws", same)
big = spot.spotlight_frame(w, h, 100, 60, 400, 0, 0, 160)
check("bigger than the screen: nothing dimmed", all(alpha_at(big, w, xx, yy) == 0 for xx in (0, 199) for yy in (0, 119)))
check("with the lift, the spot is faintly white", spot.spotlight_frame(w, h, 100, 60, 30, 10, 46, 160)[(60 * w + 100) * 4:(60 * w + 100) * 4 + 4] == spot.pixel(46))
check("off the screen's edge", len(spot.spotlight_frame(w, h, -50, 200, 30, 10, 0, 160)) == w * h * 4)
t = time.perf_counter()
for r in (1500, 900, 400, 120, 45):
    spot.spotlight_frame(1920, 1080, 960, 540, r, max(1, 15 * 30 / r), 46, 166)
took = (time.perf_counter() - t) / 5
check("a 1920x1080 frame in under 25 ms", took < 0.025, f"{took * 1000:.1f} ms")

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
