# Fiaker — a better calendar plugin for Noctalia v5

Researched against the installed **noctalia 5.1.0** binary and upstream `main`
(`docs/user/plugins/development/*`, `docs/plugin-api.json`, `src/calendar/*`, `src/scripting/*`)
on 2026-09-21.

**Decisions taken:** Google Calendar data fed from Noctalia itself · both desktop widgets *and*
bar widget + panel · full box-splitting now-line from the start.

---

## 1. What a Noctalia v5 plugin is written in

**Luau** — Roblox's gradually-typed Lua dialect. Not QML.

> v4 was QML/quickshell (archived as `noctalia-qs` and `legacy-v4-plugins`). **v5 is a native
> C++/Wayland/OpenGL-ES shell with no Qt and no GTK.** Every v4 plugin tutorial is dead weight.

A plugin is a directory:

```
noctalia-fiaker/      # repo root - the plugin lives here
  plugin.toml          # manifest: id, version, plugin_api, entries, settings schema
  ingest.luau          # [[service]]
  month.luau           # [[desktop_widget]]
  day.luau             # [[desktop_widget]]
  melange.luau         # [[panel]]
  next.luau            # [[widget]]
  lib/
    date.luau          # week/month math
    layout.luau        # lane assignment + box splitting
    model.luau         # shared event normalization
    view.luau          # the ui.* trees
    source*.luau       # backend picker + the two backends
```

- **Manifest** `plugin.toml`: `id = "author/plugin"`, `version` strictly `MAJOR.MINOR.PATCH`,
  `plugin_api = <int>` (mandatory compat gate).

> **Your installed 5.1.0 supports plugin_api 3–30, not 32.** Levels 31 (`get-color`) and
> 32 (`container-tooltip`) carry `"noctaliaVersion": null` in `docs/plugin-api.json` — unreleased
> on `main` — and `getColor` does not appear in the 5.1.0 binary's symbol strings.
> **Do not call `noctalia.getColor()`**, and set `plugin_api` to the lowest level you actually
> need (likely 26 for `getSetting`, or 23 for `readFileAsync`), never to the tip.
- **Entry kinds**: `[[widget]]`, `[[shortcut]]`, `[[launcher_provider]]`, `[[desktop_widget]]`,
  `[[panel]]`, `[[service]]`.
- **UI is a declarative tree**: `ui.box / row / column / scroll / label / glyph / image / button /
  input / select / slider / toggle / progress / graph / markdown / separator / spacer`.
- **Modules**: `require("./lib/date.luau")` — relative, must end `.luau`, hot-reloads the owner.
- **Luau stdlib is present**: `os.time()`, `os.date("*t", ts)`, `math.*`, `string.*`.
  Weekday / days-in-month / DST math is ordinary Lua.
- **Tooling**: `noctalia plugins lint <path>`, `noctalia msg plugin <id>:<entry> <event> <payload>`.
- Plugins are **trusted code** — filesystem and subprocess helpers are explicitly not sandboxed.

---

## 2. Getting Google data *from Noctalia* — this needs a small core patch

You want Noctalia to feed the plugin. Today it cannot:

1. `docs/plugin-api.json` — API levels 3→32, **no calendar capability at any level**.
2. The full `noctalia.*` surface (~70 functions) has nothing calendar-related.
3. The on-disk cache is `events.json`, **encrypted against the Secret Service keyring**
   (`failed to authenticate or read encrypted calendar cache`). Reading it externally is a dead end.
4. Google auth is brokered through `api.noctalia.dev/v1/calendar/oauth/google` — a plugin
   cannot reuse that token.

**But the patch to fix this is genuinely small**, and that is the good news:

```cpp
// src/calendar/calendar_service.h — ALREADY public, const, read-only:
[[nodiscard]] bool hasData() const noexcept { return m_snapshot.valid; }
[[nodiscard]] const CalendarSnapshot& snapshot() const noexcept { return m_snapshot; }
```

