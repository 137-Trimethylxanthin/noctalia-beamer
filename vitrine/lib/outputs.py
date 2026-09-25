#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = ["pywayland>=0.4.18"]
# ///
"""Vitrine's output backend for every compositor but Hyprland: reads and
changes monitors through the standard wlr-output-management protocol, which
sway, Scroll, niri, MangoWC, labwc, dwl, River/Triad and Umbriel all speak.

    outputs.py list                  -> JSON list of heads on stdout
    outputs.py apply '<json>'        -> applies a configuration
    outputs.py apply '<json>' --test -> asks the compositor whether it would

A configuration is a list of {"name", "enabled", "mode", "x", "y", "scale",
"transform"}. "mode" is {"width", "height", "refresh"} (refresh in mHz, 0 =
any), "preferred", or absent to keep the current one; absent position, scale
or transform keep the current values. Heads not named keep their state. The
whole configuration is applied atomically: the compositor either takes all of
it or none, and says which.

Prints one line: the JSON, or "succeeded" / "failed" / "cancelled" /
"unsupported: <protocol>". Exit status 0 only for success.

Not for Hyprland, where Vitrine uses hyprctl instead. Hyprland 0.56's
implementation of this protocol answers `test` with "succeeded" without
checking anything, and acts on `disable_head` as soon as a configuration
names it, applied or not, so even --test switches screens off there.
"""

from __future__ import annotations

import json
import os
import select
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from pywayland.client import Display  # noqa: E402
from wlr_output_management_unstable_v1 import ZwlrOutputManagerV1  # noqa: E402

ANSWER_SECONDS = 10  # how long a change may take before it counts as failed


class Head:
    def __init__(self, proxy):
        self.proxy = proxy
        self.info = {"name": None, "description": "", "make": "", "model": "", "serial": "",
                     "enabled": False, "x": 0, "y": 0, "scale": 1.0, "transform": 0}
        self.modes = []  # [(proxy, dict)]
        self.current = None
        self.gone = False
        d = proxy.dispatcher
        for field in ("name", "description", "make", "model", "serial_number"):
            d[field] = self._setter("serial" if field == "serial_number" else field)
        d["enabled"] = lambda _h, v: self.info.update(enabled=bool(v))
        d["position"] = lambda _h, x, y: self.info.update(x=x, y=y)
        d["scale"] = lambda _h, s: self.info.update(scale=s)
        d["transform"] = lambda _h, t: self.info.update(transform=t)
        d["mode"] = self._mode
        d["current_mode"] = lambda _h, mode: setattr(self, "current", mode)
        d["finished"] = lambda _h: setattr(self, "gone", True)

    def _setter(self, key):
        return lambda _h, v: self.info.__setitem__(key, v)

    def _mode(self, _h, proxy):
        m = {"width": 0, "height": 0, "refresh": 0, "preferred": False}
        self.modes.append((proxy, m))
        proxy.dispatcher["size"] = lambda _m, w, h: m.update(width=w, height=h)
        proxy.dispatcher["refresh"] = lambda _m, r: m.update(refresh=r)
        proxy.dispatcher["preferred"] = lambda _m: m.update(preferred=True)
        proxy.dispatcher["finished"] = lambda _m: m.update(gone=True)

    def live_modes(self):
        return [(p, m) for p, m in self.modes if not m.get("gone")]

    def to_json(self):
        out = dict(self.info)
        current = next((m for p, m in self.live_modes() if p is self.current), None)
        out["width"] = current["width"] if current else 0
        out["height"] = current["height"] if current else 0
        out["refresh"] = current["refresh"] if current else 0
        out["modes"] = [{k: m[k] for k in ("width", "height", "refresh", "preferred")} for _, m in self.live_modes()]
        return out

    def find_mode(self, want):
        modes = self.live_modes()
        if not modes:
            return None
        if want == "preferred":
            return next((p for p, m in modes if m["preferred"]), modes[0][0])
        w, h, r = want.get("width"), want.get("height"), want.get("refresh") or 0
        same = [(p, m) for p, m in modes if m["width"] == w and m["height"] == h]
        if not same:
            return None
        if r:
            return min(same, key=lambda pm: abs(pm[1]["refresh"] - r))[0]
        return max(same, key=lambda pm: pm[1]["refresh"])[0]


