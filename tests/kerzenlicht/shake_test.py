# /// script
# requires-python = ">=3.11"
# dependencies = []
# ///
"""Telling a shake from ordinary mouse movement: back and forth, fast, counts;
moving across the screen, a slow wobble, one flick or a pause does not.
Wayland is not involved; see run.sh."""

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "kerzenlicht" / "lib"))
import shake  # noqa: E402

fails = 0


def check(name, cond, extra=None):
    global fails
    if cond:
        print("  ok   " + name)
    else:
        fails += 1
        print("  FAIL " + name + (f"  -> {extra}" if extra is not None else ""))


def run(points, detector=None):
    """Feeds (t, x, y) points; returns the times a shake was seen."""
    detector = detector or shake.Shake()
    return [t for t, x, y in points if detector.feed(t, x, y)]


def strokes(xs, start=0.0, step=0.01, y=500, per=10):
    """Moves through each x in turn, `per` samples per stroke, `step` s apart."""
    points, t, x = [], start, xs[0]
    for target in xs[1:]:
        for i in range(1, per + 1):
            t += step
            points.append((t, x + (target - x) * i / per, y))
        x = target
    return points


print("== shakes ==")
# Six times left and right, 0.1 s a stroke, 200 px each way.
fast = strokes([500, 700] * 6 + [500])
hits = run(fast)
check("six times left and right, fast", len(hits) == 1, hits)
check("seen on the eleventh turn, not before", hits and abs(hits[0] - fast[-1][0]) < 0.11, hits)
vertical = [(t, 500, x) for t, x, _ in fast]
check("up and down counts too", len(run(vertical)) == 1)
long = strokes([500, 700] * 11 + [500])  # 22 strokes, 21 turns: counted after 11, then again only once the turns are fresh
check("shaking on counts again after another eleven turns", len(run(long)) == 1, run(long))

print("== not shakes ==")
check("five times left and right is not enough", run(strokes([500, 700] * 5 + [500])) == [])
check("across the screen", run(strokes([100, 1800])) == [])
check("across with a wobble", run([(i * 0.01, 100 + i * 8, 500 + (20 if i % 4 < 2 else -20)) for i in range(200)]) == [])
check("strokes too short (80 px)", run(strokes([500, 580] * 8)) == [])
check("one flick there and back", run(strokes([500, 900, 500])) == [])
check("too slow", run(strokes([500, 700] * 7, step=0.03)) == [])
paused = strokes([500, 700] * 4) + strokes([500, 700] * 4, start=5.0)
check("two halves with a pause between", run(paused) == [])

print("== stopping ==")
d = shake.Shake()
run(fast, d)
last = fast[-1][0]
check("still shaking right after a turn", d.still(last))
check("over 0.3 s after the last turn", not d.still(last + 0.35))

print("== reset ==")
d = shake.Shake()
half = strokes([500, 700, 500, 700, 500])
run(half, d)
d.reset()
rest = strokes([500, 700, 500, 700], start=half[-1][0])
check("a jump to another output starts over", run(rest, d) == [])

print()
if fails:
    print(f"{fails} failed")
    sys.exit(1)
print("all passed")
