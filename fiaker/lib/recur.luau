--!nonstrict
-- RRULE expansion (RFC 5545 section 3.3.10), on day numbers: which days a
-- recurring event falls on. The time of day stays that of DTSTART, so the
-- caller turns each day into an instant in its own time zone, and a meeting
-- at 09:00 stays at 09:00 across a DST change.
--
-- Covered: FREQ=DAILY, WEEKLY, MONTHLY and YEARLY with INTERVAL, COUNT,
-- UNTIL (checked by the caller, which knows the time of day), BYDAY (with
-- ordinals such as 2MO or -1FR in monthly and yearly rules), BYMONTHDAY
-- (negative counts from the month's end), BYMONTH, BYSETPOS and WKST. Rules
-- this does not cover (HOURLY and finer, BYYEARDAY, BYWEEKNO, BYHOUR...)
-- parse as nil, and the event shows its first instance only.
--
-- Pure: day numbers come from date.dayNumber, which works for any year.

local date = require("./date.luau")

local M = {}

local WEEKDAYS = { SU = 0, MO = 1, TU = 2, WE = 3, TH = 4, FR = 5, SA = 6 }
local FREQS = { DAILY = true, WEEKLY = true, MONTHLY = true, YEARLY = true }
local UNSUPPORTED = { BYSECOND = true, BYMINUTE = true, BYHOUR = true, BYYEARDAY = true, BYWEEKNO = true }

-- The most periods one expansion walks, and the most days it returns: a
-- daily rule over decades stays cheap, and a broken one cannot hang a fetch.
local MAX_PERIODS = 5000
local MAX_DAYS = 3000

local function numbers(text)
  local out = {}
  for part in string.gmatch(text, "[^,]+") do
    local n = tonumber(part)
    if n == nil then return nil end
    table.insert(out, math.floor(n))
  end
  return out
end

-- "FREQ=WEEKLY;INTERVAL=2;BYDAY=MO,WE" -> a rule table, or nil. UNTIL is left
-- as its raw text for the caller to read with its own stamp parser.
function M.parse(value)
  if type(value) ~= "string" then return nil end
  local rule = { interval = 1, wkst = 1 }
  for part in string.gmatch(value, "[^;]+") do
    local key, v = string.match(part, "^%s*([%w%-]+)=(.*)$")
    if key == nil then return nil end
    key, v = string.upper(key), string.upper(v)
    if UNSUPPORTED[key] then
      return nil
    elseif key == "FREQ" then
      if not FREQS[v] then return nil end
      rule.freq = v
    elseif key == "INTERVAL" then
      local n = tonumber(v)
      if n == nil or n < 1 then return nil end
      rule.interval = math.floor(n)
    elseif key == "COUNT" then
      local n = tonumber(v)
      if n == nil or n < 1 then return nil end
      rule.count = math.floor(n)
    elseif key == "UNTIL" then
      rule["until"] = v
    elseif key == "WKST" then
      if WEEKDAYS[v] == nil then return nil end
      rule.wkst = WEEKDAYS[v]
    elseif key == "BYDAY" then
      rule.byday = {}
      for entry in string.gmatch(v, "[^,]+") do
        local n, wd = string.match(entry, "^([%+%-]?%d*)(%a%a)$")
        if wd == nil or WEEKDAYS[wd] == nil then return nil end
        local ordinal = nil
        if n ~= "" and n ~= "+" and n ~= "-" then ordinal = tonumber(n) end
        table.insert(rule.byday, { wd = WEEKDAYS[wd], n = ordinal })
      end
    elseif key == "BYMONTHDAY" then
      rule.bymonthday = numbers(v)
      if rule.bymonthday == nil then return nil end
    elseif key == "BYMONTH" then
      rule.bymonth = numbers(v)
      if rule.bymonth == nil then return nil end
    elseif key == "BYSETPOS" then
      rule.bysetpos = numbers(v)
      if rule.bysetpos == nil then return nil end
    end
  end
  if rule.freq == nil then return nil end
  return rule
end

local function contains(list, value)
  for _, v in ipairs(list) do
    if v == value then return true end
  end
  return false
end

local function sortedUnique(days)
  table.sort(days)
  local out = {}
  for _, d in ipairs(days) do
    if out[#out] ~= d then table.insert(out, d) end
  end
  return out
end

-- The days from `first` to `last` (inclusive) that BYDAY picks: every such
-- weekday, or with an ordinal only the nth (from the end when negative).
local function byDayIn(first, last, byday)
  local out = {}
  for _, entry in ipairs(byday) do
    local matches = {}
    local offset = (entry.wd - date.weekday(first)) % 7
    local d = first + offset
    while d <= last do
      table.insert(matches, d)
      d = d + 7
    end
    if entry.n == nil or entry.n == 0 then
      for _, m in ipairs(matches) do table.insert(out, m) end
    elseif entry.n > 0 then
      if matches[entry.n] then table.insert(out, matches[entry.n]) end
    else
      local m = matches[#matches + entry.n + 1]
      if m then table.insert(out, m) end
    end
  end
  return out
end

-- BYMONTHDAY within one month: 31 is skipped in a 30-day month, -1 is the
-- last day.
local function byMonthDayIn(y, m, list)
  local first, dim = date.dayNumber(y, m, 1), date.daysInMonth(y, m)
  local out = {}
  for _, md in ipairs(list) do
    local day = md
    if md < 0 then day = dim + md + 1 end
    if day >= 1 and day <= dim then table.insert(out, first + day - 1) end
  end
  return out
end

local function weekdaySet(byday)
  local set = {}
  for _, entry in ipairs(byday) do set[entry.wd] = true end
  return set
end

-- BYMONTH, and BYDAY without ordinals, as limits on a DAILY or WEEKLY day.
local function passesLimits(rule, d, useByDay)
  if rule.bymonth then
    local _, m = date.civil(d)
    if not contains(rule.bymonth, m) then return false end
  end
  if useByDay and rule.byday then
    if not weekdaySet(rule.byday)[date.weekday(d)] then return false end
  end
  if rule.bymonthday and rule.freq == "DAILY" then
    local y, m, dd = date.civil(d)
    local dim = date.daysInMonth(y, m)
    local ok = false
    for _, md in ipairs(rule.bymonthday) do
      if md == dd or (md < 0 and dim + md + 1 == dd) then ok = true end
    end
    if not ok then return false end
  end
  return true
end

local function applySetPos(rule, days)
  if not rule.bysetpos then return days end
  local out = {}
  for _, pos in ipairs(rule.bysetpos) do
    local d = nil
    if pos > 0 then d = days[pos] elseif pos < 0 then d = days[#days + pos + 1] end
    if d then table.insert(out, d) end
  end
  return sortedUnique(out)
end

-- The candidate days of one month for a MONTHLY rule (or a YEARLY rule's
-- month), before BYSETPOS.
local function monthDays(rule, y, m, startDay)
  local first = date.dayNumber(y, m, 1)
  local last = first + date.daysInMonth(y, m) - 1
  if rule.bymonthday then
    local days = byMonthDayIn(y, m, rule.bymonthday)
    if rule.byday then
      local set = weekdaySet(rule.byday)
      local limited = {}
      for _, d in ipairs(days) do
        if set[date.weekday(d)] then table.insert(limited, d) end
      end
      days = limited
    end
    return days
  elseif rule.byday then
    return byDayIn(first, last, rule.byday)
  end
  if startDay <= last - first + 1 then return { first + startDay - 1 } end
  return {} -- the 31st in a shorter month is skipped, as RFC 5545 says
end

-- The days of period `k` (the k-th day, week, month or year counting from
-- DTSTART's), sorted.
local function periodDays(rule, k, start)
  local sy, sm, sd = date.civil(start)
  local freq, step = rule.freq, rule.interval * k
  local days = {}
  if freq == "DAILY" then
    local d = start + step
    if passesLimits(rule, d, true) then days = { d } end
  elseif freq == "WEEKLY" then
    local weekStart = start - (date.weekday(start) - rule.wkst) % 7 + 7 * step
    if rule.byday then
      for _, entry in ipairs(rule.byday) do
        table.insert(days, weekStart + (entry.wd - rule.wkst) % 7)
      end
    else
      days = { weekStart + (date.weekday(start) - rule.wkst) % 7 }
    end
    local limited = {}
    for _, d in ipairs(days) do
      if passesLimits(rule, d, false) then table.insert(limited, d) end
    end
    days = limited
  elseif freq == "MONTHLY" then
    local index = sy * 12 + (sm - 1) + step
    local y, m = math.floor(index / 12), index % 12 + 1
    if rule.bymonth == nil or contains(rule.bymonth, m) then
      days = monthDays(rule, y, m, sd)
    end
  else -- YEARLY
    local y = sy + step
    if rule.byday and rule.bymonth == nil and rule.bymonthday == nil then
      local first = date.dayNumber(y, 1, 1)
      days = byDayIn(first, date.dayNumber(y + 1, 1, 1) - 1, rule.byday)
    else
      local months = rule.bymonth or { sm }
      for _, m in ipairs(months) do
        for _, d in ipairs(monthDays(rule, y, m, sd)) do table.insert(days, d) end
      end
    end
  end
  return applySetPos(rule, sortedUnique(days))
end

-- A first period near `fromDay`, so a rule that began years ago is not
-- walked from its start. Only without COUNT, which counts from the start.
local function firstPeriod(rule, start, fromDay)
  if rule.count or fromDay == nil or fromDay <= start then return 0 end
  local sy, sm = date.civil(start)
  local fy, fm = date.civil(fromDay)
  local periods
  if rule.freq == "DAILY" then
    periods = (fromDay - start) / rule.interval
  elseif rule.freq == "WEEKLY" then
    periods = (fromDay - start) / (7 * rule.interval)
  elseif rule.freq == "MONTHLY" then
    periods = ((fy * 12 + fm) - (sy * 12 + sm)) / rule.interval
  else
    periods = (fy - sy) / rule.interval
  end
  return math.max(0, math.floor(periods) - 1)
end

-- The days the event falls on, from DTSTART's day `start` up to `toDay`, in
-- order. `fromDay` only lets the walk start late; days before it may still
-- come back. `pastUntil(day)` says when UNTIL is behind; it may be nil.
-- DTSTART's day is always the first occurrence, as RFC 5545 says, when the
-- walk starts at the beginning.
function M.days(rule, start, fromDay, toDay, pastUntil)
  local out = {}
  local k = firstPeriod(rule, start, fromDay)
  if k == 0 then
    if start > toDay or (pastUntil and pastUntil(start)) then return out end
    table.insert(out, start)
  end
  local emitted = #out
  local periods = 0
  while periods < MAX_PERIODS and #out < MAX_DAYS do
    local stop = false
    for _, d in ipairs(periodDays(rule, k, start)) do
      if d > start then
        if d > toDay or (pastUntil and pastUntil(d)) or (rule.count and emitted >= rule.count) then
          stop = true
          break
        end
        table.insert(out, d)
        emitted = emitted + 1
      end
    end
    if stop then break end
    k = k + 1
    periods = periods + 1
  end
  return out
end

return M
