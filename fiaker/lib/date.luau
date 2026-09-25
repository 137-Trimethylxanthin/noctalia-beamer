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
--
-- Of the two candidates, the one that reads back as the asked-for wall
-- clock wins. A wall clock that does not exist (the hour a DST change skips,
-- which in Santiago or Havana is midnight itself) has no such candidate; the
-- later one is taken, which is the first instant after the gap, on the same
-- day, where the earlier one would be an hour before, on the day before.
--
-- Returns nil for a time Luau cannot represent (before 1970).
function M.mktime(t)
  local guess = os.time(t)
  if guess == nil then return nil end
  local function wall(x)
    local fields = os.date("*t", x)
    if fields == nil then return nil end
    return os.time(fields)
  end
  local w1 = wall(guess)
  if w1 == nil then return nil end
  local first = guess - (w1 - guess)
  local w2 = wall(first)
  if w2 == nil then return nil end
  local second = guess - (w2 - first)
  local a, b = second, first
  if wall(a) == guess then return a end
  if wall(b) == guess then return b end
  return math.max(a, b)
end

-- ── Civil dates without os ──────────────────────────────────────────────────
-- Day numbers (days since 1970-01-01) from pure integer arithmetic (Howard
-- Hinnant's algorithm), so any year works: os.time refuses dates before 1970
-- under Luau, and a birthday from 1945 still has to repeat into this year.

function M.dayNumber(y, m, d)
  if m <= 2 then y = y - 1 end
  local era = math.floor(y / 400)
  local yoe = y - era * 400
  local mp = (m + 9) % 12
  local doy = math.floor((153 * mp + 2) / 5) + d - 1
  local doe = yoe * 365 + math.floor(yoe / 4) - math.floor(yoe / 100) + doy
  return era * 146097 + doe - 719468
end

function M.civil(n)
  n = n + 719468
  local era = math.floor(n / 146097)
  local doe = n - era * 146097
  local yoe = math.floor((doe - math.floor(doe / 1460) + math.floor(doe / 36524) - math.floor(doe / 146096)) / 365)
  local y = yoe + era * 400
  local doy = doe - (365 * yoe + math.floor(yoe / 4) - math.floor(yoe / 100))
  local mp = math.floor((5 * doy + 2) / 153)
  local d = doy - math.floor((153 * mp + 2) / 5) + 1
  local m = mp + 3
  if m > 12 then m = m - 12 end
  if m <= 2 then y = y + 1 end
  return y, m, d
end

-- 0 = Sunday .. 6 = Saturday; 1970-01-01 was a Thursday.
function M.weekday(n)
  return (n + 4) % 7
end

function M.daysInMonth(y, m)
  local nextY, nextM = y, m + 1
  if nextM > 12 then nextY, nextM = y + 1, 1 end
  return M.dayNumber(nextY, nextM, 1) - M.dayNumber(y, m, 1)
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
