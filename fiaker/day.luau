--!nonstrict
-- [[desktop_widget]] - the day timeline with the live now-line.
--
-- Ticks every 30s purely to move the line. The tick is cheap: it re-plans the
-- day from events already in memory, no I/O. Paging days writes selected_date,
-- which the month grid follows.

local date = require("./lib/date.luau")
local view = require("./lib/view.luau")

local events = {}
local dayTs = date.startOfDay(os.time())

local function render()
  desktopWidget.render(view.dayTree({
    dayTs = dayTs,
    events = events,
    nowUnix = os.time(),
    hourFrom = noctalia.getConfig("hour_from"),
    hourTo = noctalia.getConfig("hour_to"),
    pxPerMinute = noctalia.getConfig("px_per_minute"),
    accent = noctalia.getConfig("accent"),
    nowColor = noctalia.getConfig("now_color"),
    showAllDay = noctalia.getConfig("show_all_day"),
    onStep = function(delta)
      noctalia.state.set("selected_date", date.iso(date.addDays(dayTs, delta)))
    end,
  }))
end

noctalia.state.watch("events", function(value)
  events = value or {}
  render()
end)

noctalia.state.watch("selected_date", function(value)
  local ts = date.fromIso(value)
  if ts then
    dayTs = ts
    render()
  end
end)

-- Moves the now-line. 30s keeps it under half a minute of drift without
-- re-rendering more than necessary.
noctalia.setUpdateInterval(30000)

function update() render() end
function onConfigChanged() render() end

-- watch() only fires on change: seed from what the service already published.
events = noctalia.state.get("events") or {}
do
  local ts = date.fromIso(noctalia.state.get("selected_date"))
  if ts then dayTs = ts end
end

render()
