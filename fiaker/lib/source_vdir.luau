--!nonstrict
-- Reads a vdir: a directory of collection folders, each holding one .ics file
-- per event. That is exactly what vdirsyncer writes, and exactly what
-- Noctalia's own `provider = "vdir"` account reads - so pointing both at the
-- same path gives one source of truth with no duplicated auth.
--
-- Recurring events are expanded here (lib/recur.luau): RRULE with EXDATE,
-- and RECURRENCE-ID overrides that move or cancel one instance. Each fetch
-- asks for a window, and only instances in it are made.
--
-- Known limitation: a DTSTART with a TZID is read as local wall-clock time.
-- Correct for the common case (your own calendars, your own timezone), wrong
-- for events pinned to another zone.

local model = require("./model.luau")
local date = require("./date.luau")
local recur = require("./recur.luau")

local M = {}

M.needsPolling = true

-- Interprets a Y/M/D h:m:s table as UTC and returns epoch seconds, or nil
-- for an instant Luau cannot represent. Correct under both readings of
-- os.time(table): on Lua 5.4 (local) the offset term fixes it up; on Luau
-- (UTC) the first line is already the answer and the offset term is zero.
local function timegm(t)
  local asLocal = os.time(t)
  if asLocal == nil then return nil end
  local utcView = os.date("!*t", asLocal)
  if utcView == nil then return nil end
  utcView.isdst = nil
  local back = os.time(utcView)
  if back == nil then return nil end
  return asLocal + (asLocal - back)
end

-- A stamp is a wall-clock time kept apart from any time zone, so it can be
-- moved by whole days (a recurrence) before it becomes an instant:
--   { day = day number, sec = seconds since midnight, allDay, utc }
-- "20260921T083000Z" | "20260921T083000" | "20260921"
local function parseStamp(value, isDateOnly, isUtc)
  local y, mo, d = string.match(value, "^(%d%d%d%d)(%d%d)(%d%d)")
  if not y then return nil end
  local day = date.dayNumber(tonumber(y), tonumber(mo), tonumber(d))
  if isDateOnly or #value == 8 then
    return { day = day, sec = 0, allDay = true, utc = false }
  end
  local h, mi, sec = string.match(value, "T(%d%d)(%d%d)(%d%d)")
  if not h then return nil end
  return {
    day = day,
    sec = tonumber(h) * 3600 + tonumber(mi) * 60 + tonumber(sec),
    allDay = false,
    utc = string.sub(value, -1) == "Z" or isUtc == true,
  }
end

-- The instant a stamp's wall clock names. A date alone is local midnight:
-- DTEND is exclusive, so an all-day event from the 21st to the 22nd covers
-- the 21st and nothing of the 22nd. (Noon first, then back to the start of
-- the day, so a DST jump cannot shift it.) nil before 1970, which Luau's
-- clock cannot hold.
local function instant(day, sec, allDay, utc)
  if day < 1 then return nil end
  local y, m, d = date.civil(day)
  if allDay then
    local noon = date.mktime({ year = y, month = m, day = d, hour = 12 })
    if noon == nil then return nil end
    return date.startOfDay(noon)
  end
  local fields = {
    year = y, month = m, day = d,
    hour = math.floor(sec / 3600), min = math.floor(sec / 60) % 60, sec = sec % 60,
  }
  if utc then return timegm(fields) end
  return date.mktime(fields)
end

local function stampInstant(st)
  return instant(st.day, st.sec, st.allDay, st.utc)
end

-- "PT1H30M", "P1D", "P2W" -> whole days and seconds, or nil. Days are
-- calendar days (RFC 5545): P1D from a DST day ends at the same wall clock
-- the next day, not 24 hours later.
local function parseDuration(value)
  local sign, body = string.match(value, "^([%+%-]?)P(.+)$")
  if not body then return nil end
  local days, secs = 0, 0
  local weeks = string.match(body, "^(%d+)W$")
  if weeks then
    days = tonumber(weeks) * 7
  else
    local d = string.match(body, "^(%d+)D")
    local time = string.match(body, "T(.*)$")
    if d then days = tonumber(d) end
    if time then
      local h = string.match(time, "(%d+)H")
      local m = string.match(time, "(%d+)M")
      local sec = string.match(time, "(%d+)S")
      if h then secs = secs + tonumber(h) * 3600 end
      if m then secs = secs + tonumber(m) * 60 end
      if sec then secs = secs + tonumber(sec) end
    end
    if not d and not time then return nil end
  end
  if sign == "-" then days, secs = -days, -secs end
  return { days = days, secs = secs }
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

-- How long an event lasts, as whole days plus seconds of wall clock, from
-- DTEND or DURATION or the defaults (a day, or half an hour).
local function lengthOf(ev)
  local st = ev.start
  if ev["end"] then
    local e = ev["end"]
    if st.allDay then
      return math.max(0, e.day - st.day), 0
    end
    return 0, math.max(0, (e.day - st.day) * 86400 + e.sec - st.sec)
  end
  if ev.duration then
    return math.max(0, ev.duration.days), math.max(0, ev.duration.secs)
  end
  if st.allDay then return 1, 0 end
  return 0, 1800
end

-- Whether an instance starting at (`day`, `at`) is excluded by `list`: an
-- EXDATE or the RECURRENCE-ID of an override. A date alone matches the
-- whole day.
local function excluded(list, day, at)
  if list == nil then return false end
  for _, ex in ipairs(list) do
    if ex.allDay then
      if ex.day == day then return true end
    elseif at ~= nil and stampInstant(ex) == at then
      return true
    end
  end
  return false
