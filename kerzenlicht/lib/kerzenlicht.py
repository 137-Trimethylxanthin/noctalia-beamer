#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = ["pywayland>=0.4.18"]
# ///
"""The flashlight itself: a white glow around the cursor, drawn over every
output, and a flash that dims the screen around the cursor for a moment, on
any Wayland compositor with layer-shell and cursor sessions.

No plugin entry can draw over everything, so the watch service runs this as a
child process, for as long as the plugin is enabled. While nothing shows it
only follows the cursor, which is what telling a shake needs; the light and
the flash are commands to it:

    SIGUSR1     flash: a small glow on the cursor for --flash seconds (again: longer)
    SIGUSR2     read --glow-file: "on" lights the glow, anything else puts it out

While something shows, each output gets a layer-shell surface on the overlay
layer, anchored to all edges, with an empty input region, so every click and
scroll goes straight through to whatever is below. When nothing shows, the
surfaces and their buffers are gone again.

The cursor comes from ext-image-copy-capture-v1 cursor sessions, one per
output: they report where the pointer is on that output, and when it enters
and leaves, to any client. Only the position is used; no frame is ever
captured, and no screen content is read.

It prints "on" once a second, and "glow on" / "glow off" whenever the glow
changes. When the service goes away the pipe breaks, the print fails, and
this exits, so the light is never left behind without the shell. Closing the
connection removes the surfaces, whatever the reason.

    uv run --script kerzenlicht.py --radius 30 --softness 15 --brightness 0.6 \
        --flash-radius 18 --dim 0.65 --flash 1.5 --shake --glow-file /path/glow
"""

from __future__ import annotations

import argparse
import math
import mmap
import os
import select
import signal
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import shake  # noqa: E402
import spot  # noqa: E402
from pywayland.client import Display  # noqa: E402
from pywayland.protocol.alpha_modifier_v1 import WpAlphaModifierV1  # noqa: E402
from pywayland.protocol.ext_image_capture_source_v1 import ExtOutputImageCaptureSourceManagerV1  # noqa: E402
from pywayland.protocol.ext_image_copy_capture_v1 import ExtImageCopyCaptureManagerV1  # noqa: E402
from pywayland.protocol.wayland import WlCompositor, WlOutput, WlSeat, WlShm  # noqa: E402
from pywayland.protocol.xdg_output_unstable_v1 import ZxdgOutputManagerV1  # noqa: E402
from wlr_virtual_pointer_unstable_v1 import ZwlrVirtualPointerManagerV1  # noqa: E402
from wlr_layer_shell_unstable_v1 import ZwlrLayerShellV1, ZwlrLayerSurfaceV1  # noqa: E402


class Buffer:
    """One shm buffer the size of the output, plus where its glow is now."""

    def __init__(self, shm, width, height):
        self.size = width * height * spot.BPP
        fd = os.memfd_create("kerzenlicht", os.MFD_CLOEXEC)
        try:
            os.ftruncate(fd, self.size)  # zero-filled: fully transparent
            self.map = mmap.mmap(fd, self.size)
            pool = shm.create_pool(fd, self.size)
            self.wl = pool.create_buffer(0, width, height, width * spot.BPP, WlShm.format.argb8888.value)
            pool.destroy()
        finally:
            os.close(fd)
        self.busy = False
        self.fresh = True
        self.placed = None
        self.scene = None  # which background and stamp it holds
        self.on_release = None
        self.wl.dispatcher["release"] = self._release

    def _release(self, _buffer):
        self.busy = False
        if self.on_release:
            self.on_release()

    def destroy(self):
        self.on_release = None
        self.wl.destroy()
        self.map.close()


