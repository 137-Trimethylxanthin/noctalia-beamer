#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = ["pywayland>=0.4.18"]
# ///
"""The flashlight itself: a white glow around the cursor, drawn over every
output, on any Wayland compositor with layer-shell and cursor sessions.

No plugin entry can draw over everything, so the watch service runs this as a
child process. Each output gets a layer-shell surface on the overlay layer,
anchored to all edges, with an empty input region, so every click and scroll
goes straight through to whatever is below.

The cursor comes from ext-image-copy-capture-v1 cursor sessions, one per
output: they report where the pointer is on that output, and when it enters
and leaves, to any client. Only the position is used; no frame is ever
captured, and no screen content is read.

It prints "on" once a second. When the service goes away the pipe breaks, the
print fails, and this exits, so the glow is never left behind without the
shell. Closing the connection removes the surfaces, whatever the reason.

    uv run --script kerzenlicht.py --radius 30 --softness 15 --brightness 0.6
"""

from __future__ import annotations

import argparse
import mmap
import os
import select
import signal
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import spot  # noqa: E402
from pywayland.client import Display  # noqa: E402
from pywayland.protocol.ext_image_capture_source_v1 import ExtOutputImageCaptureSourceManagerV1  # noqa: E402
from pywayland.protocol.ext_image_copy_capture_v1 import ExtImageCopyCaptureManagerV1  # noqa: E402
from pywayland.protocol.wayland import WlCompositor, WlOutput, WlSeat, WlShm  # noqa: E402
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
        self.clear_row = b""
        self.cursor = None
        self.physical = False
        # Every proxy is held here: pywayland keeps only weak references, and
        # a collected proxy is destroyed, along with the events it was waiting
        # for. A lost frame callback would freeze the light for good.
        self.frame_cb = None
        self.shown = None  # the glow's rect in the last committed buffer
        self.dirty = False
        self.session = None
        self.surface = None
        self.layer = None
        wl_output.dispatcher["mode"] = self._mode

    def _mode(self, _output, flags, width, height, _refresh):
        if flags & WlOutput.mode.current.value:
            self.mode = (width, height)

    def factor(self):
        if not self.mode or not self.width:
            return 1.0
        return max(self.mode) / max(self.width, self.height)

    def start(self):
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
        self.surface.commit()

        # The source may go as soon as the session exists.
        source = app.capture_sources.create_source(self.wl_output)
        self.session = app.capture.create_pointer_cursor_session(source, app.pointer)
        source.destroy()
        self.session.dispatcher["position"] = self._position
        self.session.dispatcher["leave"] = self._leave

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
            self.clear_row = spot.CLEAR * width
            self.shown = None
        self.dirty = True
        self.draw()

    def _position(self, _session, x, y):
        factor = self.factor()
        if not self.physical and spot.looks_physical(x, y, self.width, self.height, factor):
            self.physical = True
        self.cursor = spot.to_local(x, y, self.width, self.height, self.physical, factor)
        self.dirty = True
        self.draw()

    def _leave(self, _session):
        self.cursor = None
        self.dirty = True
        self.draw()

    def draw(self):
        """At most one commit per frame; cursor events in between are merged."""
        if not self.dirty or self.frame_cb is not None or not self.buffers or self.surface is None:
            return
        buffer = next((b for b in self.buffers if not b.busy), None)
        if buffer is None:
            return
        app = self.app
        old = buffer.placed
        new = None
        if self.cursor is not None:
            new = spot.clip(self.cursor[0], self.cursor[1], app.half, self.width, self.height)
        if old:
            spot.fill(buffer.map, self.width, self.height, old[:4], self.clear_row)
        if new:
            spot.stamp(buffer.map, self.width, app.rows, new)

        self.surface.attach(buffer.wl, 0, 0)
        if buffer.fresh:
            self.surface.damage_buffer(0, 0, self.width, self.height)
            buffer.fresh = False
        # Damage is against what is on screen, which is the other buffer when
        # they alternate: its glow (`shown`) has to go too, not only this
        # buffer's own old one.
        for rect in (old, self.shown, new):
            if rect:
                self.surface.damage_buffer(*rect[:4])
        self.frame_cb = self.surface.frame()
        self.frame_cb.dispatcher["done"] = self._frame_done
        self.surface.commit()
        buffer.busy = True
        buffer.placed = new
        self.shown = new
        self.dirty = False

    def _frame_done(self, _callback, _time):
        self.frame_cb = None
        self.draw()

    def destroy(self):
        self.frame_cb = None
        if self.session:
            self.session.destroy()
            self.session = None
        if self.layer:
            self.layer.destroy()
            self.layer = None
        if self.surface:
            self.surface.destroy()
            self.surface = None
        for buffer in self.buffers:
            buffer.destroy()
        self.buffers = []
        if self.wl_output is not None:
            if self.version >= 3:
                self.wl_output.release()
            self.wl_output = None


