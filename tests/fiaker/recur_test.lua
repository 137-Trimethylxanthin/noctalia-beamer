math.clamp = function(v,lo,hi) return math.max(lo,math.min(hi,v)) end
table.clone = function(t) local r={} for k,v in pairs(t) do r[k]=v end return r end
noctalia = noctalia or { log = function() end }

-- Runs under Lua 5.4 (run.sh) and under Luau alike, so the module names are
-- whatever the runner resolves.
local date = require(LIB and (LIB .. "date") or "lib.date")
local recur = require(LIB and (LIB .. "recur") or "lib.recur")
local vdir = require(LIB and (LIB .. "source_vdir") or "lib.source_vdir")
local fails = 0
local function check(n,c,e) if c then print("  ok   "..n) else fails=fails+1; print("  FAIL "..n.."  -> "..tostring(e)) end end
local function stamp(ts) return os.date("%Y-%m-%d %H:%M", ts) end
local function day(y, m, d) return date.dayNumber(y, m, d) end
local function window(y1, m1, d1, y2, m2, d2)
  return date.mktime({ year = y1, month = m1, day = d1, hour = 0 }), date.mktime({ year = y2, month = m2, day = d2, hour = 0 })
end
local function ics(lines) return table.concat(lines, "\r\n") .. "\r\n" end
local function starts(evs)
  local out = {}
  for i, e in ipairs(evs) do out[i] = stamp(e.startUnix) end
  table.sort(out)
  return table.concat(out, ", ")
end

print("== civil dates ==")
local ok = true
for _, c in ipairs({ { 1970, 1, 1, 0 }, { 1945, 6, 12, -8969 }, { 2000, 2, 29, 11016 }, { 2026, 9, 25, 20721 }, { 2100, 3, 1, 47541 } }) do
  local n = date.dayNumber(c[1], c[2], c[3])
  local y, m, d = date.civil(n)
  ok = ok and n == c[4] and y == c[1] and m == c[2] and d == c[3]
end
check("day numbers round-trip, before 1970 too", ok)
check("1970-01-01 was a Thursday", date.weekday(0) == 4)
check("2026-09-25 is a Friday", date.weekday(day(2026, 9, 25)) == 5)
check("February 2028 has 29 days, 2100 has 28", date.daysInMonth(2028, 2) == 29 and date.daysInMonth(2100, 2) == 28)

print("== rules ==")
local function days(rule, start, to)
  local out = {}
  for i, d in ipairs(recur.days(recur.parse(rule), start, nil, to)) do
    local y, m, dd = date.civil(d)
    out[i] = string.format("%04d-%02d-%02d", y, m, dd)
  end
  return table.concat(out, " ")
end
check("daily, five times", days("FREQ=DAILY;COUNT=5", day(2026, 9, 28), day(2027, 1, 1)) == "2026-09-28 2026-09-29 2026-09-30 2026-10-01 2026-10-02")
check("every other week on Tuesday and Thursday",
  days("FREQ=WEEKLY;INTERVAL=2;BYDAY=TU,TH;COUNT=4", day(2026, 9, 1), day(2027, 1, 1)) == "2026-09-01 2026-09-03 2026-09-15 2026-09-17")
check("the last Friday of each month", days("FREQ=MONTHLY;BYDAY=-1FR;COUNT=3", day(2026, 9, 25), day(2027, 1, 1)) == "2026-09-25 2026-10-30 2026-11-27")
check("the 31st skips shorter months", days("FREQ=MONTHLY;COUNT=3", day(2026, 8, 31), day(2027, 6, 1)) == "2026-08-31 2026-10-31 2026-12-31")
check("the last weekday of the month (BYSETPOS)",
  days("FREQ=MONTHLY;BYDAY=MO,TU,WE,TH,FR;BYSETPOS=-1;COUNT=2", day(2026, 10, 30), day(2027, 1, 1)) == "2026-10-30 2026-11-30")
