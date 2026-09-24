-- Fiaker under Luau's os.time: there, os.time(table) reads the table as UTC,
-- where Lua 5.4 reads it as local time. This patches os.time to the Luau
-- reading before loading the modules, and checks that local wall-clock times
-- still come out as local times (they came out shifted by the UTC offset).
math.clamp = function(v, lo, hi) return math.max(lo, math.min(hi, v)) end
table.clone = function(t) local r = {} for k,v in pairs(t) do r[k]=v end return r end

local localTime = os.time
local function utcTime(t)
  if t == nil then return localTime() end
  local fields = {}
  for k, v in pairs(t) do fields[k] = v end
  fields.isdst = nil
  local asLocal = localTime(fields)
  local utcView = os.date("!*t", asLocal)
  utcView.isdst = nil
  return asLocal + (asLocal - localTime(utcView))
end
os.time = utcTime

local date = require("lib.date")
local vdir = require("lib.source_vdir")

local fails = 0
local function check(name, cond, extra)
  if cond then print("  ok   " .. name)
  else fails = fails + 1; print("  FAIL " .. name .. (extra and ("  -> " .. tostring(extra)) or "")) end
end

local function wall(ts) return os.date("%Y-%m-%d %H:%M", ts) end

check("the patch really reads UTC", utcTime({ year = 2026, month = 9, day = 24, hour = 10 }) ~= localTime({ year = 2026, month = 9, day = 24, hour = 10 }))
check("mktime is local", wall(date.mktime({ year = 2026, month = 9, day = 24, hour = 10, min = 30 })) == "2026-09-24 10:30",
  wall(date.mktime({ year = 2026, month = 9, day = 24, hour = 10, min = 30 })))
check("mktime is local in winter too", wall(date.mktime({ year = 2026, month = 1, day = 15, hour = 8 })) == "2026-01-15 08:00")
local noon = localTime({ year = 2026, month = 9, day = 24, hour = 12 })
check("startOfDay is local midnight", wall(date.startOfDay(noon)) == "2026-09-24 00:00", wall(date.startOfDay(noon)))
check("addDays across the DST end", wall(date.addDays(localTime({ year = 2026, month = 10, day = 24, hour = 12 }), 2)) == "2026-10-26 00:00")
check("fromIso", wall(date.fromIso("2026-09-24")) == "2026-09-24 00:00")

local events = vdir.parseIcs([[
BEGIN:VCALENDAR
BEGIN:VEVENT
UID:a
DTSTART:20260924T103000
DTEND:20260924T114500
SUMMARY:Design review
END:VEVENT
BEGIN:VEVENT
UID:b
DTSTART:20260924T083000Z
DTEND:20260924T090000Z
SUMMARY:UTC stamp
END:VEVENT
END:VCALENDAR
]], "work")
local byTitle = {}
for _, ev in ipairs(events) do byTitle[ev.title] = ev end
check("floating time stays wall-clock", byTitle["Design review"] and wall(byTitle["Design review"].startUnix) == "2026-09-24 10:30",
  byTitle["Design review"] and wall(byTitle["Design review"].startUnix))
check("Z time converts to local", byTitle["UTC stamp"] and wall(byTitle["UTC stamp"].startUnix) == "2026-09-24 10:30",
  byTitle["UTC stamp"] and wall(byTitle["UTC stamp"].startUnix))

print()
if fails > 0 then print(fails .. " failed"); os.exit(1) end
print("ALL PASS")
