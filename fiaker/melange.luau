--!nonstrict
-- [[panel]] - "melange": every calendar blended into one surface.
--
-- The month grid and the day timeline side by side, built from the same
-- lib/view trees the desktop widgets use. It watches the same state keys, so
-- selecting a day here moves the desktop widgets too, and vice versa.

local date = require("./lib/date.luau")
local model = require("./lib/model.luau")
local view = require("./lib/view.luau")

local events = {}
local counts = {}
local dayTs = date.startOfDay(os.time())
local viewYear = tonumber(os.date("%Y", os.time()))
local viewMonth = tonumber(os.date("%m", os.time()))
local sync = nil
local open = false

local function statusText(): string
  if sync == nil then return noctalia.tr("status.waiting") end
  if sync.error then return noctalia.tr("status.error", { error = sync.error }) end
  return noctalia.tr("status.ok", { backend = sync.backend or "?" })
end

local function render()
  if not open then return end

  local left = view.monthTree({
    year = viewYear, month = viewMonth,
    selectedIso = date.iso(dayTs),
    counts = counts,
    nowUnix = os.time(),
    weekStart = noctalia.getConfig("week_start"),
    accent = noctalia.getConfig("accent"),
    onSelect = function(iso) noctalia.state.set("selected_date", iso) end,
    onStep = function(delta)
      local ts = date.addMonths(date.mktime({ year = viewYear, month = viewMonth, day = 1, hour = 12 }), delta)
      noctalia.state.set("view_month", os.date("%Y-%m", ts))
    end,
  })

  local right = view.dayTree({
    dayTs = dayTs,
    events = events,
    nowUnix = os.time(),
    hourFrom = noctalia.getConfig("hour_from"),
    hourTo = noctalia.getConfig("hour_to"),
    pxPerMinute = noctalia.getConfig("px_per_minute"),
    accent = noctalia.getConfig("accent"),
    nowColor = noctalia.getConfig("now_color"),
    showAllDay = noctalia.getConfig("show_all_day"),
    scrollable = true,  -- the panel has a fixed height to scroll inside
    onStep = function(delta)
      noctalia.state.set("selected_date", date.iso(date.addDays(dayTs, delta)))
    end,
  })

  panel.render(ui.column({ gap = 0, flexGrow = 1 }, {
    ui.row({ gap = 0, flexGrow = 1 }, {
      ui.column({ width = 300 }, { left }),
      ui.separator({ orientation = "vertical", spacing = 4 }),
      ui.column({ flexGrow = 1 }, { right }),
    }),
    ui.separator({ spacing = 0 }),
    ui.row({ align = "center", gap = 8, paddingH = 10, paddingV = 4 }, {
      ui.label({ text = statusText(), fontSize = 9,
                 color = "on_surface_variant", flexGrow = 1 }),
      ui.button({ text = noctalia.tr("action.today"), variant = "ghost", controlSize = "sm",
                  onClick = function()
                    noctalia.state.set("selected_date", date.iso(os.time()))
                    noctalia.state.set("view_month", os.date("%Y-%m", os.time()))
                  end }),
      ui.button({ glyph = "refresh", variant = "ghost", controlSize = "sm",
                  tooltip = noctalia.tr("action.refresh"),
                  onClick = function() noctalia.state.set("refresh_request", noctalia.nowMs()) end }),
      ui.button({ glyph = "settings", variant = "ghost", controlSize = "sm",
                  onClick = function() noctalia.openSettings() end }),
    }),
  }))
end

noctalia.state.watch("events", function(value)
  events = value or {}
  counts = model.countsByDay(events)
  render()
end)

noctalia.state.watch("selected_date", function(value)
  local ts = date.fromIso(value)
  if ts then
    dayTs = ts
    viewYear = tonumber(os.date("%Y", ts))
    viewMonth = tonumber(os.date("%m", ts))
    render()
  end
end)

noctalia.state.watch("view_month", function(value)
  local y, m = string.match(tostring(value), "^(%d%d%d%d)%-(%d%d)$")
  if y then
    viewYear, viewMonth = tonumber(y), tonumber(m)
    render()
  end
end)

noctalia.state.watch("sync", function(value)
  sync = value
  render()
end)


-- watch() only fires on change, so seed from whatever the service already
-- published; a widget added or hot-reloaded later would otherwise stay blank
-- until the next fetch.
local function seed()
  events = noctalia.state.get("events") or {}
  counts = model.countsByDay(events)
  sync = noctalia.state.get("sync")
  local ts = date.fromIso(noctalia.state.get("selected_date"))
  if ts then
    dayTs = ts
    viewYear = tonumber(os.date("%Y", ts))
    viewMonth = tonumber(os.date("%m", ts))
  end
end

function onOpen()
  open = true
  seed()
  panel.setWantsSecondTicks(true)
  render()
end

function onClose()
  open = false
  panel.setWantsSecondTicks(false)
end

-- Second ticks while open; only re-render when the minute actually turns, so
-- the now-line stays live without rebuilding the tree 60x a minute.
local lastMinute = -1
function update()
  local m = tonumber(os.date("%M", os.time()))
  if m ~= lastMinute then
    lastMinute = m
    render()
  end
end

function onConfigChanged() render() end