check("second Sunday of May, yearly", days("FREQ=YEARLY;BYMONTH=5;BYDAY=2SU;COUNT=2", day(2026, 5, 10), day(2030, 1, 1)) == "2026-05-10 2027-05-09")
check("29 February only in leap years", days("FREQ=YEARLY;COUNT=2", day(2024, 2, 29), day(2040, 1, 1)) == "2024-02-29 2028-02-29")
check("DTSTART counts even off the rule", days("FREQ=WEEKLY;BYDAY=TU;COUNT=2", day(2026, 9, 28), day(2027, 1, 1)) == "2026-09-28 2026-09-29")
check("unsupported rules parse as nil", recur.parse("FREQ=HOURLY") == nil and recur.parse("FREQ=YEARLY;BYWEEKNO=20") == nil)
local far = recur.days(recur.parse("FREQ=DAILY"), day(1990, 1, 1), day(2026, 9, 1), day(2026, 9, 3))
check("a rule from long ago starts near the window", #far < 10 and far[#far] == day(2026, 9, 3), #far)

print("== expansion ==")
local from, to = window(2026, 9, 1, 2026, 11, 1)
local evs = vdir.parseIcs(ics({ "BEGIN:VEVENT", "UID:turnen", "SUMMARY:Turnen", "DTSTART;TZID=Europe/Vienna:20260922T140000",
  "DTEND;TZID=Europe/Vienna:20260922T150000", "RRULE:FREQ=WEEKLY;BYDAY=TU", "END:VEVENT" }), "c", from, to)
check("weekly in the window", #evs == 6, #evs)
check("still 14:00 after the clocks change", stamp(evs[#evs].startUnix) == "2026-10-27 14:00" and evs[#evs].endUnix - evs[#evs].startUnix == 3600,
  stamp(evs[#evs].startUnix))
check("instances have their own ids", evs[1].id ~= evs[2].id)

from, to = window(2026, 1, 1, 2027, 1, 1)
evs = vdir.parseIcs(ics({ "BEGIN:VEVENT", "UID:oma", "SUMMARY:Oma", "DTSTART;VALUE=DATE:19450612", "DTEND;VALUE=DATE:19450613",
  "RRULE:FREQ=YEARLY", "END:VEVENT" }), "c", from, to)
check("a birthday from 1945 shows this year", #evs == 1 and stamp(evs[1].startUnix) == "2026-06-12 00:00" and evs[1].allDay, #evs)
local okOld, oldEvs = pcall(vdir.parseIcs, ics({ "BEGIN:VEVENT", "UID:x", "SUMMARY:old", "DTSTART:19650101T100000", "END:VEVENT" }), "c")
check("a single event before 1970 is skipped, not an error", okOld and #oldEvs == 0, oldEvs)

from, to = window(2026, 9, 1, 2026, 10, 1)
evs = vdir.parseIcs(ics({
  "BEGIN:VEVENT", "UID:m", "SUMMARY:Standup", "DTSTART:20260921T080000", "DTEND:20260921T081500",
  "RRULE:FREQ=DAILY;COUNT=5", "EXDATE:20260921T080000,20260923T080000", "END:VEVENT",
  "BEGIN:VEVENT", "UID:m", "SUMMARY:Standup (moved)", "RECURRENCE-ID:20260924T080000", "DTSTART:20260924T100000",
  "DTEND:20260924T101500", "END:VEVENT",
  "BEGIN:VEVENT", "UID:m", "RECURRENCE-ID:20260925T080000", "DTSTART:20260925T080000", "STATUS:CANCELLED", "END:VEVENT",
}), "c", from, to)
check("EXDATE, a moved and a cancelled instance", starts(evs) == "2026-09-22 08:00, 2026-09-24 10:00", starts(evs))

evs = vdir.parseIcs(ics({ "BEGIN:VEVENT", "UID:u", "SUMMARY:Kurs", "DTSTART:20260901T170000Z", "DTEND:20260901T180000Z",
  "RRULE:FREQ=WEEKLY;UNTIL=20260915T170000Z", "END:VEVENT" }), "c", from, to)
check("UNTIL is the last one", #evs == 3, #evs)

evs = vdir.parseIcs(ics({ "BEGIN:VEVENT", "UID:w", "DTSTART:20260921T090000", "DTEND:20260921T100000", "END:VEVENT" }), "c")
check("an event without a SUMMARY is kept", #evs == 1 and evs[1].title == "", #evs)
evs = vdir.parseIcs(ics({ "BEGIN:VEVENT", "UID:d", "SUMMARY:Frei", "DTSTART;VALUE=DATE:20260329", "DURATION:P1D", "END:VEVENT" }), "c")
check("P1D on the day the clocks go forward ends at the next midnight", #evs == 1 and stamp(evs[1].endUnix) == "2026-03-30 00:00",
  evs[1] and stamp(evs[1].endUnix))
evs = vdir.parseIcs(ics({ "BEGIN:VEVENT", "UID:first", "SUMMARY:W", "DTSTART:20260921T090000", "RRULE:FREQ=WEEKLY",
  "EXDATE:20260921T090000", "END:VEVENT" }), "c")
check("without a window, an EXDATE on the first instance hides it", #evs == 0, #evs)

print()
if fails > 0 then print(fails .. " FAILED") os.exit(1) end
print("ALL PASS")
