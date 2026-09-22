-- Luau shims missing from Lua 5.4
math.clamp = function(v, lo, hi) return math.max(lo, math.min(hi, v)) end
table.clone = function(t) local r = {} for k,v in pairs(t) do r[k]=v end return r end

local date   = require("lib.date")
local model  = require("lib.model")
local layout = require("lib.layout")

local fails = 0
local function check(name, cond, extra)
  if cond then print("  ok   " .. name)
  else fails = fails + 1; print("  FAIL " .. name .. (extra and ("  -> " .. tostring(extra)) or "")) end
end

print("== date ==")
-- Sept 2026: 1st is a Tuesday. Monday-first grid must start Mon 31 Aug.
local g = date.monthGrid(2026, 9, true, os.time({year=2026,month=9,day=21,hour=12}))
check("42 cells", #g == 42, #g)
check("monday-first starts 2026-08-31", g[1].iso == "2026-08-31", g[1].iso)
check("cell 2 is Sept 1", g[2].iso == "2026-09-01" and g[2].inMonth, g[2].iso)
check("today flagged", g[22].iso == "2026-09-21" and g[22].isToday, g[22].iso)
check("leading day not inMonth", g[1].inMonth == false)

local gs = date.monthGrid(2026, 9, false, os.time())
check("sunday-first starts 2026-08-30", gs[1].iso == "2026-08-30", gs[1].iso)

-- Feb 2026 starts Sunday -> monday-first needs a full 6-day lead-in.
local f = date.monthGrid(2026, 2, true, os.time())
check("feb 2026 monday-first starts 2026-01-26", f[1].iso == "2026-01-26", f[1].iso)

-- DST: Europe/Vienna springs forward 2026-03-29.
local mar28 = date.fromIso("2026-03-28")
check("addDays across spring-forward", date.iso(date.addDays(mar28, 1)) == "2026-03-29",
      date.iso(date.addDays(mar28, 1)))
check("addDays across it twice", date.iso(date.addDays(mar28, 2)) == "2026-03-30",
      date.iso(date.addDays(mar28, 2)))
local oct24 = date.fromIso("2026-10-24")
check("addDays across fall-back", date.iso(date.addDays(oct24, 2)) == "2026-10-26",
      date.iso(date.addDays(oct24, 2)))
check("iso round-trip", date.iso(date.fromIso("2026-12-31")) == "2026-12-31")
check("addMonths Jan31 -> Feb1", date.iso(date.addMonths(date.fromIso("2026-01-31"), 1)) == "2026-02-01",
      date.iso(date.addMonths(date.fromIso("2026-01-31"), 1)))

print("== model ==")
local day = date.fromIso("2026-09-21")
local function ev(id, sh, sm, eh, em, allDay)
  return model.normalize({ id = id, title = id,
    startUnix = day + sh*3600 + sm*60, endUnix = day + eh*3600 + em*60, allDay = allDay })
end
local evs = { ev("a", 9,0, 10,0), ev("b", 9,30, 11,0), ev("c", 13,0, 14,0) }
local timed, allday = model.onDay(evs, day)
check("3 timed today", #timed == 3, #timed)
check("sorted by start", timed[1].id == "a" and timed[3].id == "c")

local counts = model.countsByDay({ model.normalize({ id="x", title="x",
  startUnix = day, endUnix = day + 3*86400 }) })
check("multi-day marks 3 days", counts["2026-09-21"] == 1 and counts["2026-09-23"] == 1
      and counts["2026-09-24"] == nil, counts["2026-09-24"])

print("== layout: lanes ==")
local plan = layout.planDay(timed, { dayTs = day, hourFrom = 8, hourTo = 18,
                                     pxPerMinute = 1, nowUnix = day + 0 })
check("a and b overlap -> 2 lanes", #plan.lanes == 2, #plan.lanes)
check("height = 10h * 60 * 1px", plan.height == 600, plan.height)
check("no now-line outside window", plan.nowY == nil, plan.nowY)

-- Lane heights must sum to exactly the view height, or boxes drift apart.
for i, items in ipairs(plan.lanes) do
  local sum = 0
  for _, it in ipairs(items) do sum = sum + it.h end
  check("lane " .. i .. " sums to height", math.abs(sum - plan.height) < 0.01, sum)
end

print("== layout: now-line ==")
-- 12:30 falls in the gap between b (ends 11:00) and c (starts 13:00).
local p2 = layout.planDay(timed, { dayTs = day, hourFrom = 8, hourTo = 18,
                                   pxPerMinute = 1, nowUnix = day + 12*3600 + 30*60 })
check("nowY = 270px (4.5h after 08:00)", math.abs(p2.nowY - 270) < 0.01, p2.nowY)
local lineCount, splitCount = 0, 0
for _, items in ipairs(p2.lanes) do
  for _, it in ipairs(items) do
    if it.kind == "line" then lineCount = lineCount + 1 end
    if it.split then splitCount = splitCount + 1 end
  end
end
check("line drawn in every lane", lineCount == #p2.lanes, lineCount)
check("no event split in a gap", splitCount == 0, splitCount)

-- 09:45 falls inside BOTH a (09:00-10:00) and b (09:30-11:00): both must split.
local p3 = layout.planDay(timed, { dayTs = day, hourFrom = 8, hourTo = 18,
                                   pxPerMinute = 1, nowUnix = day + 9*3600 + 45*60 })
local splits = 0
for _, items in ipairs(p3.lanes) do
  for _, it in ipairs(items) do if it.split then splits = splits + 1 end end
end
check("both overlapping events split", splits == 2, splits)
for _, items in ipairs(p3.lanes) do
  local sum = 0
  for _, it in ipairs(items) do
    if it.split then sum = sum + it.split.topH + 2 + it.split.botH else sum = sum + it.h end
  end
  check("split lane still sums to height", math.abs(sum - p3.height) < 0.01, sum)
end

-- A split 1px from an event's top edge must snap to a boundary line, not leave a sliver.
local p4 = layout.planDay({ ev("d", 9,0, 10,0) }, { dayTs = day, hourFrom = 8, hourTo = 18,
                            pxPerMinute = 1, nowUnix = day + 9*3600 + 1*60 })
local sliver = false
for _, items in ipairs(p4.lanes) do
  for _, it in ipairs(items) do
    if it.split and (it.split.topH < 4 or it.split.botH < 4) then sliver = true end
  end
end
check("no sub-4px sliver", not sliver)

print("")
if fails == 0 then print("ALL PASS") else print(fails .. " FAILURE(S)") end
os.exit(fails == 0 and 0 or 1)
