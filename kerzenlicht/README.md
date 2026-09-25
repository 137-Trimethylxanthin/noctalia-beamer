# Kerzenlicht — find your cursor

**A [Noctalia](https://noctalia.dev) shell plugin that shows you where your
mouse cursor is.** When a message comes in or at the press of a key, a small
light flashes on the cursor. Shake the mouse, and every screen dims except
where the cursor is. And a soft white glow can follow the cursor for as long
as you like, for screen shares and talks. One key or one tile each; everything
underneath keeps working.

![Kerzenlicht: a soft white glow around the mouse pointer over syntax-highlighted code in a terminal](screenshots/glow.webp)

*Kerzenlicht* is German for candlelight: the small, warm glow of the candle on
a coffee-house table, lighting that one spot and nothing more. This one
follows your mouse.

- **See that a message came in,** with the sound off or your eyes on another
  screen: a bright white light fades in on the cursor, stays a second and a
  half, and fades out. If an app had hidden the cursor (a terminal while you
  type, a player over a video), it comes back too: the flash nudges the
  mouse three pixels and back, which is what wakes it. Only for new messages, never while Do Not Disturb is
  on, and only from the apps you pick if you like.
- **Find your cursor.** On a big monitor, or three of them, shake the mouse
  (six times left and right): the dark closes in from the edges of the screen
  onto a brighter spot where the cursor is, in a third of a second, and stays
  for as long as you keep shaking. Stop, and it opens out again the same way,
  just as fast. Screens without the cursor fade in and out alongside.
- **Show people where you are pointing.** In a screen share, a recording or a
  talk, a glow is easier to follow than a 24-pixel arrow, and it shows up in
  every capture because it is a real surface.
- **Never in the way.** The light is click-through: clicks, typing, scrolling
  and dragging go straight to the window below.
- **Everywhere Noctalia runs,** not only on Hyprland: no screen shader, no
  compositor plugin, no config to edit.

## Plugin

| Field | Value |
| --- | --- |
| ID | `137-trimethylxanthin/kerzenlicht` |
| Entries | Service: `watch`; shortcut: `toggle` |

## Requirements

- [`uv`](https://docs.astral.sh/uv/). The light is a small Python Wayland
  client, and uv fetches its one dependency,
  [pywayland](https://pypi.org/project/pywayland/), the first time it starts.
  That first start needs a network connection and takes a few seconds; later
  starts are instant.
- `pkill` and `pgrep` (procps), to stop it.
- `busctl` (systemd), to see messages come in. Without it everything else
  works, and messages do not flash.
- A compositor with cursor sessions, see [Compositors](#compositors).

Missing tools are reported as soon as you ask for a flash or the glow.

## Usage

The flashes need nothing: once the plugin is enabled, messages and shakes
flash on their own. The service takes these IPC events, to bind to keys:

```sh
noctalia msg plugin 137-trimethylxanthin/kerzenlicht:watch all flash    # a flash, now
noctalia msg plugin 137-trimethylxanthin/kerzenlicht:watch all toggle   # the glow on / off
noctalia msg plugin 137-trimethylxanthin/kerzenlicht:watch all on
noctalia msg plugin 137-trimethylxanthin/kerzenlicht:watch all off
```

In `hyprland.lua`:

```lua
hl.bind("SUPER + SHIFT + F",   hl.dsp.exec_cmd("noctalia msg plugin 137-trimethylxanthin/kerzenlicht:watch all flash"))
hl.bind("SUPER + CONTROL + F", hl.dsp.exec_cmd("noctalia msg plugin 137-trimethylxanthin/kerzenlicht:watch all toggle"))
```

In `hyprland.conf`:

```
bind = SUPER SHIFT, F, exec, noctalia msg plugin 137-trimethylxanthin/kerzenlicht:watch all flash
bind = SUPER CTRL, F, exec, noctalia msg plugin 137-trimethylxanthin/kerzenlicht:watch all toggle
```

In sway's config:

```
bindsym $mod+Shift+f exec noctalia msg plugin 137-trimethylxanthin/kerzenlicht:watch all flash
bindsym $mod+Ctrl+f exec noctalia msg plugin 137-trimethylxanthin/kerzenlicht:watch all toggle
```

In niri's `config.kdl`:

```kdl
binds {
    Mod+Shift+F { spawn "noctalia" "msg" "plugin" "137-trimethylxanthin/kerzenlicht:watch" "all" "flash"; }
    Mod+Ctrl+F { spawn "noctalia" "msg" "plugin" "137-trimethylxanthin/kerzenlicht:watch" "all" "toggle"; }
}
```

The tile, under **Settings → Control Center shortcuts**, switches the glow;
right-click it for a flash.

**Presenting?** Switch on **Also Do Not Disturb** in the settings: the glow
then turns Do Not Disturb on with it, and puts it back the way it was when the
glow goes off. Messages do not flash while it is on. Pair it with
[Goschen](../goschen/README.md) and Discord keeps quiet too.

### Which messages flash

Every new notification, unless:

- Do Not Disturb is on;
- it only updates one that is already showing: a player's next track, a
  download's progress, a volume popup;
- it is sent with low urgency, the way apps mark background chatter;
- **Only these apps** is set, and the app is not on it. Names are matched
  against the app name the notification carries and its `desktop-entry` hint,
  ignoring case. To see what an app sends, run
  `busctl --user monitor --match "member='Notify'"` and wait for one.

## Settings

| Setting | Default | |
| --- | --- | --- |
| Flash size | `18` | The light a message or the flash key puts on the cursor, in logical pixels (5–400), nearly solid white |
| Flash length | `1.5` | Seconds a flash from a message or the key stays (0.3–10) |
| Dimming | `0.65` | How dark shaking makes everything but the cursor, from `0.1` to `0.9` |
| Flash for messages | On | A new notification flashes, see [Which messages flash](#which-messages-flash) |
| Only these apps | *(empty)* | Comma-separated app names; empty is every app |
| Dim when shaking the mouse | On | At least six times left and right, fast (twelve strokes of 110 pixels or more within 2 seconds). The screen stays dimmed around the cursor while you shake, and clears within a third of a second of stopping |
| Radius | `30` | The light at full strength around the cursor, in logical pixels (5–400) |
| Soft edge | `15` | How many pixels it takes to fade out (0–300) |
| Brightness | `0.6` | The white glow, from `0.1`, a hint, to `1`, solid white that covers what is under it |
| Also Do Not Disturb | Off | Turn Do Not Disturb on with the glow, and back afterwards |

Changing a setting applies it right away. Radius and soft edge shape both the
glow and the spot a shake leaves clear.

A bigger, brighter glow (radius `40`, soft edge `25`, brightness `0.85`):

![A larger, brighter glow over code](screenshots/strong.webp)

## Compositors

Wayland does not tell programs where the cursor is, with one exception: a
*cursor session* from `ext-image-copy-capture-v1`, which screen recorders use
to draw the cursor themselves. Kerzenlicht opens one per monitor and reads only
the position. It never captures a frame or reads what is on your screen. The
glow itself is a transparent `wlr-layer-shell` surface on the overlay layer,
with an empty input region.

| Compositor | Status |
| --- | --- |
| **Hyprland** | Tested on 0.56: the glow with two monitors at different scales, the flash across three at scale 1 |
| **Sway, Scroll, MangoWC, Labwc, dwl, River/Triad** | Cursor sessions since wlroots 0.19; not tested yet |
| **niri** | Needs a build newer than v26.04: cursor sessions were merged on 12 September 2026 |
| **Umbriel** | Built on wlroots 0.20; not tested yet |

**Scaled screens.** Cursor sessions report positions in physical pixels, as
the protocol says, and wlroots and niri do exactly that; Hyprland reports
logical ones. Kerzenlicht reads each output's logical size from
`xdg-output` at start and scales accordingly, so the light sits on the cursor
at any scale from the first flash on.

**A mouse plugged in later.** A Bluetooth or KVM mouse that connects after
login, or one unplugged and plugged back in, is picked up as it appears.

**wlroots compositors and software cursors.** On wlroots, a cursor session only
reports the position while the monitor uses a hardware cursor. With a software
cursor the light goes out on that monitor: with `WLR_NO_HARDWARE_CURSORS=1`, in
nested sessions, on some NVIDIA setups, and while another program records that
monitor with the cursor painted in. Hyprland and niri are not affected.

On a compositor without them, switching it on tells you which protocol is
missing and stays off. There is no fallback, because without a cursor session
there is no standard way to know where the cursor is.

## How it stays out of the way

**Nothing is left behind.** The light is its own process and sends the shell a
heartbeat once a second. If the shell goes away, the next heartbeat hits a
closed pipe and the light quits; if the light goes away, the shell sees it
exit and starts it again, a little later each time, and gives up after a few
tries. Its surfaces vanish the moment its connection closes, however it ends.
Stopping it waits until it is really gone, and kills it outright if it does not
go within two seconds. It is off when Noctalia quits or the plugin is
disabled; after a reload the glow comes back as it was.

**Cheap to run.** While nothing shows, the light holds no surfaces and no
buffers: it only follows the cursor, which is what telling a shake needs, and
waits. Moving a light that shows does not redraw the screen: only the squares
that changed, where the light was and where it is now, are repainted and sent
to the compositor, at most once per frame. The circle closing in and opening out is
the exception: for its third of a second the whole screen is drawn every frame, from runs of
equal pixels rather than pixel by pixel, which keeps a 1920×1080 frame under
25 ms. Flashes fade in and out with
`wp-alpha-modifier-v1`, which changes the surface's opacity without
repainting it; without that protocol they come and go at once.

**Commands are signals.** The shell tells the light to flash or to glow with
`SIGUSR1` and `SIGUSR2`, sent to the pid it writes itself, and the light says
back whether it glows. The tile shows what the light says, not what was asked.

**Screenshots and screen sharing show it,** which is the point when you are
presenting. The screenshots above are exactly that: `grim` with the light on.

**HiDPI.** The light is drawn at logical resolution and scaled by the
compositor, so on a scaled screen its edge is a touch softer.

## Tests

`./tests/kerzenlicht/run.sh` covers the pixel math: the glow, the dimming and
its hole, the two together, their symmetry, clipping at the screen edges and
repainting the old square; and the shake detector: back and forth counts,
sideways and vertical, and moving across the screen, a wobble, strokes that
are too short or too slow, one flick and a pause do not. The light itself has
been run on Hyprland 0.56 across three monitors: flashes by signal, the glow
switched on and off by file and signal, and both at once.
