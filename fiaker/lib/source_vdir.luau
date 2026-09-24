--!nonstrict
-- Reads a vdir: a directory of collection folders, each holding one .ics file
-- per event. That is exactly what vdirsyncer writes, and exactly what
-- Noctalia's own `provider = "vdir"` account reads - so pointing both at the
-- same path gives one source of truth with no duplicated auth.
--
-- Deliberately NOT implemented here: RRULE expansion. It is the heaviest part
-- of a calendar and this plugin should not own it. A recurring event shows its
-- first instance, and the count is logged. Two ways out, in order:
--   1. the native backend (the core patch) - the shell expands recurrences
--   2. shell out to `khal`, which expands them too
--
-- Known limitation: a DTSTART with a TZID is read as local wall-clock time.
-- Correct for the common case (your own calendars, your own timezone), wrong
-- for events pinned to another zone. The native backend has no such problem.

local model = require("./model.luau")
local date = require("./date.luau")

local M = {}

M.needsPolling = true

-- Interprets a Y/M/D h:m:s table as UTC and returns epoch seconds.
-- Correct under both readings of os.time(table): on Lua 5.4 (local) the
-- offset term fixes it up; on Luau (UTC) the first line is already the answer
-- and the offset term is zero.
local function timegm(t): number
  local asLocal = os.time(t)
  local utcView = os.date("!*t", asLocal)
  utcView.isdst = nil
  return asLocal + (asLocal - os.time(utcView))
end

-- "20260921T083000Z" | "20260921T083000" | "20260921"
-- A date alone is local midnight: DTEND is exclusive, so an all-day event
-- from the 21st to the 22nd covers the 21st and nothing of the 22nd. (Noon
-- first, then back to the start of the day, so a DST jump cannot shift it.)
local function parseStamp(value: string, isDateOnly: boolean, isUtc: boolean?): (number?, boolean)
  local y, mo, d = string.match(value, "^(%d%d%d%d)(%d%d)(%d%d)")
  if not y then return nil, false end

  if isDateOnly or #value == 8 then
    local noon = date.mktime({ year = tonumber(y), month = tonumber(mo), day = tonumber(d), hour = 12 })
    return date.startOfDay(noon), true
  end

  local h, mi, s = string.match(value, "T(%d%d)(%d%d)(%d%d)")
  if not h then return nil, false end
  local fields = {
    year = tonumber(y), month = tonumber(mo), day = tonumber(d),
    hour = tonumber(h), min = tonumber(mi), sec = tonumber(s),
  }
  if string.sub(value, -1) == "Z" or isUtc then
    return timegm(fields), false
  end
  return date.mktime(fields), false
end

-- "PT1H30M", "P1D", "P2W" -> seconds, or nil.
local function parseDuration(value: string): number?
  local sign, body = string.match(value, "^([%+%-]?)P(.+)$")
  if not body then return nil end
  local total = 0
  local weeks = string.match(body, "^(%d+)W$")
  if weeks then
    total = tonumber(weeks) * 7 * 86400
  else
    local days = string.match(body, "^(%d+)D")
    local time = string.match(body, "T(.*)$")
    if days then total += tonumber(days) * 86400 end
    if time then
      local h = string.match(time, "(%d+)H")
      local m = string.match(time, "(%d+)M")
      local sec = string.match(time, "(%d+)S")
      if h then total += tonumber(h) * 3600 end
      if m then total += tonumber(m) * 60 end
      if sec then total += tonumber(sec) end
    end
    if not days and not time then return nil end
  end
  if sign == "-" then total = -total end
  return total
end

