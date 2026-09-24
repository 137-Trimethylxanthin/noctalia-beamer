--!nonstrict
-- Reads a vdir: a directory of collection folders, each holding one .ics file
-- per event. That is exactly what vdirsyncer writes, and exactly what
-- Noctalia's own `provider = "vdir"` account reads - so pointing both at the
-- same path gives one source of truth with no duplicated auth.
--
-- Deliberately NOT implemented here: RRULE expansion. It is the heaviest part
-- of a calendar and this plugin should not own it. Recurring events are
-- counted and reported so the UI can say so. Two ways out, in order:
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
local function parseStamp(value: string, isDateOnly: boolean): (number?, boolean)
  local y, mo, d = string.match(value, "^(%d%d%d%d)(%d%d)(%d%d)")
  if not y then return nil, false end

  if isDateOnly or #value == 8 then
    return date.mktime({ year = tonumber(y), month = tonumber(mo), day = tonumber(d), hour = 12 }), true
  end

  local h, mi, s = string.match(value, "T(%d%d)(%d%d)(%d%d)")
  if not h then return nil, false end
  local fields = {
    year = tonumber(y), month = tonumber(mo), day = tonumber(d),
    hour = tonumber(h), min = tonumber(mi), sec = tonumber(s),
  }
  if string.sub(value, -1) == "Z" then
    return timegm(fields), false
  end
  return date.mktime(fields), false
end

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

local function unescape(v: string): string
  v = string.gsub(v, "\\[nN]", "\n")
  v = string.gsub(v, "\\([,;\\])", "%1")
  return v
end

-- Returns (events, recurringCount).
function M.parseIcs(text: string, calendarName: string)
  local events, recurring = {}, 0
  local cur = nil

  for _, line in ipairs(unfold(text)) do
    if line == "BEGIN:VEVENT" then
      cur = {}
    elseif line == "END:VEVENT" then
      if cur and cur.startUnix and cur.title then
        if cur.rrule then
          recurring += 1
          -- Still show the first instance rather than dropping it entirely.
        end
        cur.calendar = calendarName
        if not cur.endUnix then
          cur.endUnix = cur.allDay and (cur.startUnix + 86400) or (cur.startUnix + 1800)
        end
        local ev = model.normalize(cur)
        if ev then table.insert(events, ev) end
      end
      cur = nil
    elseif cur then
      local name, params, value = string.match(line, "^([A-Za-z%-]+)(;?[^:]*):(.*)$")
      if name then
        name = string.upper(name)
        local dateOnly = string.find(params, "VALUE=DATE", 1, true) ~= nil

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
        elseif name == "DTSTART" then
          local ts, allDay = parseStamp(value, dateOnly)
          cur.startUnix, cur.allDay = ts, allDay
        elseif name == "DTEND" then
          local ts = parseStamp(value, dateOnly)
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
