math.clamp = function(v,lo,hi) return math.max(lo,math.min(hi,v)) end
table.clone = function(t) local r={} for k,v in pairs(t) do r[k]=v end return r end
noctalia = { log = function() end }

local vdir = require("lib.source_vdir")
local fails = 0
local function check(n,c,e) if c then print("  ok   "..n) else fails=fails+1; print("  FAIL "..n.."  -> "..tostring(e)) end end

local ics = table.concat({
"BEGIN:VCALENDAR","VERSION:2.0",
"BEGIN:VEVENT","UID:evt-1","SUMMARY:Mathematik","DTSTART;TZID=Europe/Vienna:20260921T080000",
"DTEND;TZID=Europe/Vienna:20260921T085000","LOCATION:Raum A1.03","END:VEVENT",
-- folded SUMMARY (RFC 5545: leading space continues the line)
"BEGIN:VEVENT","UID:evt-2","SUMMARY:Ein sehr langer Terminname der ",
" ueber zwei Zeilen geht","DTSTART:20260921T120000Z","DTEND:20260921T133000Z","END:VEVENT",
-- all-day
"BEGIN:VEVENT","UID:evt-3","SUMMARY:Feiertag","DTSTART;VALUE=DATE:20260921",
"DTEND;VALUE=DATE:20260922","END:VEVENT",
-- recurring: must still yield one instance, and be counted
"BEGIN:VEVENT","UID:evt-4","SUMMARY:Turnen","DTSTART;TZID=Europe/Vienna:20260922T140000",
"DTEND;TZID=Europe/Vienna:20260922T150000","RRULE:FREQ=WEEKLY;BYDAY=TU","END:VEVENT",
-- escaped characters
"BEGIN:VEVENT","UID:evt-5","SUMMARY:Deutsch\\, Test","DTSTART;TZID=Europe/Vienna:20260923T100000",
"DTEND;TZID=Europe/Vienna:20260923T110000","END:VEVENT",
-- no DTEND: must get a default duration
"BEGIN:VEVENT","UID:evt-6","SUMMARY:Kurz","DTSTART;TZID=Europe/Vienna:20260924T090000","END:VEVENT",
"END:VCALENDAR"}, "\r\n")