-- NAME;PARAM="a:b";PARAM2=x:value -> NAME, ";PARAM=...", value. The value
-- starts at the first colon outside double quotes, since quoted parameters
-- (ALTREP="http://...", TZID="...") may hold colons of their own.
local function splitProperty(line: string): (string?, string, string)
  local name = string.match(line, "^([A-Za-z0-9%-]+)")
  if not name then return nil, "", "" end
  local quoted = false
  for i = #name + 1, #line do
    local c = string.sub(line, i, i)
    if c == '"' then
      quoted = not quoted
    elseif c == ":" and not quoted then
      return name, string.sub(line, #name + 1, i - 1), string.sub(line, i + 1)
    end
  end
  return nil, "", ""
end

local UTC_ZONES = { UTC = true, ["ETC/UTC"] = true, GMT = true, ["ETC/GMT"] = true, Z = true }

-- RFC 5545 line unfolding: a leading space or tab continues the previous line.
local function unfold(text: string): { string }
  local out = {}
  for line in string.gmatch(text .. "\n", "([^\r\n]*)\r?\n") do
    local first = string.sub(line, 1, 1)
    if (first == " " or first == "\t") and #out > 0 then
      out[#out] = out[#out] .. string.sub(line, 2)
    else
      table.insert(out, line)
    end
  end
  return out
end

-- One pass, so an escaped backslash followed by "n" stays a backslash and an n.
local function unescape(v: string): string
  return (string.gsub(v, "\\(.)", function(c)
    if c == "n" or c == "N" then return "\n" end
    return c
  end))
end

-- Returns (events, recurringCount).
function M.parseIcs(text: string, calendarName: string)
  local events, recurring = {}, 0
  local cur = nil
  -- Components nested in the event (VALARM) carry SUMMARY, UID and friends of
  -- their own, which must not overwrite the event's.
  local depth = 0

  for _, line in ipairs(unfold(text)) do
    local marker = string.upper((string.gsub(line, "%s+$", "")))
    if marker == "BEGIN:VEVENT" and cur == nil then
      cur, depth = {}, 0
    elseif marker == "END:VEVENT" and cur ~= nil and depth == 0 then
      if cur.startUnix and cur.title and not cur.cancelled then
        if cur.rrule then
          recurring += 1
          -- Still show the first instance rather than dropping it entirely.
        end
        cur.calendar = calendarName
        if not cur.endUnix and cur.duration then
          cur.endUnix = cur.startUnix + cur.duration
        end
        if not cur.endUnix then
          cur.endUnix = cur.allDay and date.addDays(cur.startUnix, 1) or (cur.startUnix + 1800)
        end
        cur.duration, cur.cancelled = nil, nil
        local ev = model.normalize(cur)
        if ev then table.insert(events, ev) end
      end
      cur = nil
    elseif cur ~= nil and string.sub(marker, 1, 6) == "BEGIN:" then
      depth += 1
    elseif cur ~= nil and string.sub(marker, 1, 4) == "END:" and depth > 0 then
      depth -= 1
    elseif cur ~= nil and depth == 0 then
      local name, params, value = splitProperty(line)
      if name then
        name = string.upper(name)
        local upperParams = string.upper(params) .. ";"
        -- VALUE=DATE, but not VALUE=DATE-TIME.
        local dateOnly = string.find(upperParams, ";VALUE=DATE;", 1, true) ~= nil
        local tzid = string.match(upperParams, ';TZID="?([^;"]+)"?;')
        local utc = tzid ~= nil and UTC_ZONES[tzid] == true

        if name == "UID" then
          cur.id = value
        elseif name == "SUMMARY" then
          cur.title = unescape(value)
        elseif name == "LOCATION" then
          cur.location = unescape(value)
        elseif name == "URL" then
          cur.url = value
        elseif name == "COLOR" then
          cur.color = value
        elseif name == "RRULE" then
          cur.rrule = value
        elseif name == "STATUS" then
          cur.cancelled = string.upper(value) == "CANCELLED"
        elseif name == "DURATION" then
          cur.duration = parseDuration(value)
        elseif name == "DTSTART" then
          local ts, allDay = parseStamp(value, dateOnly, utc)
          cur.startUnix, cur.allDay = ts, allDay
        elseif name == "DTEND" then
          local ts = parseStamp(value, dateOnly, utc)
          cur.endUnix = ts
        end
      end
    end
  end

  return events, recurring
end

-- Walks <root>/<collection>/*.ics. Reads are async and fan out, so the results
-- are collected by a countdown rather than in order.
function M.fetch(opts, done)
  local root = noctalia.expandPath(opts.vdirPath or "~/.calendars")
  local dirs, err = noctalia.listDir(root)
  if not dirs then
    done(nil, "vdir path not readable: " .. root .. " (" .. tostring(err) .. ")")
    return
  end

  local files = {}
  for _, name in ipairs(dirs) do
    local sub = root .. "/" .. name
    local info = noctalia.fileInfo(sub)
    if info and info.isDir then
      local inner = noctalia.listDir(sub)
      for _, f in ipairs(inner or {}) do
        if string.sub(f, -4) == ".ics" then
          table.insert(files, { path = sub .. "/" .. f, calendar = name })
        end
      end
    elseif string.sub(name, -4) == ".ics" then
      table.insert(files, { path = sub, calendar = "default" })
    end
  end

  if #files == 0 then
    done({}, nil)
    return
  end

  -- Noctalia allows four outstanding readFileAsync calls per runtime and
  -- refuses the rest, so reads go out at most four at a time, the next one
  -- starting as each lands. A refused read (the budget taken elsewhere in this
  -- runtime) falls back to a synchronous read rather than being dropped, which
  -- would leave the countdown short and the fetch hanging forever.
  local MAX_IN_FLIGHT = 4
  local events, recurring, pending = {}, 0, #files
  local nextIndex, inFlight, finished = 1, 0, false

  local function take(f, contents)
    if contents then
      local parsed, rec = M.parseIcs(contents, f.calendar)
      for _, ev in ipairs(parsed) do table.insert(events, ev) end
      recurring += rec
    end
    pending -= 1
  end

  local function finish()
    if finished or pending > 0 then return end
    finished = true
    if recurring > 0 then
      noctalia.log(string.format(
        "fiaker: %d recurring event(s) shown as a single instance - vdir backend does not expand RRULE",
        recurring))
    end
    -- Only the window the views ask for: a vdirsyncer mirror can hold years.
    local from, to = opts.from, opts.to
    if from and to then
      local inWindow = {}
      for _, ev in ipairs(events) do
        if model.overlaps(ev, from, to) then table.insert(inWindow, ev) end
      end
      events = inWindow
    end
    done(model.sortByStart(events), nil)
  end

  local pump
  pump = function()
    while inFlight < MAX_IN_FLIGHT and nextIndex <= #files do
      local f = files[nextIndex]
      nextIndex += 1
      inFlight += 1
      local accepted = noctalia.readFileAsync(f.path, function(contents)
        inFlight -= 1
        take(f, contents)
        pump()
        finish()
      end)
      if not accepted then
        inFlight -= 1
        take(f, noctalia.readFile(f.path))
      end
    end
    finish()
  end

  pump()
end

return M
