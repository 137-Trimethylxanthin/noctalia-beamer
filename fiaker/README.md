# Fiaker

A calendar for [Noctalia](https://noctalia.dev) v5 that keeps the **month grid** and the
**day timeline** as separate widgets, and keeps them in sync.

Named after the Viennese coffee — and the carriage that gets you places on time.

![status](https://img.shields.io/badge/status-early-orange)

## What it does

- **Month grid** (desktop widget) — 6×7 cells, event dots, click a day to select it.
- **Day timeline** (desktop widget) — Google-style: hour gutter, overlapping events in
  side-by-side lanes, and a **live now-line** that runs the full width.
- **Melange** (panel) — both views side by side, for the bar.
- **Next up** (bar widget) — "Mathematik · in 25 min", click to open the panel.

Click a day anywhere and every other view follows. That works because all five entries live in
one plugin: `noctalia.state` is a **per-plugin** channel, so this sync is only possible inside a
single plugin — separating "calendar" from "events" means separating *widgets*, not *plugins*.

## Where events come from

Noctalia's plugin API does **not** expose the built-in calendar's events (no calendar capability
at any API level, and the on-disk cache is encrypted against the Secret Service keyring). So there
are two backends behind one interface — `lib/source.luau` picks at load:

| `source` | Backend | Notes |
|----------|---------|-------|
| `auto` | native if present, else vdir | the default |
| `native` | `noctalia.calendar.events()` | **needs a core patch that does not exist yet** — see `PROPOSAL.md` §2 |
| `vdir` | a directory of `.ics` files | works on stock Noctalia 5.1.0 today |

### The vdir path (works now)

`vdirsyncer` syncs Google/CalDAV into a directory of `.ics` files. Point **both** Noctalia's own
calendar account (`provider = "vdir"`) **and** this plugin at that directory, and they can never
disagree.

```toml
# ~/.config/noctalia/config.toml
[calendar.account.personal]
provider = "vdir"
path     = "~/.calendars"
```

Then set the plugin's **vdir path** to the same folder.

**Limitations of this backend**, both of which vanish on the native backend:

- **No RRULE expansion.** A recurring event shows only its first instance, and the count of
  skipped repeats is logged. Writing an iCalendar recurrence engine in Luau is not worth it —
  `khal` already does it, and so does Noctalia itself.
- **`TZID` is read as local wall-clock time.** Correct for your own calendars in your own
  timezone; wrong for an event pinned to another zone.

### The native path (needs a core patch)

`CalendarService::snapshot()` is already public and const, and `calendar_types.h` states that
*"recurring events are expanded server-side, so every instance carries its own resolved
start/end"*. The data is merged, expanded and in-process — it simply isn't reachable from Luau.
`PROPOSAL.md` §2 sketches the binding.

## Install

Noctalia loads plugins from a git or path source:

```sh
noctalia msg plugins source add fiaker git https://github.com/137-Trimethylxanthin/noctalia-fiaker

# ...or from a local checkout while developing:
# noctalia msg plugins source add fiaker path ~/Documents/code/noctalia-fiaker
noctalia msg plugins enable 137-trimethylxanthin/fiaker
```

Then add the widgets: **Settings → Desktop Widgets** for `month` and `day`, **Settings → Bar** for
`next`. Open the panel with:

```sh
noctalia msg panel-toggle 137-trimethylxanthin/fiaker:melange
```

## Layout

```
plugin.toml          manifest: 5 entries + the shared settings schema
ingest.luau          [[service]]        the only entry that touches a data source
month.luau           [[desktop_widget]] month grid
day.luau             [[desktop_widget]] timeline
melange.luau         [[panel]]          both views + status line
next.luau            [[widget]]         bar
lib/date.luau        calendar arithmetic (DST-safe)
lib/model.luau       the normalized event shape and its slices
lib/layout.luau      lane assignment + now-line geometry
lib/view.luau        the ui.* trees, shared by all three surfaces
lib/source*.luau     the two backends and the picker
```

### How the now-line works

Noctalia's UI tree is **flexbox only** — no absolute positioning, no z-stacking, no canvas. A line
cannot be drawn *over* anything, so it is drawn *between* things:

- where it falls in a **gap** → the gap splits into `[gap][line][gap]`
- where it falls in an **event** → the event splits into `[top][line][bottom]`, with the title in
  whichever half has room

Every lane splits independently at the same `y`, which is what makes it read as one continuous
line. Splits closer than 4px to an edge snap to the boundary so no hairline slivers appear.

### Sizing the day widget

A desktop widget sizes itself from its tree and has nothing to scroll inside, so the timeline's
height is simply **(last hour − first hour) × 60 × zoom**. At the defaults (07–22, `0.6`) that is
about 540px. Raise `hour_from` / lower `hour_to` before raising the zoom. The panel is
height-bounded, so its copy of the timeline scrolls and can be zoomed freely.

### Deliberately missing

`tooltip` on a container (`ui.column` / `ui.row` / `ui.box`) is plugin API **32**, which Noctalia
5.1.0 does not have — so month cells and event boxes carry no hover tooltip yet. Unknown props are
logged and skipped, and the timeline re-renders every 30s, so using it would only fill the log.
Worth revisiting once 5.2 ships.

## Development

Both commands run from the repository root, one level up from this directory:

```sh
noctalia plugins lint fiaker   # cross-checks declared settings against getConfig() calls
./test/run.sh                  # pure-logic tests (date math, lanes, now-line, ICS parser)
```

Editing any `.luau` file hot-reloads its entry.

## Requirements

- Noctalia **5.1.0+** (`plugin_api = 23`; 5.1.0 supports 3–30)
- `vdirsyncer` for the vdir backend
- `lua5.4` and `python3` to run the tests

## Design notes

[`PROPOSAL.md`](PROPOSAL.md) is the design doc behind this plugin: what a Noctalia v5 plugin is
written in, why the built-in calendar's events are not reachable from a plugin today, the shape of
the core patch that would fix that, and the architecture the five entries follow.

## License

MIT
