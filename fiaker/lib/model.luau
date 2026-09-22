--!nonstrict
-- The normalized event shape every entry speaks, and the helpers that slice it.
--
-- One table shape, whatever the source:
--   { id, title, calendar, color, location, url, startUnix, endUnix, allDay }
--
-- It mirrors Noctalia's own CalendarEvent (src/calendar/calendar_types.h) on
-- purpose, so the native source is a straight copy and the vdir source has an
-- obvious target to normalize onto.

local date = require("./date.luau")

local M = {}

function M.normalize(raw): any?
  if type(raw) ~= "table" then return nil end
  local s, e = tonumber(raw.startUnix), tonumber(raw.endUnix)
  if not s then return nil end
  if not e or e < s then e = s end
  return {
    id = tostring(raw.id or (tostring(s) .. "/" .. tostring(raw.title or ""))),
    title = tostring(raw.title or ""),
    calendar = tostring(raw.calendar or ""),
    color = tostring(raw.color or ""),
    location = tostring(raw.location or ""),
    url = tostring(raw.url or ""),
    startUnix = s,
    endUnix = e,
    allDay = raw.allDay == true,
  }
end

function M.sortByStart(events)
  table.sort(events, function(a, b)
    if a.startUnix ~= b.startUnix then return a.startUnix < b.startUnix end
    -- Longer events first: they become the left-most lane, which reads better.
    if a.endUnix ~= b.endUnix then return a.endUnix > b.endUnix end
    return a.title < b.title
  end)
  return events
end

-- Half-open overlap: an event ending exactly at `from` is not in the window.
function M.overlaps(ev, from: number, to: number): boolean
  return ev.endUnix > from and ev.startUnix < to
end

function M.onDay(events, dayTs: number)
  local from, to = date.startOfDay(dayTs), date.endOfDay(dayTs)
  local timed, allDay = {}, {}
  for _, ev in ipairs(events) do
    if M.overlaps(ev, from, to) then
      if ev.allDay then table.insert(allDay, ev) else table.insert(timed, ev) end
    end
  end
  return M.sortByStart(timed), M.sortByStart(allDay)
end

-- iso -> count, for the month grid's dots. Multi-day events mark every day they
-- touch, so a week-long holiday shows across the whole week.
function M.countsByDay(events)
  local counts = {}
  for _, ev in ipairs(events) do
    local cursor = date.startOfDay(ev.startUnix)
    local last = date.startOfDay(ev.endUnix - 1)
    if last < cursor then last = cursor end
    -- Guard against a pathological range dominating the loop.
    local guard = 0
    while cursor <= last and guard < 400 do
      local key = date.iso(cursor)
      counts[key] = (counts[key] or 0) + 1
      cursor = date.addDays(cursor, 1)
      guard += 1
    end
  end
  return counts
end

function M.nextUpcoming(events, nowUnix: number)
  local best = nil
  for _, ev in ipairs(events) do
    if not ev.allDay and ev.endUnix > nowUnix then
      if best == nil or ev.startUnix < best.startUnix then best = ev end
    end
  end
  return best
end

return M