```cpp
// src/calendar/calendar_types.h — ALREADY exactly the shape a plugin wants.
// Note the comment: "Recurring events are expanded server-side, so every instance
// carries its own resolved start/end." -> no RRULE work in the plugin at all.
struct CalendarEvent {
  std::string id, title, calendarName, colorHex, location, url;
  std::chrono::system_clock::time_point start, end;
  bool allDay = false;
};
```

So the merged, recurrence-expanded, multi-account event list already exists in-process. It just
isn't reachable from Luau. The binding follows the existing `luau_systemStats` pattern in
`src/scripting/luau_host.cpp:429` exactly:

```cpp
// noctalia.calendar.events(startUnix?, endUnix?) -> array of event tables, or nil
int luau_calendarEvents(lua_State* L) {
  auto* svc = calendarServiceForState(L);        // mirrors runningMonitorForState()
  if (svc == nullptr || !svc->hasData()) { lua_pushnil(L); return 1; }

  const double from = luaL_optnumber(L, 1, 0);
  const double to   = luaL_optnumber(L, 2, 0);

  const CalendarSnapshot& snap = svc->snapshot();
  lua_createtable(L, static_cast<int>(snap.events.size()), 0);
  int i = 1;
  for (const CalendarEvent& e : snap.events) {
    const double s = unixSeconds(e.start), en = unixSeconds(e.end);
    if (from > 0 && en < from) continue;
    if (to   > 0 && s  > to)   continue;
    lua_createtable(L, 0, 9);
    setTableString(L, "id", e.id);
    setTableString(L, "title", e.title);
    setTableString(L, "calendar", e.calendarName);
    setTableString(L, "color", e.colorHex);
    setTableString(L, "location", e.location);
    setTableString(L, "url", e.url);
    setTableNumber(L, "startUnix", s);
    setTableNumber(L, "endUnix", en);
    setTableBoolean(L, "allDay", e.allDay);
    lua_rawseti(L, -2, i++);
  }
  return 1;
}
```

Two things to check before promising it's small:

- **Reachability** — `runningMonitorForState(L)` exists because someone plumbed `SystemMonitor`
  into the Luau host context. If `CalendarService` isn't already reachable the same way, the patch
  also touches `plugin_runtime_context.h` and `application_plugins.cpp` to hand the host a pointer.
  Still small, but it's more than one file.
- **Thread affinity** — `readFileAsync` is documented as reading "outside plugin VM workers",
  which implies entry VMs may run off the main thread. `snapshot()` returns a `const&` to
  `m_snapshot`, which `accountDone()` mutates. `monitor->latest()` returns a *copy* — check whether
  it locks. If VMs are off-thread, the binding must copy under a mutex or marshal through the main
  thread rather than hand out the reference. Settle this before shaping the signature.

Scope of the PR — roughly 120 lines including docs, assuming reachability is already there:

- `luau_host.cpp`: the function above + registration in the `noctalia.calendar` table.
- `plugin_api.h`: `kCalendarEventsPluginApiVersion = 33`.
- `docs/plugin-api.json`: one `calendar-events` row at level 33.
- `docs/user/plugins/development/runtime-api.mdx`: one table row + a short section.
- Optional second call: `noctalia.calendar.syncState()` → `{ valid, lastSyncMs, accounts }`.

**Change notification:** for v1, don't add a hook. The service entry calls
`setUpdateInterval(60000)` and re-reads `snapshot()`; it's cheap (a vector walk) and avoids
touching the event loop. A `onCalendarChanged()` callback can follow later.

