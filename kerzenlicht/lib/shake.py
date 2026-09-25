"""Telling a shake from ordinary mouse movement, without Wayland: plain
arithmetic on cursor positions, so the tests can run it anywhere.

A shake is the pointer going back and forth, fast: several turns within a
short time, each after a real stroke. A turn only counts once the pointer has
come back `stroke` pixels from the furthest point it reached, so a hand that
wobbles while it moves across the screen is not a shake, and neither is a
single flick or a quick correction. Both axes are watched, each on its own, so
a vertical shake counts as well.

Once it is a shake, it lasts as long as the turns keep coming: `still` says
whether the last one was just now, so the light can go the moment the hand
stops.
"""

from __future__ import annotations

STROKE = 110  # logical px back from the far point before a turn counts
TURNS = 11  # six times left and right: twelve strokes, eleven turns between them
WINDOW = 2.0  # seconds they all have to fall within
HOLD = 0.3  # seconds without a turn after which a shake is over


class Axis:
    def __init__(self):
        self.reset()

    def reset(self):
        self.anchor = None  # where this stroke started, before a direction is known
        self.direction = 0
        self.far = 0.0  # the furthest point of the current stroke
        self.turns: list[float] = []
        self.last_turn = None

    def feed(self, t: float, v: float, stroke: float, window: float) -> int:
        """Takes one position; returns how many turns fall within `window`."""
        if self.anchor is None:
            self.anchor = v
            return 0
        if self.direction == 0:
            if abs(v - self.anchor) >= stroke:
                self.direction = 1 if v > self.anchor else -1
                self.far = v
            return 0
        if (v - self.far) * self.direction > 0:
            self.far = v  # still going the same way
        elif abs(self.far - v) >= stroke:
            self.turns.append(t)
            self.last_turn = t
            self.direction = -self.direction
            self.far = v
        self.turns = [turn for turn in self.turns if t - turn <= window]
        return len(self.turns)


class Shake:
    """Feed it the cursor's positions; it says when they make a shake."""

    def __init__(self, stroke: float = STROKE, turns: int = TURNS, window: float = WINDOW):
        self.stroke = stroke
        self.needed = turns
        self.window = window
        self.axes = (Axis(), Axis())
        self.last = None

    def reset(self):
        """Forget everything: the cursor jumped (to another output)."""
        for axis in self.axes:
            axis.reset()
        self.last = None

    def still(self, t: float, hold: float = HOLD) -> bool:
        """Whether the pointer turned within the last `hold` seconds."""
        turns = [axis.last_turn for axis in self.axes if axis.last_turn is not None]
        return bool(turns) and t - max(turns) <= hold

    def feed(self, t: float, x: float, y: float) -> bool:
        # A pause starts over: turns from before it are no part of this.
        if self.last is not None and t - self.last > self.window:
            self.reset()
        self.last = t
        hit = False
        for axis, v in zip(self.axes, (x, y)):
            if axis.feed(t, v, self.stroke, self.window) >= self.needed:
                hit = True
        if hit:
            # Each shake counts once; shaking on counts again after as many
            # more turns, which is what keeps the light up while it goes on.
            for axis in self.axes:
                axis.turns = []
        return hit
