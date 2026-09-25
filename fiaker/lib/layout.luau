--!nonstrict
-- Timeline geometry.
--
-- Noctalia's UI tree is flexbox only: no absolute positioning, no z-stacking,
-- no canvas. So the timeline is built by computing every box height here and
-- emitting a column of sized nodes. This module owns all the arithmetic; the
-- render entries stay dumb walkers.
--
-- The now-line is the reason this file exists. A line cannot be drawn *over*
-- anything, so it is drawn *between* things:
--
--   * where it falls in a gap    -> the gap splits into [gap][line][gap]
--   * where it falls in an event -> the event splits into [top][line][bottom]
--
-- Every lane is split independently at the same y, which is what makes the
-- result read as one continuous line across the full width.

local model = require("./model.luau")
local date = require("./date.luau")

local M = {}

local NOW_H = 2       -- px, the line itself
local MIN_SLIVER = 4  -- px; a split closer than this to an edge snaps to it
local MIN_LABEL = 15  -- px; a segment shorter than this cannot hold text

-- Greedy interval colouring. Events are pre-sorted by start, so the first lane
-- whose last event has ended is always a valid home.
local function assignLanes(events)
  local lanes = {}
  for _, ev in ipairs(events) do
    local placed = false
    for _, lane in ipairs(lanes) do
      if lane.lastEnd <= ev._s then
        table.insert(lane.events, ev)
        lane.lastEnd = ev._e
        placed = true
        break
      end
    end
    if not placed then
      table.insert(lanes, { events = { ev }, lastEnd = ev._e })
    end
  end
  return lanes
end

-- Turns one lane's events into a vertical run of gaps and event boxes.
-- Gaps are measured to where the event belongs on the time grid, from where
-- the lane has actually got to: a box stretched to its minimum height takes
-- its extra pixels out of the next gap instead of pushing the rest of the
-- lane down, so every lane stays aligned with the hour gutter.
local function buildItems(lane, viewStart: number, pxPerMin: number, totalH: number)
  local items = {}
  local y = 0

  for _, ev in ipairs(lane.events) do
    local target = (ev._s - viewStart) / 60 * pxPerMin
    local gap = target - y
    if gap > 0.5 then
      table.insert(items, { kind = "gap", h = gap })
      y = target
    end
    local h = math.max((ev._e - ev._s) / 60 * pxPerMin, 6)
    table.insert(items, {
      kind = "event",
      h = h,
      ev = ev,
      clippedTop = ev._s > ev.startUnix,
      clippedBottom = ev._e < ev.endUnix,
    })
    y += h
  end

  local tail = totalH - y
  if tail > 0.5 then
    table.insert(items, { kind = "gap", h = tail })
  end
  return items
end

-- Walks a lane to the item holding `y` and splits it in place.
local function splitAt(items, y: number)
  local top = 0
  for i, item in ipairs(items) do
    local bottom = top + item.h
    if y >= top and y < bottom then
      local offset = y - top

      -- Too close to an edge to leave a visible sliver: snap to the boundary,
      -- where the line renders as its own node between two items instead.
      if offset < MIN_SLIVER then
        table.insert(items, i, { kind = "line", h = NOW_H })
        return
      end
      if item.h - offset < MIN_SLIVER + NOW_H then
        table.insert(items, i + 1, { kind = "line", h = NOW_H })
        return
      end

      if item.kind == "gap" then
        local rest = item.h - offset - NOW_H
        item.h = offset
        table.insert(items, i + 1, { kind = "line", h = NOW_H })
        table.insert(items, i + 2, { kind = "gap", h = rest })
      else
        -- Split the event box. The title goes in whichever half has room for
        -- it, preferring the top so the event still reads top-down.
        local topH = offset
        local botH = item.h - offset - NOW_H
        item.split = {
          topH = topH,
          botH = botH,
          labelIn = (topH >= MIN_LABEL or topH >= botH) and "top" or "bottom",
        }
      end
      return
    end
    top = bottom
  end

  -- Exactly at the very bottom edge of the last item.
  if math.abs(y - top) < 1 then
    table.insert(items, { kind = "line", h = NOW_H })
  end
end

-- opts: dayTs, hourFrom, hourTo, pxPerMinute, nowUnix
function M.planDay(events, opts)
  local hourFrom = math.clamp(opts.hourFrom or 0, 0, 23)
  local hourTo = math.clamp(opts.hourTo or 24, hourFrom + 1, 24)
  local pxPerMin = math.clamp(opts.pxPerMinute or 1.2, 0.2, 8)

  -- Wall-clock hours of that day, so a DST day is 23 or 25 hours long and
  -- 09:00 is still drawn where 09:00 is.
  local day = os.date("*t", opts.dayTs)
  local viewStart = date.mktime({ year = day.year, month = day.month, day = day.day, hour = hourFrom })
  local viewEnd = date.mktime({ year = day.year, month = day.month, day = day.day, hour = hourTo })
  local totalH = (viewEnd - viewStart) / 60 * pxPerMin

  -- Clamp every event to the visible window, keeping the real bounds so the
  -- renderer can flatten the corner it cut.
  local visible = {}
  for _, ev in ipairs(events) do
    local stop = ev.endUnix
    if stop <= ev.startUnix then stop = ev.startUnix + 300 end -- see model.onDay
    if not ev.allDay and stop > viewStart and ev.startUnix < viewEnd then
      local clone = table.clone(ev)
      clone._s = math.max(ev.startUnix, viewStart)
      clone._e = math.min(ev.endUnix, viewEnd)
      if clone._e - clone._s < 300 then          -- keep sub-5-minute events legible
        clone._e = math.min(clone._s + 300, viewEnd)
      end
      table.insert(visible, clone)
    end
  end
  model.sortByStart(visible)

  local lanes = {}
  for _, lane in ipairs(assignLanes(visible)) do
    table.insert(lanes, buildItems(lane, viewStart, pxPerMin, totalH))
  end
  if #lanes == 0 then
    lanes = { { { kind = "gap", h = totalH } } }
  end

  -- The now-line, only when today is actually the day on screen.
  local nowY = nil
  local now = opts.nowUnix
  if now and now >= viewStart and now < viewEnd then
    nowY = (now - viewStart) / 60 * pxPerMin
    for _, items in ipairs(lanes) do
      splitAt(items, nowY)
    end
  end

  -- The gutter from the same wall clock: on the day the clocks go forward
  -- the skipped hour has no row, and on the day they go back the repeated
  -- one is two hours tall, so every label sits beside its hour.
  local hours = {}
  for h = hourFrom, hourTo - 1 do
    local at = date.mktime({ year = day.year, month = day.month, day = day.day, hour = h })
    local nextAt = date.mktime({ year = day.year, month = day.month, day = day.day, hour = h + 1 })
    local minutes = (nextAt - at) / 60
    if minutes > 0 then
      table.insert(hours, { hour = h, at = at, h = minutes * pxPerMin })
    end
  end

  return {
    height = totalH,
    hourHeight = 60 * pxPerMin,
    hours = hours,
    lanes = lanes,
    nowY = nowY,
    viewStart = viewStart,
    viewEnd = viewEnd,
  }
end

return M
