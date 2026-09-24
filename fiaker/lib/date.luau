--!nonstrict
-- Date math. Luau ships the standard `os` library, so os.date("*t", ts) and
-- os.time(t) do the real work - no hand-rolled epoch arithmetic needed.
--
-- One catch: Luau's os.time(table) reads the table as UTC, where Lua 5.4 (the
-- test runner) reads it as local time. Every table-to-epoch conversion goes
-- through M.mktime, which gives local time under both.
--
-- Every day-shifting helper anchors at 12:00 before normalizing. Anchoring at
-- midnight breaks on DST transition days, where 00:00 may not exist or may
-- occur twice; noon always exists.

local M = {}

-- os.time(t) for a table of local wall-clock fields, under either reading.
-- The round trip through os.date("*t") shows how far os.time's reading is
-- from local time; it is zero on Lua 5.4. The offset is measured a second
-- time at the corrected instant, so a DST change between the two readings
-- does not leave it an hour out.
function M.mktime(t): number
  local guess = os.time(t)
  local first = guess - (os.time(os.date("*t", guess)) - guess)
  return guess - (os.time(os.date("*t", first)) - first)
end

function M.startOfDay(ts: number): number
  local t = os.date("*t", ts)
  t.hour, t.min, t.sec, t.isdst = 0, 0, 0, nil
  return M.mktime(t)
end

-- The next midnight, which is 23 or 25 hours away on a DST day.
function M.endOfDay(ts: number): number
  return M.addDays(M.startOfDay(ts), 1)
end

-- Shifts by whole days across DST without drifting.
function M.addDays(ts: number, n: number): number
  local t = os.date("*t", ts)
  t.day = t.day + n
  t.hour, t.min, t.sec, t.isdst = 12, 0, 0, nil
  return M.startOfDay(M.mktime(t))
end

function M.addMonths(ts: number, n: number): number
  local t = os.date("*t", ts)
  t.month = t.month + n
  t.day = 1
  t.hour, t.min, t.sec, t.isdst = 12, 0, 0, nil
  return M.startOfDay(M.mktime(t))
end

function M.iso(ts: number): string
  return os.date("%Y-%m-%d", ts)
end

function M.fromIso(s: string?): number?
  if type(s) ~= "string" then return nil end
  local y, m, d = string.match(s, "^(%d%d%d%d)%-(%d%d)%-(%d%d)$")
  if not y then return nil end
  return M.startOfDay(M.mktime({
    year = tonumber(y), month = tonumber(m), day = tonumber(d), hour = 12,
  }))
end

function M.sameDay(a: number, b: number): boolean
  return M.startOfDay(a) == M.startOfDay(b)
end

function M.minutesSinceMidnight(ts: number): number
  local t = os.date("*t", ts)
  return t.hour * 60 + t.min + t.sec / 60
end

-- 0 = the first column of the week, honoring the week_start setting.
local function columnFor(wday: number, mondayFirst: boolean): number
  -- os.date wday: 1 = Sunday .. 7 = Saturday
  if mondayFirst then
    return (wday + 5) % 7
  end
  return wday - 1
end

M.columnFor = columnFor

-- A 6x7 grid covering `month`, padded with the surrounding days so every row is
-- a full week. Always 42 cells, so the widget never changes height mid-year.
function M.monthGrid(year: number, month: number, mondayFirst: boolean, todayTs: number)
  local first = M.mktime({ year = year, month = month, day = 1, hour = 12 })
  local offset = columnFor(os.date("*t", first).wday, mondayFirst)
  local cursor = M.addDays(first, -offset)
  local today = M.startOfDay(todayTs)

  local cells = {}
  for i = 1, 42 do
    local t = os.date("*t", cursor)
    cells[i] = {
      ts = cursor,
      iso = M.iso(cursor),
      day = t.day,
      inMonth = (t.month == month and t.year == year),
      isToday = (cursor == today),
      isWeekend = (t.wday == 1 or t.wday == 7),
    }
    cursor = M.addDays(cursor, 1)
  end
  return cells
end

-- Weekday headers in the configured order, e.g. Mo Di Mi ... (locale-driven).
function M.weekdayHeaders(mondayFirst: boolean): { string }
  -- 2024-01-01 was a Monday; walk from there so the labels come from the locale.
  local monday = M.mktime({ year = 2024, month = 1, day = 1, hour = 12 })
  local out = {}
  for i = 0, 6 do
    local ts = M.addDays(monday, mondayFirst and i or (i - 1))
    out[i + 1] = os.date("%a", ts)
  end
  return out
end

return M