class Output:
    def __init__(self, app, name, wl_output, version):
        self.app = app
        self.name = name
        self.wl_output = wl_output
        self.version = version
        self.mode = None
        self.width = self.height = 0
        self.buffers = []
        self.cursor = None
        self.raw = None  # the last position as the session sent it
        # Cursor-session positions are in buffer (physical) pixels, as the
        # protocol says, and that is what wlroots (sway, labwc, river, mango,
        # dwl) and niri send; Hyprland sends logical ones. Should Hyprland
        # ever change, a position past the logical edge gives it away
        # (spot.looks_physical).
        self.physical = not os.environ.get("HYPRLAND_INSTANCE_SIGNATURE")
        self.xdg = None  # xdg-output: the logical size before any surface exists
        # Every proxy is held here: pywayland keeps only weak references, and
        # a collected proxy is destroyed, along with the events it was waiting
        # for. A lost frame callback would freeze the light for good.
        self.frame_cb = None
        self.shown = None  # the stamp's rect in the last committed buffer
        self.dirty = False
        self.session = None
        self.surface = None
        self.layer = None
        self.fader = None
        self.opacity = None  # the multiplier last committed
        wl_output.dispatcher["mode"] = self._mode

    def _mode(self, _output, flags, width, height, _refresh):
        if flags & WlOutput.mode.current.value:
            self.mode = (width, height)

    def factor(self):
        width, height = self.logical_size()
        if not self.mode or not width:
            return 1.0
        return max(self.mode) / max(width, height)

    def learn_size(self):
        """Asks xdg-output for the logical size, so positions are scaled right
        before the first flash gives this output a surface to measure."""
        manager = self.app.xdg_outputs
        if manager is None or self.xdg is not None or self.wl_output is None:
            return
        self.xdg = manager.get_xdg_output(self.wl_output)
        self.xdg.dispatcher["logical_size"] = self._logical_size

    def _logical_size(self, _xdg, width, height):
        if width > 0 and height > 0 and not self.width:
            self.app.sizes[self.name] = (width, height)

    def watch(self):
        """Follows the cursor on this output, for as long as the helper runs.
        The source may go as soon as the session exists."""
        app = self.app
        self.learn_size()
        source = app.capture_sources.create_source(self.wl_output)
        self.session = app.capture.create_pointer_cursor_session(source, app.pointer)
        source.destroy()
        self.session.dispatcher["position"] = self._position
        self.session.dispatcher["leave"] = self._leave

    def show(self):
        """Puts the overlay up; `configure` brings its buffers."""
        if self.surface is not None:
            return
        app = self.app
        self.surface = app.compositor.create_surface()
        region = app.compositor.create_region()
        self.surface.set_input_region(region)  # empty: clicks go through
        region.destroy()
        self.layer = app.layer_shell.get_layer_surface(
            self.surface, self.wl_output, ZwlrLayerShellV1.layer.overlay.value, "kerzenlicht"
        )
        anchor = ZwlrLayerSurfaceV1.anchor
        self.layer.set_anchor(anchor.top.value | anchor.bottom.value | anchor.left.value | anchor.right.value)
        self.layer.set_size(0, 0)
        self.layer.set_exclusive_zone(-1)
        self.layer.set_keyboard_interactivity(ZwlrLayerSurfaceV1.keyboard_interactivity.none.value)
        self.layer.dispatcher["configure"] = self._configure
        self.layer.dispatcher["closed"] = lambda _layer: self.app.drop(self.name)
        if app.alpha is not None:
            self.fader = app.alpha.get_surface(self.surface)
        self.opacity = None
        self.surface.commit()

    def hide(self):
        """Takes the overlay down again, buffers and all."""
        self.frame_cb = None
        if self.fader is not None:
            self.fader.destroy()
            self.fader = None
        if self.layer is not None:
            self.layer.destroy()
            self.layer = None
        if self.surface is not None:
            self.surface.destroy()
            self.surface = None
        for buffer in self.buffers:
            buffer.destroy()
        self.buffers = []
        self.width = self.height = 0
        self.shown = None
        self.dirty = False

    def _configure(self, layer, serial, width, height):
        layer.ack_configure(serial)
        if width <= 0 or height <= 0:
            return
        if (width, height) != (self.width, self.height):
            # New buffers first: if that fails, the old ones are still whole.
            buffers = [Buffer(self.app.shm, width, height) for _ in range(2)]
            for buffer in self.buffers:
                buffer.destroy()
            self.buffers = buffers
            for buffer in buffers:
                buffer.on_release = self.draw
            self.width, self.height = width, height
            self.app.sizes[self.name] = (width, height)
            self.shown = None
            if self.raw is not None:
                self.locate(*self.raw)  # it may have come before the size did
        self.dirty = True
        self.draw()

    def logical_size(self):
        """The output's size in logical pixels, surface or not."""
        if self.width:
            return self.width, self.height
        return self.app.sizes.get(self.name, (0, 0))

    def locate(self, x, y):
        factor = self.factor()
        width, height = self.logical_size()
        if not self.physical and spot.looks_physical(x, y, width, height, factor):
            self.physical = True
        self.cursor = spot.to_local(x, y, width, height, self.physical, factor)

    def _position(self, _session, x, y):
        self.raw = (x, y)
        self.locate(x, y)
        self.app.moved(self)
        self.dirty = True
        self.draw()

    def _leave(self, _session):
        self.cursor = None
        self.raw = None
        self.dirty = True
        self.draw()

    def draw(self):
        """At most one commit per frame; cursor events in between are merged."""
        if self.frame_cb is not None or not self.buffers or self.surface is None:
            return
        app = self.app
        scene = app.scene
        if scene is None:
            return
        opacity = None
        if self.fader is not None:
            opacity = app.opacity() * app.share(self, time.monotonic())
        fading = opacity != self.opacity
        if app.closing(time.monotonic()) and scene[1] and self.cursor is not None:
            self.dirty = True  # a new frame of the closing-in, every frame
        if not self.dirty and not fading:
            return
        if self.dirty:
            buffer = next((b for b in self.buffers if not b.busy), None)
            if buffer is None:
                return
            self.paint(buffer, scene)
        if fading:
            self.fader.set_multiplier(round(opacity * 0xFFFFFFFF))
            self.opacity = opacity
        self.frame_cb = self.surface.frame()
        self.frame_cb.dispatcher["done"] = self._frame_done
        self.surface.commit()

    def centre(self):
        """The middle of the cursor, where every light is centred."""
        return self.cursor[0] + self.app.offset[0], self.cursor[1] + self.app.offset[1]

    def paint_closing(self, buffer, scene, now):
        """One frame of the closing-in: the whole buffer, drawn afresh."""
        app = self.app
        cx, cy = self.centre()
        far = max(math.hypot(cx - x, cy - y) for x in (0, self.width) for y in (0, self.height))
        radius = app.closing_radius(now, far + app.args.softness)
        # A soft edge that grows as the circle shrinks: cheap while it is
        # big, and exactly the set softness once it arrives.
        softness = max(1.0, app.args.softness * app.args.radius / max(radius, 1.0))
        buffer.map[:] = spot.spotlight_frame(self.width, self.height, cx, cy, radius, softness, scene[0], app.black)
        self.surface.attach(buffer.wl, 0, 0)
        self.surface.damage_buffer(0, 0, self.width, self.height)
        buffer.fresh = False
        buffer.busy = True
        buffer.placed = None
        buffer.scene = None  # whatever comes next repaints it whole
        self.shown = None
        self.dirty = False

    def paint(self, buffer, scene):
        """Brings `buffer` up to date and attaches it, with the damage."""
        now = time.monotonic()
        if self.app.closing(now) and scene[1] and self.cursor is not None:
            return self.paint_closing(buffer, scene, now)
        half, rows, background = self.app.stamps(scene, self.width)
        old = buffer.placed
        new = None
        if self.cursor is not None:
            cx, cy = self.centre()
            new = spot.clip(cx, cy, half, self.width, self.height)
        whole = buffer.fresh or buffer.scene != scene
        if whole:
            # Another look (or a new buffer): every pixel gets the new
            # background, and the whole screen is repainted.
            buffer.map[:] = background * self.height
        elif old:
            spot.fill(buffer.map, self.width, self.height, old[:4], background)
        if new:
            spot.stamp(buffer.map, self.width, rows, new)

        self.surface.attach(buffer.wl, 0, 0)
        if whole:
            self.surface.damage_buffer(0, 0, self.width, self.height)
            buffer.fresh = False
        else:
            # Damage is against what is on screen, which is the other buffer
            # when they alternate: its stamp (`shown`) has to go too, not only
            # this buffer's own old one.
            for rect in (old, self.shown, new):
                if rect:
                    self.surface.damage_buffer(*rect[:4])
        buffer.busy = True
        buffer.placed = new
        buffer.scene = scene
        self.shown = new
        self.dirty = False

    def _frame_done(self, callback, _time):
        if callback is not self.frame_cb:
            return  # from a surface that has been taken down since
        self.frame_cb = None
        self.draw()

    def unwatch(self):
        if self.session:
            self.session.destroy()
            self.session = None
        self.cursor = self.raw = None

    def destroy(self):
        self.hide()
        self.unwatch()
        if self.xdg is not None:
            self.xdg.destroy()
            self.xdg = None
        if self.wl_output is not None:
            if self.version >= 3:
                self.wl_output.release()
            self.wl_output = None