end

-- One event as it goes to the views, starting on `day`.
local function instanceOf(ev, day, days, secs, calendarName, recurring)
  local st = ev.start
  local at = instant(day, st.sec, st.allDay, st.utc)
  if at == nil then return nil end
  local total = st.sec + secs
  local endDay = day + days + math.floor(total / 86400)
  local stop = instant(endDay, total % 86400, st.allDay, st.utc)
  if stop == nil then return nil end
  local id = ev.id
  if recurring and id then id = id .. "@" .. tostring(at) end
  return model.normalize({
    id = id, title = ev.title or "", location = ev.location, url = ev.url, color = ev.color,
    calendar = calendarName, startUnix = at, endUnix = stop, allDay = st.allDay,
  }), at
end

-- Returns (events, recurringCount). With a window (`from`, `to`, epoch
-- seconds), recurring events are expanded to every instance in it; without
-- one, each shows its first instance only.
function M.parseIcs(text, calendarName, from, to)
  local raw = {}
  local cur = nil
  -- Components nested in the event (VALARM) carry SUMMARY, UID and friends of
  -- their own, which must not overwrite the event's.
  local depth = 0

  for _, line in ipairs(unfold(text)) do
    local marker = string.upper((string.gsub(line, "%s+$", "")))
    if marker == "BEGIN:VEVENT" and cur == nil then
      cur, depth = { exdates = {} }, 0
    elseif marker == "END:VEVENT" and cur ~= nil and depth == 0 then
      if cur.start then table.insert(raw, cur) end
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
          cur.start = parseStamp(value, dateOnly, utc)
        elseif name == "DTEND" then
          cur["end"] = parseStamp(value, dateOnly, utc)
        elseif name == "EXDATE" then
          for part in string.gmatch(value, "[^,]+") do
            local ex = parseStamp(part, dateOnly, utc)
            if ex then table.insert(cur.exdates, ex) end
          end
        elseif name == "RECURRENCE-ID" then
          cur.recurrenceId = parseStamp(value, dateOnly, utc)
        end
      end
    end
  end

  -- An override (RECURRENCE-ID) replaces one instance of the event with its
  -- UID: that instance goes, and the override shows instead, unless it is
  -- cancelled.
  local moved = {}
  for _, ev in ipairs(raw) do
    if ev.recurrenceId and ev.id then
      moved[ev.id] = moved[ev.id] or {}
      table.insert(moved[ev.id], ev.recurrenceId)
    end
  end

  local events, recurring = {}, 0
  local function add(ev)
    if ev then table.insert(events, ev) end
  end
  for _, ev in ipairs(raw) do
    if not ev.cancelled then
      local days, secs = lengthOf(ev)
      local st = ev.start
      local rule = nil
      if ev.rrule and not ev.recurrenceId then
        recurring += 1
        rule = recur.parse(ev.rrule)
      end
      local skip = moved[ev.id or ""]
      if rule and from and to then
        local untilStamp = rule["until"] and parseStamp(rule["until"], false, false)
        local untilAt = untilStamp and not untilStamp.allDay and untilStamp.utc and stampInstant(untilStamp)
        local function pastUntil(day)
          if untilStamp == nil then return false end
          if untilStamp.allDay then return day > untilStamp.day end
          if untilStamp.utc then
            local at = instant(day, st.sec, st.allDay, st.utc)
            return untilAt ~= nil and at ~= nil and at > untilAt
          end
          return day > untilStamp.day or (day == untilStamp.day and st.sec > untilStamp.sec)
        end
        -- Day numbers around the window, wide enough for any time zone and
        -- for instances that began before it and still run.
        local fromDay = math.floor(from / 86400) - 2 - days - math.ceil(secs / 86400)
        local toDay = math.floor(to / 86400) + 2
        for _, day in ipairs(recur.days(rule, st.day, fromDay, toDay, pastUntil)) do
          local at = instant(day, st.sec, st.allDay, st.utc)
          if at ~= nil and not excluded(ev.exdates, day, at) and not excluded(skip, day, at) then
            local inst = instanceOf(ev, day, days, secs, calendarName, true)
            if inst and model.overlaps(inst, from, to) then add(inst) end
          end
        end
      else
        -- A single event, an override, or a recurring one without a window
        -- (or with a rule this cannot expand): the first instance, unless an
        -- EXDATE or an override took it.
        local at = instant(st.day, st.sec, st.allDay, st.utc)
        local isMaster = ev.recurrenceId == nil
        local gone = isMaster and (excluded(ev.exdates, st.day, at) or excluded(skip, st.day, at))
        if not gone then add((instanceOf(ev, st.day, days, secs, calendarName, false))) end
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

  -- One file that does not parse (or trips over something unexpected) must
  -- not stop the countdown, or the fetch never finishes and the calendar
  -- freezes until the settings change.
  local function take(f, contents)
    if contents then
      local ok, parsed, rec = pcall(M.parseIcs, contents, f.calendar, opts.from, opts.to)
      if ok then
        for _, ev in ipairs(parsed) do table.insert(events, ev) end
        recurring += rec
      else
        noctalia.log("fiaker: skipped " .. f.path .. ": " .. tostring(parsed))
      end
    end
    pending -= 1
  end

  local function finish()
    if finished or pending > 0 then return end
    finished = true
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