class App:
    def __init__(self, args):
        self.args = args
        alpha = round(255 * max(0.0, min(1.0, args.brightness)))
        self.half, self.rows = spot.glow(args.radius, args.softness, alpha)
        self.display = Display()
        self.display.connect()
        self.outputs = {}
        self.pending = []  # outputs plugged in since the last loop turn
        self.compositor = self.shm = self.seat = self.layer_shell = None
        self.capture = self.capture_sources = None
        self.pointer = None
        self.seat_caps = 0
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
            self.seat = registry.bind(name, WlSeat, min(version, 5))
            self.seat.dispatcher["capabilities"] = self._seat_caps
        elif interface == "zwlr_layer_shell_v1":
            self.layer_shell = registry.bind(name, ZwlrLayerShellV1, min(version, 4))
        elif interface == "ext_image_copy_capture_manager_v1":
            self.capture = registry.bind(name, ExtImageCopyCaptureManagerV1, 1)
        elif interface == "ext_output_image_capture_source_manager_v1":
            self.capture_sources = registry.bind(name, ExtOutputImageCaptureSourceManagerV1, 1)
        elif interface == "wl_output":
            version = min(version, 3)
            output = Output(self, name, registry.bind(name, WlOutput, version), version)
            self.outputs[name] = output
            if self.started:
                # Started from the main loop, once its mode has arrived.
                self.pending.append(name)

    def _seat_caps(self, _seat, caps):
        self.seat_caps = caps

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
        self.display.roundtrip()  # seat capabilities, output modes
        if not self.seat_caps & WlSeat.capability.pointer.value:
            return False
        self.pointer = self.seat.get_pointer()
        self.started = True
        for output in list(self.outputs.values()):
            output.start()
        self.display.roundtrip()
        return True

    def start_pending(self):
        if not self.pending:
            return
        names, self.pending = self.pending, []
        self.display.roundtrip()  # their modes
        for name in names:
            output = self.outputs.get(name)
            if output is not None and output.surface is None:
                output.start()

    def run(self, stop_fd, stopping):
        fd = self.display.get_fd()
        deadline = time.monotonic() + self.args.seconds if self.args.seconds > 0 else None
        next_beat = 0.0
        while not stopping():
            now = time.monotonic()
            if deadline is not None and now >= deadline:
                return
            if now >= next_beat:
                print("on", flush=True)  # BrokenPipeError once the service is gone
                next_beat = now + 1.0
            self.start_pending()
            self.display.dispatch(block=False)
            self.display.flush()
            timeout = next_beat - now
            if deadline is not None:
                timeout = min(timeout, deadline - now)
            readable, _, _ = select.select([fd, stop_fd], [], [], max(0.0, timeout))
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


def clamp(value, bounds):
    return max(bounds[0], min(bounds[1], value))


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--radius", type=int, default=30, help="full-strength glow around the cursor, logical px")
    parser.add_argument("--softness", type=int, default=15, help="fade from the glow to nothing, logical px")
    parser.add_argument("--brightness", type=float, default=0.6, help="opacity of the white glow, 0.1 to 1")
    parser.add_argument("--seconds", type=float, default=0, help="turn off by itself after this long; 0 never")
    parser.add_argument("--pidfile", help="write the pid here, to stop it by hand")
    parser.add_argument("--tag", help="ignored; marks the command line, so the service can pkill -f this run")
    args = parser.parse_args()
    args.radius = clamp(args.radius, RADIUS)
    args.softness = clamp(args.softness, SOFTNESS)
    args.brightness = clamp(args.brightness, BRIGHTNESS)

    # A signal only sets a flag and wakes the loop through a pipe. Raising
    # from the handler would be swallowed if it landed inside a Wayland
    # callback (pywayland catches exceptions there), and the helper would
    # keep running after pkill.
    stop_r, stop_w = os.pipe()
    os.set_blocking(stop_r, False)
    os.set_blocking(stop_w, False)
    stopped = []
    signal.set_wakeup_fd(stop_w)
    for signum in (signal.SIGTERM, signal.SIGINT, signal.SIGHUP):
        signal.signal(signum, lambda _signum, _frame: stopped.append(True))
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
        if not app.start():
            print("unsupported: a pointer on the seat", flush=True)
            return 3
        app.run(stop_r, lambda: bool(stopped))
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