def connect():
    display = Display()
    display.connect()
    registry = display.get_registry()
    found = {}

    def on_global(reg, name, interface, version):
        if interface == "zwlr_output_manager_v1":
            found["manager"] = reg.bind(name, ZwlrOutputManagerV1, min(version, 4))

    registry.dispatcher["global"] = on_global
    display.roundtrip()
    manager = found.get("manager")
    if manager is None:
        return display, registry, None, [], None
    heads, state = [], {"serial": None}
    manager.dispatcher["head"] = lambda _m, proxy: heads.append(Head(proxy))
    manager.dispatcher["done"] = lambda _m, serial: state.update(serial=serial)
    display.roundtrip()
    display.roundtrip()
    return display, registry, manager, heads, state["serial"]


def apply(display, manager, heads, serial, config, test_only):
    by_name = {h.info["name"]: h for h in heads if not h.gone}
    wanted = {c["name"]: c for c in config if isinstance(c, dict) and c.get("name") in by_name}
    unknown = [c.get("name") for c in config if isinstance(c, dict) and c.get("name") not in by_name]
    if unknown:
        return "failed", f"unknown output {unknown[0]}"

    cfg = manager.create_configuration(serial)
    for name, head in by_name.items():
        want = wanted.get(name, {})
        enabled = want.get("enabled", head.info["enabled"])
        if not enabled:
            cfg.disable_head(head.proxy)
            continue
        ch = cfg.enable_head(head.proxy)
        mode = want.get("mode")
        proxy = head.find_mode(mode) if mode else head.current
        if proxy is None and mode and mode != "preferred":
            ch.set_custom_mode(mode["width"], mode["height"], mode.get("refresh") or 0)
        elif proxy is not None:
            ch.set_mode(proxy)
        else:
            fallback = head.find_mode("preferred")
            if fallback is not None:
                ch.set_mode(fallback)
        ch.set_position(int(want.get("x", head.info["x"])), int(want.get("y", head.info["y"])))
        ch.set_scale(float(want.get("scale", head.info["scale"]) or 1.0))
        ch.set_transform(int(want.get("transform", head.info["transform"]) or 0))

    result = {}
    cfg.dispatcher["succeeded"] = lambda _c: result.update(r="succeeded")
    cfg.dispatcher["failed"] = lambda _c: result.update(r="failed")
    cfg.dispatcher["cancelled"] = lambda _c: result.update(r="cancelled")
    (cfg.test if test_only else cfg.apply)()
    # The answer comes once the compositor has done it, which for a modeset
    # can take a second or two: wait for it, not for a number of roundtrips.
    display.flush()
    fd = display.get_fd()
    deadline = time.monotonic() + ANSWER_SECONDS
    while not result:
        left = deadline - time.monotonic()
        if left <= 0:
            break
        display.dispatch(block=False)
        if result:
            break
        display.flush()
        readable, _, _ = select.select([fd], [], [], left)
        if readable:
            display.read()
            display.dispatch(block=False)
    cfg.destroy()
    if not result:
        return "failed", "no answer from the compositor"
    return result["r"], None


def main():
    if len(sys.argv) < 2 or sys.argv[1] not in ("list", "apply"):
        print("usage: outputs.py list | apply '<json>' [--test]", file=sys.stderr)
        return 2
    display, registry, manager, heads, serial = connect()
    if manager is None:
        print("unsupported: zwlr_output_manager_v1", flush=True)
        return 3
    if sys.argv[1] == "apply" and os.environ.get("HYPRLAND_INSTANCE_SIGNATURE"):
        print("failed: not on Hyprland; Vitrine drives it through hyprctl", flush=True)
        return 2
    if sys.argv[1] == "list":
        print(json.dumps([h.to_json() for h in heads if not h.gone and h.info["name"]]), flush=True)
        return 0
    try:
        config = json.loads(sys.argv[2]) if len(sys.argv) > 2 else None
    except ValueError:
        config = None
    if not isinstance(config, list):
        print("failed: configuration must be a JSON list", flush=True)
        return 2
    test_only = "--test" in sys.argv[3:]
    outcome, why = apply(display, manager, heads, serial, config, test_only)
    if outcome == "cancelled":
        # The outputs changed under us (a hotplug, another tool): look again
        # and try once more against what is there now.
        display.disconnect()
        display, registry, manager, heads, serial = connect()
        if manager is not None:
            outcome, why = apply(display, manager, heads, serial, config, test_only)
    print(outcome if why is None else f"{outcome}: {why}", flush=True)
    return 0 if outcome == "succeeded" else 1


if __name__ == "__main__":
    code = main()
    sys.stdout.flush()
    # Skip interpreter teardown: pywayland's proxies can outlive the
    # connection there and crash on the way out.
    os._exit(code)
