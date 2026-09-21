--!nonstrict
-- [[widget]] - the bar entry: what is coming up next, and a way into the panel.
--
-- The manifest sets middle = "none" so onMiddleClick is free; without that,
-- every widget's built-in middle binding opens its settings instead.

local model = require("./lib/model.luau")

local events = {}

local function truncate(s: string, n: number): string
  if utf8.len(s) == nil or (utf8.len(s) :: number) <= n then return s end
  return string.sub(s, 1, (utf8.offset(s, n + 1) or #s + 1) - 1) .. "…"
end

local function relative(ev, now: number): string
  if ev.startUnix <= now then
    return noctalia.tr("next.now")
  end
  local mins = math.floor((ev.startUnix - now) / 60)
  if mins < 60 then
    return noctalia.trp("next.in_minutes", mins)
  end
  return noctalia.trp("next.in_hours", math.floor(mins / 60))
end

local function render()
  local now = os.time()
  local ev = model.nextUpcoming(events, now)
  local maxTitle = noctalia.getConfig("max_title") or 22

  barWidget.setGlyph("calendar")

  if ev == nil then
    barWidget.setText(noctalia.tr("next.none"))
    barWidget.clearTooltip()
    return
  end

  barWidget.setText(truncate(ev.title, maxTitle) .. " · " .. relative(ev, now))

  local pattern = noctalia.timeFormat()
  if pattern == nil or pattern == "" then pattern = "{:%H:%M}" end
  local rows = {
    { key = ev.title, value = noctalia.formatTime(pattern, ev.startUnix)
        .. "–" .. noctalia.formatTime(pattern, ev.endUnix) },
  }
  if ev.location ~= "" then
    table.insert(rows, { key = noctalia.tr("tooltip.location"), value = ev.location })
  end
  if ev.calendar ~= "" then
    table.insert(rows, { key = noctalia.tr("tooltip.calendar"), value = ev.calendar })
  end
  barWidget.setTooltip(rows)
end

noctalia.state.watch("events", function(value)
  events = value or {}
  render()
end)

noctalia.setUpdateInterval(30000)

function update() render() end
function onClick() noctalia.togglePanel("137-trimethylxanthin/fiaker:melange") end
function onConfigChanged() render() end

-- watch() only fires on change: seed from what the service already published.
events = noctalia.state.get("events") or {}

render()