FADE_IN = 0.08  # seconds: a flash is there at once
FADE_OUT = 0.3
SHAKE_LIFT = 0.18  # the faint white that brightens the cursor's spot while shaking
FLASH_BRIGHTNESS = 0.95  # a flash is bright, whatever the steady glow's brightness
NUDGE = 3.0  # px the pointer moves to wake a hidden cursor, and back


def cursor_offset():
    """Where the middle of the cursor is, from its point: an arrow hangs
    down and to the right of the spot the position is for, so a light
    centred on the point would sit on its tip. Scaled from the cursor size
    the session sets (24 unless it says otherwise)."""
    size = 24
    for name in ("HYPRCURSOR_SIZE", "XCURSOR_SIZE"):
        try:
            value = int(os.environ.get(name, ""))
        except ValueError:
            continue
        if 8 <= value <= 256:
            size = value
            break
    return round(size * 0.2), round(size * 0.4)
NUDGE_BACK = 0.06  # seconds until it goes back
CIRCLE = 0.35  # seconds the dimming takes to close in onto the spot, and to open out again


class App:
    def __init__(self, args):
        self.args = args
        self.white = round(255 * args.brightness)
        self.black = round(255 * args.dim)
        self._stamps = {}
        self._backgrounds = {}
        self.sizes = {}  # output name -> logical size, kept while hidden
        self.glow = False
        self.flash_until = 0.0
        self.scene = None  # what is drawn: (white, dimmed), or None
        self.shake = shake.Shake() if args.shake else None
        self.shake_output = None
        # While the mouse is being shaken the screen is dimmed around the
        # cursor, with no glow: a spotlight, not a flashlight. It ends the
        # moment the shaking does.
        self.shaking = False
        self.offset = cursor_offset()
        # When the dimming comes on, the clear circle starts bigger than the
        # screen and shrinks to the spot ("in"); when it goes, it widens past
        # the screen's edge again ("out"). Each takes CIRCLE seconds from
        # `circle_start`.
        self.circle_dir = None
        self.circle_start = 0.0
        # The fade: opacity goes from `fade_from` to `fade_to` over
        # `fade_len` seconds from `fade_start`.
        self.fade_from = self.fade_to = 1.0
        self.fade_start = 0.0
        self.fade_len = 0.0
        self.display = Display()
        self.display.connect()
        self.outputs = {}
        self.pending = []  # outputs plugged in since the last loop turn
        self.compositor = self.shm = self.seat = self.layer_shell = None
        self.capture = self.capture_sources = None
        self.alpha = None
        self.xdg_outputs = None
        self.virtual_pointers = None
        self.nudger = None
        self.nudge_back_at = 0.0
        self.pointer = None
        self.seat_caps = 0
        self.seat_version = 0
        self.started = False
        self.registry = self.display.get_registry()  # held: see Output.frame_cb
        self.registry.dispatcher["global"] = self._global
        self.registry.dispatcher["global_remove"] = self._global_remove
        self.display.roundtrip()

    def _global(self, registry, name, interface, version):
        if interface == "wl_compositor":
            self.compositor = registry.bind(name, WlCompositor, min(version, 4))
        elif interface == "wl_shm":
            self.shm = registry.bind(name, WlShm, 1)
        elif interface == "wl_seat" and self.seat is None:
            self.seat_version = min(version, 5)  # proxies do not carry it
            self.seat = registry.bind(name, WlSeat, self.seat_version)
            self.seat.dispatcher["capabilities"] = self._seat_caps
        elif interface == "zwlr_layer_shell_v1":
            self.layer_shell = registry.bind(name, ZwlrLayerShellV1, min(version, 4))
        elif interface == "ext_image_copy_capture_manager_v1":
            self.capture = registry.bind(name, ExtImageCopyCaptureManagerV1, 1)
        elif interface == "ext_output_image_capture_source_manager_v1":
            self.capture_sources = registry.bind(name, ExtOutputImageCaptureSourceManagerV1, 1)
        elif interface == "zwlr_virtual_pointer_manager_v1":
            # Optional: to wake a cursor an app has hidden, see nudge().
            self.virtual_pointers = registry.bind(name, ZwlrVirtualPointerManagerV1, 1)
        elif interface == "zxdg_output_manager_v1":
            self.xdg_outputs = registry.bind(name, ZxdgOutputManagerV1, min(version, 3))
        elif interface == "wp_alpha_modifier_v1":
            # Optional: without it the light comes and goes without a fade.
            self.alpha = registry.bind(name, WpAlphaModifierV1, 1)
        elif interface == "wl_output":
            version = min(version, 3)
            output = Output(self, name, registry.bind(name, WlOutput, version), version)
            self.outputs[name] = output
            if self.started:
                # Started from the main loop, once its mode has arrived.
                self.pending.append(name)

    def _seat_caps(self, _seat, caps):
        self.seat_caps = caps
        if self.started:
            self.follow_pointer()

    def follow_pointer(self):
        """Cursor sessions need the seat's pointer, which exists only while a
        mouse or touchpad does: a Bluetooth mouse that connects after login,
        or one unplugged and plugged back in, picks up from here."""
        has = bool(self.seat_caps & WlSeat.capability.pointer.value)
        if has and self.pointer is None:
            self.pointer = self.seat.get_pointer()
            for output in list(self.outputs.values()):
                if output.session is None and output.wl_output is not None:
                    output.watch()
        elif not has and self.pointer is not None:
            for output in list(self.outputs.values()):
                output.unwatch()
            if self.seat_version >= 3:
                self.pointer.release()
            self.pointer = None

    def _global_remove(self, _registry, name):
        self.drop(name)

    def drop(self, name):
        output = self.outputs.pop(name, None)
        if output:
            output.destroy()

    def missing(self):
        needs = {
            "wl_compositor": self.compositor,
            "wl_shm": self.shm,
            "wl_seat": self.seat,
            "zwlr_layer_shell_v1": self.layer_shell,
            "ext_image_copy_capture_manager_v1": self.capture,
            "ext_output_image_capture_source_manager_v1": self.capture_sources,
        }
        return [name for name, value in needs.items() if value is None]

    def start(self):
        """Follows the cursor from now on; with no mouse yet, from when one
        turns up."""
        self.display.roundtrip()  # seat capabilities, output modes
        self.started = True
        for output in list(self.outputs.values()):
            output.learn_size()
        self.follow_pointer()
        self.display.roundtrip()

    def start_pending(self):
        if not self.pending:
            return
        names, self.pending = self.pending, []
        self.display.roundtrip()  # their modes
        for name in names:
            output = self.outputs.get(name)
            if output is not None and output.session is None:
                if self.pointer is not None:
                    output.watch()
                else:
                    output.learn_size()
                if self.scene is not None:
                    output.show()

    # ── What shows ──────────────────────────────────────────────────────────

    def stamps(self, scene, width):
        """The stamp and background row for a scene, built once each."""
        white, dimmed, radius = scene
        stamp = self._stamps.get(scene)
        if stamp is None:
            # The soft edge keeps its proportion, so a small flash is as
            # soft as the big glow, only smaller.
            softness = round(self.args.softness * radius / self.args.radius)
            stamp = self._stamps[scene] = spot.spotlight(
                radius, softness, white, self.black if dimmed else 0
            )
        key = (dimmed, width)
        background = self._backgrounds.get(key)
        if background is None:
            background = self._backgrounds[key] = spot.background(self.black if dimmed else 0, width)
        return stamp[0], stamp[1], background

    def wanted(self, now):
        """The scene the state asks for: (white, dimmed, radius), or None.
        `white` is the glow's opacity, 0 to 255.

        A flash (a message, the flash key) is a small glow on the cursor,
        nothing else. A shake dims the screen around the spot, which a
        faint lift makes brighter than the screen without laying a light
        over it. The steady glow is the big one, and wins over a flash."""
        flashing = now < self.flash_until
        white, radius = 0, self.args.radius
        if self.glow:
            white = self.white
        elif self.shaking:
            white = round(255 * SHAKE_LIFT)
        elif flashing:
            white, radius = round(255 * FLASH_BRIGHTNESS), self.args.flash_radius
        dimmed = self.shaking
        if not white and not dimmed:
            return None
        return white, dimmed, radius

    def opacity(self, now=None):
        if now is None:
            now = time.monotonic()
        if self.fade_len <= 0:
            return self.fade_to
        t = min(1.0, max(0.0, (now - self.fade_start) / self.fade_len))
        return self.fade_from + (self.fade_to - self.fade_from) * t

    def fade(self, to, seconds, now):
        self.fade_from = self.opacity(now)
        self.fade_to = to
        self.fade_start = now
        self.fade_len = seconds if self.alpha is not None else 0.0

    def fading(self, now):
        return self.fade_len > 0 and now - self.fade_start < self.fade_len

    def update(self, now):
        """Brings what shows in line with the state: fades in, switches the
        look, or fades out and takes the surfaces down."""
        if self.shaking and not self.shake.still(now):
            self.shaking = False
        want = self.wanted(now)
        want_dim = want is not None and want[1]
        dimmed = self.scene is not None and self.scene[1]

        if self.circle_dir == "out":
            if want_dim:
                # Back before it had opened: close in again from where it is.
                self.circle_dir = "in"
                self.circle_start = now - (1.0 - self.circle_progress(now)) * CIRCLE
            elif self.circle_progress(now) < 1.0:
                return self.draw_all()  # the dimmed look stays while it opens
            else:
                self.circle_dir = None
                if want is None:
                    return self.take_down()
                self.scene = want  # the glow alone, if it is still on
                self.mark_dirty()
                return self.draw_all()
        elif dimmed and not want_dim and self.fade_to >= 1.0:
            # The dimming ends: open out, in reverse, from where it is.
            p = self.circle_progress(now) if self.circle_dir == "in" else 1.0
            self.circle_dir = "out"
            self.circle_start = now - (1.0 - p) * CIRCLE
            self.mark_dirty()
            return self.draw_all()

        if want_dim and not dimmed and self.circle_dir is None:
            self.circle_dir, self.circle_start = "in", now
        if self.circle_dir == "in" and self.circle_progress(now) >= 1.0:
            self.circle_dir = None
            self.mark_dirty()  # the last frame: the real stamp
        if want is not None:
            if self.scene is None:
                self.fade_from = self.fade_to = 0.0  # from nothing
                self.fade(1.0, FADE_IN, now)
                self.scene = want
                for output in self.outputs.values():
                    if output.session is not None:
                        output.show()
            elif self.fade_to < 1.0:
                self.fade(1.0, FADE_IN, now)  # it was going: come back
            if want != self.scene:
                self.scene = want
                for output in self.outputs.values():
                    output.dirty = True
        elif self.scene is not None:
            if self.fade_to > 0.0:
                self.fade(0.0, FADE_OUT, now)  # the glow alone fades as it was
            elif not self.fading(now):
                return self.take_down()
        self.draw_all()

    def draw_all(self):
        for output in self.outputs.values():
            output.draw()

    def mark_dirty(self):
        for output in self.outputs.values():
            output.dirty = True

    def take_down(self):
        self.scene = None
        self.circle_dir = None
        for output in self.outputs.values():
            output.hide()

    def circle_progress(self, now):
        return min(1.0, max(0.0, (now - self.circle_start) / CIRCLE))

    def closing(self, now):
        """Whether the circle is moving, in or out."""
        return self.circle_dir is not None and self.circle_progress(now) < 1.0

    def closed(self, now):
        """How far the dimming has closed in: 0 open, 1 on the spot. The way
        out is the way in played backwards."""
        p = self.circle_progress(now)
        if self.circle_dir == "out":
            p = 1.0 - p
        elif self.circle_dir is None:
            p = 1.0
        return 1.0 - (1.0 - p) ** 3  # fast at first, settling at the end

    def closing_radius(self, now, far):
        """The spot's radius `now`, between `far` (past the screen's farthest
        corner) and the set radius."""
        return self.args.radius + (far - self.args.radius) * (1.0 - self.closed(now))

    def share(self, output, now):
        """How much of the dimming an output without the cursor shows: it has
        no circle, so it fades in and out along with the one that does."""
        if output.cursor is None and self.closing(now) and self.scene is not None and self.scene[1]:
            return self.closed(now)
        return 1.0

    def nudge(self):
        """Wakes a cursor that has gone into hiding. Terminals hide it while
        you type, players while a video runs, and it only comes back when
        the mouse moves: so it moves, a few pixels and back. The way back
        comes a moment later (nudge_back), as a move of its own: an app that
        reads the pointer once a frame would see a move and its undoing in
        the same frame as no move at all. Needs wlr-virtual-pointer
        (wlroots, Hyprland); elsewhere the cursor stays as it is."""
        if self.virtual_pointers is None or self.seat is None or self.nudge_back_at:
            return
        if self.nudger is None:
            self.nudger = self.virtual_pointers.create_virtual_pointer(self.seat)
        self.nudger.motion(int(time.monotonic() * 1000) & 0xFFFFFFFF, NUDGE, 0.0)
        self.nudger.frame()
        self.display.flush()
        self.nudge_back_at = time.monotonic() + NUDGE_BACK

    def nudge_back(self, now):
        if self.nudge_back_at and now >= self.nudge_back_at:
            self.nudge_back_at = 0.0
            self.nudger.motion(int(now * 1000) & 0xFFFFFFFF, -NUDGE, 0.0)
            self.nudger.frame()
            self.display.flush()

    def flash(self):
        self.nudge()
        now = time.monotonic()
        self.flash_until = max(self.flash_until, now + self.args.flash)
        self.update(now)

    def set_glow(self, on):
        if on != self.glow:
            self.glow = on
            self.update(time.monotonic())
        print("glow on" if on else "glow off", flush=True)

    def read_glow(self):
        try:
            with open(self.args.glow_file) as handle:
                return handle.read().strip() == "on"
        except (OSError, TypeError):
            return False

    def moved(self, output):
        """The cursor moved on `output`: shaking it flashes."""
        if self.shake is None or output.cursor is None:
            return
        # Near a seam the cursor image overlaps two outputs, and both report
        # it; only the one it is really on counts, or every event would
        # switch outputs and start the shake over.
        width, height = output.logical_size()
        x, y = output.cursor
        if width and height and not (0 <= x < width and 0 <= y < height):
            return
        if output.name != self.shake_output:
            self.shake.reset()
            self.shake_output = output.name
        now = time.monotonic()
        if self.shake.feed(now, x, y) and not self.shaking:
            self.shaking = True
            self.update(now)

    def run(self, wake_fd, signals):
        fd = self.display.get_fd()
        deadline = time.monotonic() + self.args.seconds if self.args.seconds > 0 else None
        next_beat = 0.0
        self.set_glow(self.read_glow())
        while True:
            now = time.monotonic()
            if deadline is not None and now >= deadline:
                return
            while signals:
                signum = signals.pop(0)
                if signum == signal.SIGUSR1:
                    self.flash()
                elif signum == signal.SIGUSR2:
                    self.set_glow(self.read_glow())
                else:
                    return
            if now >= next_beat:
                print("on", flush=True)  # BrokenPipeError once the service is gone
                next_beat = now + 1.0
            self.start_pending()
            self.nudge_back(now)
            self.update(now)
            self.display.dispatch(block=False)
            self.display.flush()
            timeout = next_beat - now
            if deadline is not None:
                timeout = min(timeout, deadline - now)
            if self.scene is not None and now < self.flash_until:
                timeout = min(timeout, self.flash_until - now)
            if self.shaking:
                timeout = min(timeout, 0.05)  # to see the shaking stop
            if self.nudge_back_at:
                timeout = min(timeout, max(0.0, self.nudge_back_at - now))
            if self.circle_dir is not None:
                timeout = min(timeout, 0.008)  # the circle draws every frame
            if self.fading(now) or (self.scene is not None and self.fade_to == 0.0):
                timeout = min(timeout, 0.02)  # the fade ends between frames
            readable, _, _ = select.select([fd, wake_fd], [], [], max(0.0, timeout))
            if wake_fd in readable:
                try:
                    os.read(wake_fd, 64)
                except BlockingIOError:
                    pass
            if fd in readable:
                # Read what is there and dispatch it; never block in dispatch,
                # which would wait for an event for a live proxy.
                self.display.read()
                self.display.dispatch(block=False)

    def close(self):
        for output in list(self.outputs.values()):
            output.destroy()
        try:
            self.display.flush()
            self.display.disconnect()
        except Exception:
            pass