**No open issue requests this** (searched `noctalia-dev/noctalia`, all states — only user-facing
calendar features like #3996 vdir, #3158 per-collection CalDAV). Worth filing before you write it,
to confirm the maintainers want the API shaped this way. This is the kind of self-contained
addition that lands well, and it unblocks every future calendar plugin, not just yours.

### Fallback while the patch is unmerged

`provider = "vdir"` **is supported in your installed 5.1.0** (confirmed: `CalendarService::VdirWorker`,
`settings.calendar-accounts.vdir-path-label`). Run `vdirsyncer` against Google, point both
Noctalia's account **and** the plugin at that directory. The plugin reads `.ics` with
`listDir` + `readFileAsync` and parses VEVENT in Luau.

**Don't write an RRULE engine in Luau.** On the vdir path recurrence expansion comes back, and it
is the single heaviest piece of the project. Shell out instead — `noctalia.runAsync({"khal", ...})`
expands recurrences for you (check whether your `khal` build has a machine-readable output mode);
`gcalcli` is the Google-native equivalent. Only hand-roll VEVENT parsing if neither is acceptable.

Keep the ingest service behind one interface so this is a swappable backend:

```lua
-- lib/source.luau
if noctalia.calendar then return require("./source_native.luau") end
return require("./source_vdir.luau")
```

Then the patch landing is a one-line behavioural change, and the plugin works for users on
stock 5.1.0 either way. **Also**: `stundenglas` already does WebUntis → Google Calendar in Rust —
if it emitted `.ics` into a vdir, the fallback path costs you nothing extra.

> **Not proposed:** scraping the encrypted cache via `secret-tool`. Undocumented, and it will
> break without warning.

**Context:** no calendar plugin exists in either `official-plugins` or `community-plugins`.
The space is open.

---

## 3. Architecture

**One plugin, five entries.** This is forced, not stylistic: the `noctalia.state` channel is
**per-plugin**. Two separate plugins could never sync selection. Separating "calendar" from
"events" means separating *widgets*, not *plugins*.

| Entry | Kind | Job |
|-------|------|-----|
| `ingest` | `[[service]]` | Poll the snapshot, normalize, publish to state |
| `month` | `[[desktop_widget]]` | Month grid, event dots, click to select |
| `day` | `[[desktop_widget]]` | Google-style timeline with the now-line |
| `melange` | `[[panel]]` | Both views in a popup, for the bar |
| `next` | `[[widget]]` | Bar: "Mathe in 25 min", click opens `melange` |

Everything stays in sync for free — all five watch the same keys.

### State contract

```lua
noctalia.state.set("events", { ... })              -- ingest -> everyone
noctalia.state.set("selected_date", "2026-09-21")  -- any view -> every other view
noctalia.state.set("view_month", "2026-09")        -- which month the grid is showing
noctalia.state.set("sync", { valid = true, lastMs = ..., error = nil })
```

- `ingest` publishes a **±45-day window**, not just the selected day — the month grid needs dots
  on every cell, and paging months must not trigger a refetch.
- Clicking a cell calls `state.set("selected_date", iso)`; `day`, `melange` and `next` re-render.
  Symmetric: paging days in `day` moves the grid's highlight and may bump `view_month`.
- Values are **copied** between entries — plain data only, no functions.
- The channel is **in-memory only** and clears when the plugin stops. Persist the last snapshot to
  `noctalia.pluginDataDir()` so a restart paints instantly, then refreshes.

### Normalized event shape

```lua
{ id, title, calendar, color, location, url, startUnix, endUnix, allDay }
```

Straight from `CalendarEvent`. **Recurrence is already expanded upstream** — the single biggest
piece of work you would otherwise have owned, gone. (On the vdir fallback you *do* own RRULE.
One more reason to push the patch.)

---

## 4. The timeline

Layout is **flexbox only**: no absolute positioning, no z-stacking, no canvas. Every node takes
`width` / `height` / `flexGrow`. You compute geometry in Luau and emit sized boxes.

```
ui.row
├─ gutter      ui.column of fixed-height hour labels (08:00, 09:00, …)
└─ events      ui.row of lanes; each lane a ui.column of
               [spacer h=…] [event ui.box h=…] [spacer h=…] …
```

- **Overlapping events** → lane assignment in Luau (greedy interval colouring), rendered as a
  `ui.row` of columns.
- **Positioning** → events sorted per lane, spacers computed between them.
- **The now-line (full box-splitting, as chosen)** — `offset = pxPerMinute * minutesSinceStart`:
  - Falls in a **gap** → split the spacer: `[spacer][2px ui.box][spacer]`.
  - Falls **inside an event** → split the event: `[top ui.box][2px line][bottom ui.box]`,
    title in the top part, both halves sharing the event's fill and radius.
  - Do the split **per lane** — the line crosses every lane at the same `y`, so each lane
    independently decides gap-split vs event-split. That is what makes it read as one
    continuous line across the full width.
  - Watch the corners: an event split near its top or bottom edge leaves a sliver. Clamp —
    below ~4px, drop the sliver and nudge the line to the boundary.
- **Refresh** → `setUpdateInterval(60000)` in `day`. Use `noctalia.nowMs()` to phase the tick onto
  the minute boundary so the line doesn't jump late.
- **Colors** → use **palette role tokens directly in props** — `fill = "error"` for the now-line,
  `"primary/0.6"` for a translucent event box. These resolve live against the theme and work at
  every API level. (`noctalia.getColor()` is level 31 and **not in your 5.1.0** — avoid it.)
  Event colors come from `e.color` (the calendar's own hex) with a role fallback when empty.

---

## 5. Name — decided

**Fiaker** — Viennese coffee with rum, and the horse carriage that gets you places on time.

Chosen over **Melange** on collision grounds: `melange` is taken by Chainguard's APK build tool,
the OCaml/ReasonML compiler, and — worst for us — `melange-nvim`, a Neovim colorscheme sitting in
the same Linux-ricing space this plugin lives in. `fiaker` returns only two unrelated personal
profile repos. Neither name collides in the Noctalia catalogs.

Melange survives as an entry id: the merged multi-calendar panel is `<author>/fiaker:melange` —
the blend of every calendar you sync.

> Plugin `id` is `author/plugin`. `137-Trimethylxanthin/fiaker` is unwieldy in a catalog row —
> pick a short author slug (`137-trimethylxanthin/fiaker`, `trimethyl/fiaker`). Check the id character rules in
> `plugin_manifest.cpp` before committing.

## 6. Phasing

**Done** (lints clean, 40 logic assertions passing):

- [x] Manifest with all five entries and the shared settings schema
- [x] `lib/date.luau` — DST-safe day/month arithmetic, 6×7 grid, locale weekday headers
- [x] `lib/model.luau` — the normalized event shape, day slicing, per-day counts
- [x] `lib/layout.luau` — lane assignment and full now-line box-splitting
- [x] `lib/view.luau` — both ui.* trees, shared by all three surfaces
- [x] `lib/source*.luau` — backend picker, native stub, vdir + ICS parser
- [x] All five entries wired through `noctalia.state`
- [x] EN + DE translations
- [x] `test/run.sh` — transpiles the pure modules to Lua 5.4 and asserts the math

**Next**, in order:

1. **Run it.** Add the path source, enable, place the widgets. Nothing below matters until the
   trees have actually rendered on screen.
2. **Point it at real data** — `vdirsyncer` into `~/.calendars`, and set Noctalia's own account to
   `provider = "vdir"` on the same path.
3. **Tune the timeline** against a real school day: zoom, hour range, lane widths, how a 50-minute
   period reads at `px_per_minute = 1.2`.
4. **The core patch** — file the issue, write `noctalia.calendar.events()`, flip `source` to
   `native`. This is what makes it *fed from Noctalia*, and it deletes the RRULE problem.
5. Week view, if wanted — `lib/layout.luau` goes from one lane set to seven.
6. `noctalia plugins lint`, catalog submission to `community-plugins`.

## 7. Still open

1. **Month grid** — true 7×6 month with leading/trailing days, or a rolling 30 days from today?
2. **Timeline range** — fixed hours (06:00–24:00), or auto-fit to the day's events?
   Fixed is calmer; auto-fit wastes less space on a light day.
3. **Week view** — day only, or is a 7-column week the real goal? It changes `lib/layout.luau`
   from one lane set to seven.
4. **Multi-monitor** — both desktop widgets on one output, or `month` and `day` on different ones?
5. **UI language** — DE, EN, or both via `noctalia.tr`?
6. **Publishing** — `community-plugins`, or personal use? Changes how much the settings schema
   and i18n matter.
7. **Are you up for the C++ patch?** If not, the vdir path is the whole plan and step 6 drops.