local evs, rec = vdir.parseIcs(ics, "schule")
print("== ics parser ==")
check("6 events parsed", #evs == 6, #evs)
check("1 recurring counted", rec == 1, rec)

local by = {}
for _, e in ipairs(evs) do by[e.id] = e end

check("local time 08:00", os.date("%Y-%m-%d %H:%M", by["evt-1"].startUnix) == "2026-09-21 08:00",
      os.date("%Y-%m-%d %H:%M", by["evt-1"].startUnix))
check("location kept", by["evt-1"].location == "Raum A1.03", by["evt-1"].location)
check("calendar name applied", by["evt-1"].calendar == "schule", by["evt-1"].calendar)
-- RFC 5545 unfolding drops the CRLF AND the single whitespace that follows it,
-- so the space must come from the content itself (trailing space before the fold).
check("folded line rejoined per RFC 5545",
      by["evt-2"].title == "Ein sehr langer Terminname der ueber zwei Zeilen geht", by["evt-2"].title)
check("fold does not invent a space", (function()
  local e = vdir.parseIcs("BEGIN:VEVENT\r\nUID:z\r\nSUMMARY:abc\r\n def\r\nDTSTART:20260101T100000Z\r\nEND:VEVENT\r\n","x")
  return e[1].title == "abcdef" end)())
-- 12:00Z in CEST (UTC+2) is 14:00 local
check("Z time converted to local", os.date("%H:%M", by["evt-2"].startUnix) == "14:00",
      os.date("%H:%M", by["evt-2"].startUnix))
check("all-day flagged", by["evt-3"].allDay == true)
check("escaped comma unescaped", by["evt-5"].title == "Deutsch, Test", by["evt-5"].title)
check("missing DTEND gets 30min", by["evt-6"].endUnix - by["evt-6"].startUnix == 1800,
      by["evt-6"].endUnix - by["evt-6"].startUnix)
check("empty input is safe", (function() local e,r = vdir.parseIcs("", "x") return #e==0 and r==0 end)())
check("garbage input is safe", (function() local e,r = vdir.parseIcs("BEGIN:VEVENT\r\nnonsense\r\n", "x") return #e==0 end)())

print("== audit regressions ==")
local model = require("lib.model")
local date = require("lib.date")
local day21 = date.mktime({ year = 2026, month = 9, day = 21, hour = 12 })
local day22 = date.mktime({ year = 2026, month = 9, day = 22, hour = 12 })
local allDay = by["evt-3"]
check("all-day starts at midnight", os.date("%H:%M", allDay.startUnix) == "00:00", os.date("%H:%M", allDay.startUnix))
local _, on21 = model.onDay({ allDay }, date.startOfDay(day21))
local _, on22 = model.onDay({ allDay }, date.startOfDay(day22))
check("all-day is on its own day", #on21 == 1, #on21)
check("and not on the next one", #on22 == 0, #on22)
local dots = model.countsByDay({ allDay })
check("one dot, not two", dots["2026-09-21"] == 1 and dots["2026-09-22"] == nil)

local function one(lines)
  local e = vdir.parseIcs(table.concat(lines, "\r\n"), "x")
  return e[1], #e
end
local dt = one({ "BEGIN:VEVENT", "UID:a", "SUMMARY:Timed", "DTSTART;VALUE=DATE-TIME:20260921T083000Z", "DTEND;VALUE=DATE-TIME:20260921T093000Z", "END:VEVENT" })
check("VALUE=DATE-TIME is not all-day", dt and not dt.allDay and dt.endUnix - dt.startUnix == 3600)
local alarm = one({ "BEGIN:VEVENT", "UID:real", "SUMMARY:Meeting", "DTSTART:20260921T083000Z", "DTEND:20260921T093000Z",
  "BEGIN:VALARM", "UID:alarm-1", "ACTION:EMAIL", "SUMMARY:Alarm notification", "TRIGGER:-PT15M", "END:VALARM", "END:VEVENT" })
check("a VALARM keeps its hands off the event", alarm and alarm.title == "Meeting" and alarm.id == "real", alarm and alarm.title)
local altrep = one({ "BEGIN:VEVENT", "UID:b", "SUMMARY:Room", 'LOCATION;ALTREP="http://x.org/r":Room 1', "DTSTART:20260921T083000Z", "END:VEVENT" })
check("a colon inside a quoted parameter", altrep and altrep.location == "Room 1", altrep and altrep.location)
local dur = one({ "BEGIN:VEVENT", "UID:c", "SUMMARY:Long", "DTSTART:20260921T083000Z", "DURATION:PT1H30M", "END:VEVENT" })
check("DURATION instead of DTEND", dur and dur.endUnix - dur.startUnix == 5400)
local _, n = one({ "BEGIN:VEVENT", "UID:d", "SUMMARY:Off", "STATUS:CANCELLED", "DTSTART:20260921T083000Z", "END:VEVENT" })
check("cancelled events are left out", n == 0, n)
local utc = one({ "BEGIN:VEVENT", "UID:e", "SUMMARY:U", "DTSTART;TZID=UTC:20260921T083000", "DTEND;TZID=UTC:20260921T093000", "END:VEVENT" })
local z = one({ "BEGIN:VEVENT", "UID:f", "SUMMARY:Z", "DTSTART:20260921T083000Z", "END:VEVENT" })
check("TZID=UTC is UTC", utc and z and utc.startUnix == z.startUnix)
local esc = one({ "BEGIN:VEVENT", "UID:g", "SUMMARY:a\\\\nb\\nc", "DTSTART:20260921T083000Z", "END:VEVENT" })
check("an escaped backslash before n stays one", esc and esc.title == "a\\nb\nc", esc and esc.title)
local ws = one({ "BEGIN:VEVENT ", "UID:h", "SUMMARY:Spaces", "DTSTART:20260921T083000Z", "end:vevent" })
check("markers tolerate trailing space and case", ws ~= nil)

print("")
if fails == 0 then print("ALL PASS") else print(fails.." FAILURE(S)") end
os.exit(fails == 0 and 0 or 1)
