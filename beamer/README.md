# Beamer — a Win+P display switcher for Hyprland

![Beamer in the Noctalia launcher: extend, duplicate, external only and laptop only](thumbnail.webp)

Hyprland has no "Win+P" menu. Mirroring exists, but only as a monitor rule you
write into your config and reload — which is not what you want thirty seconds
before a talk. Beamer puts the four layouts you actually reach for in the
launcher, on a control-center tile, and behind one IPC call you can bind to your
laptop's display key.

| Layout | What it does |
| --- | --- |
| Extend | External screen gets its own workspaces |
| Duplicate | External screen shows a copy of the built-in one |
| External only | Built-in screen off |
| Laptop only | External screen off |

## Plugin

| Field | Value |
| --- | --- |
| ID | `137-trimethylxanthin/beamer` |
| Entries | Launcher provider: `provider`; service: `control`; shortcut: `cycle` |
| Launcher Prefix | `/beam` |

## Requirements

Hyprland, with `hyprctl` on `PATH`. Beamer reads and writes monitor
configuration through it and does nothing on other compositors beyond saying so.

Both Hyprland config parsers are supported. Beamer applies rules with
`hyprctl keyword`, and falls back to `hyprctl eval` on the Lua parser, which
answers every `keyword` with *"keyword can't work with non-legacy parsers"*. The
parser is detected on the first switch and remembered for the session.

## Usage

Open the launcher and type `/beam`. Four rows appear; the one you are on is
marked **Active**, and picking another switches to it straight away. Typing
filters on the visible name and on the internal id, so both `duplicate` and
`mirror` land on the same row.

Plug the external screen in first. With nothing attached, every layout except
**Laptop only** is a no-op, and the rows say so instead of failing quietly.

The `cycle` shortcut is a control-center tile that steps to the next layout on
each click. Add it under **Settings → Control Center shortcuts**. The tile shows
the layout you are currently on.

To bind your laptop's display key, point it at the `control` service. In
`hyprland.conf`:

```
bind = , XF86Display, exec, noctalia msg plugin 137-trimethylxanthin/beamer:control all cycle
```

## IPC

The `control` service takes two events:

```sh
noctalia msg plugin 137-trimethylxanthin/beamer:control all cycle
noctalia msg plugin 137-trimethylxanthin/beamer:control all set mirror
```

`cycle` advances extend → duplicate → external only → laptop only → extend.
`set` takes one of `extend`, `mirror`, `external` or `internal`.

## Notes

**Extend re-applies your config.** There is no way to reconstruct the layout you
described in your own config — positions, scales, workspace rules — from the
outside, so **Extend** runs `hyprctl reload` instead of guessing. The practical
consequence runs the other way too: *any* Hyprland config reload puts you back
on Extend. If your shell re-applies a theme on wallpaper change, avoid changing
wallpaper mid-presentation.

**Aspect ratios.** Duplicate copies one framebuffer to both outputs. A 16:10
laptop panel on a 16:9 projector will letterbox. **External only** avoids it.

**Your panel's scale is preserved.** Beamer records the built-in screen's mode
and scale whenever it sees it running, and restores both when switching back, so
a HiDPI panel does not come back at scale 1. Every switch re-reads the monitors
first, so this is current; if Beamer has never seen the panel running, it falls
back to `preferred` and `auto`.

**The hyprlang path is untested.** Beamer was developed on Hyprland's Lua config
parser, so every switch the author has run went through `hyprctl eval`. The
`hyprctl keyword` branch is written against documented syntax but has not been
exercised on a real hyprlang setup. Reports welcome.

**It will not black out your session.** The built-in screen is only switched off
when an external one is attached and enabled.

**Side effects.** Beamer spawns `hyprctl` and nothing else. It makes no network
calls and writes no files; the remembered mode and scale live in the plugin's
own Noctalia state.