RADIUS = (5, 400)
SOFTNESS = (0, 300)
BRIGHTNESS = (0.1, 1.0)
DIM = (0.1, 0.9)
FLASH = (0.3, 10.0)


def clamp(value, bounds):
    return max(bounds[0], min(bounds[1], value))


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--radius", type=int, default=30, help="full-strength glow around the cursor, logical px")
    parser.add_argument("--softness", type=int, default=15, help="fade from the glow to nothing, logical px")
    parser.add_argument("--brightness", type=float, default=0.6, help="opacity of the white glow, 0.1 to 1")
    parser.add_argument("--flash-radius", type=int, default=18, help="the glow a flash shows, logical px")
    parser.add_argument("--dim", type=float, default=0.65, help="how dark a shake makes the rest of the screen, 0.1 to 0.9")
    parser.add_argument("--flash", type=float, default=1.5, help="how long a flash lasts, seconds")
    parser.add_argument("--shake", action="store_true", help="shaking the mouse dims all but the cursor")
    parser.add_argument("--glow-file", help='holds "on" while the glow should be lit; read at start and on SIGUSR2')
    parser.add_argument("--seconds", type=float, default=0, help="turn off by itself after this long; 0 never")
    parser.add_argument("--pidfile", help="write the pid here, to stop it by hand")
    parser.add_argument("--tag", help="ignored; marks the command line, so the service can pkill -f this run")
    args = parser.parse_args()
    args.radius = clamp(args.radius, RADIUS)
    args.flash_radius = clamp(args.flash_radius, RADIUS)
    args.softness = clamp(args.softness, SOFTNESS)
    args.brightness = clamp(args.brightness, BRIGHTNESS)
    args.dim = clamp(args.dim, DIM)
    args.flash = clamp(args.flash, FLASH)

    # A signal only queues itself and wakes the loop through a pipe. Raising
    # from the handler would be swallowed if it landed inside a Wayland
    # callback (pywayland catches exceptions there), and the helper would
    # keep running after pkill. The two user signals are the commands.
    wake_r, wake_w = os.pipe()
    os.set_blocking(wake_r, False)
    os.set_blocking(wake_w, False)
    signals = []
    signal.set_wakeup_fd(wake_w)
    for signum in (signal.SIGTERM, signal.SIGINT, signal.SIGHUP, signal.SIGUSR1, signal.SIGUSR2):
        signal.signal(signum, lambda signum, _frame: signals.append(signum))
    # SIGPIPE stays ignored (Python's default), so a dead reader surfaces as
    # BrokenPipeError on the next beat and the pidfile is still cleaned up.

    if args.pidfile:
        with open(args.pidfile, "w") as handle:
            handle.write(str(os.getpid()))

    app = None
    try:
        app = App(args)
        missing = app.missing()
        if missing:
            print("unsupported: " + ", ".join(missing), flush=True)
            return 3
        app.start()
        app.run(wake_r, signals)
        return 0
    except BrokenPipeError:
        # The service is gone. Point stdout at /dev/null so the final flush
        # at exit does not complain about the same closed pipe.
        os.dup2(os.open(os.devnull, os.O_WRONLY), sys.stdout.fileno())
        return 0
    except Exception as error:  # reported to the service, which logs it
        print(f"error: {type(error).__name__}: {error}", flush=True)
        return 1
    finally:
        if app is not None:
            app.close()
        if args.pidfile:
            try:
                os.unlink(args.pidfile)
            except OSError:
                pass


if __name__ == "__main__":
    sys.exit(main())
