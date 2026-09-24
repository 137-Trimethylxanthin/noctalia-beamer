--!nonstrict
-- [[desktop_widget]] - the month grid.
--
-- Owns no event logic: it watches the service's state and writes back exactly
-- one thing, selected_date. That single write is what makes the day timeline,
-- the panel and the bar widget all follow a click on a cell.

local date = require("./lib/date.luau")
local model = require("./lib/model.luau")
local view = require("./lib/view.luau")

local events = {}
local counts = {}
local selectedIso = date.iso(os.time())
local viewYear = tonumber(os.date("%Y", os.time()))
local viewMonth = tonumber(os.date("%m", os.time()))

local function render()
  desktopWidget.render(view.monthTree({
    year = viewYear,
    month = viewMonth,
    selectedIso = selectedIso,
    counts = counts,
    nowUnix = os.time(),
    weekStart = noctalia.getConfig("week_start"),
    accent = noctalia.getConfig("accent"),
    onSelect = function(iso)
      noctalia.state.set("selected_date", iso)
    end,
    onStep = function(delta)
      local ts = date.addMonths(date.mktime({ year = viewYear, month = viewMonth, day = 1, hour = 12 }), delta)
      viewYear = tonumber(os.date("%Y", ts))
      viewMonth = tonumber(os.date("%m", ts))
      noctalia.state.set("view_month", os.date("%Y-%m", ts))
      render()
    end,
  }))
end

noctalia.state.watch("events", function(value)
  events = value or {}
  counts = model.countsByDay(events)
  render()
end)

noctalia.state.watch("selected_date", function(value)
  if type(value) ~= "string" then return end
  selectedIso = value
  -- Follow the selection into its month, so a click in the timeline that
  -- crosses a month boundary does not leave the grid behind.
  local ts = date.fromIso(value)
  if ts then
    viewYear = tonumber(os.date("%Y", ts))
    viewMonth = tonumber(os.date("%m", ts))
  end
  render()
end)

noctalia.state.watch("view_month", function(value)
  local y, m = string.match(tostring(value), "^(%d%d%d%d)%-(%d%d)$")
  if y then
    viewYear, viewMonth = tonumber(y), tonumber(m)
    render()
  end
end)

function onConfigChanged() render() end

-- watch() only fires on change: seed from what the service already published.
events = noctalia.state.get("events") or {}
counts = model.countsByDay(events)
selectedIso = noctalia.state.get("selected_date") or selectedIso
do
  local ts = date.fromIso(selectedIso)
  if ts then
    viewYear = tonumber(os.date("%Y", ts))
    viewMonth = tonumber(os.date("%m", ts))
  end
end

render()
