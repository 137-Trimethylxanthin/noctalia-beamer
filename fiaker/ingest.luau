--!nonstrict
-- [[service]] - the only entry that talks to a data source.
--
-- Publishes three keys on the plugin's shared state channel:
--   events         a ±window_days slice, so the month grid has dots on every
--                  cell and paging months never triggers a refetch
--   selected_date  the day every view is looking at (ISO), seeded to today
--   sync           { ok, lastMs, backend, error } for the status line
--
-- The channel is in-memory only and clears when the plugin stops, so the last
-- good fetch is also written to pluginDataDir() and replayed at startup. The
-- views paint instantly from cache, then update when the first fetch lands.

local date = require("./lib/date.luau")
local picker = require("./lib/source.luau")

local source, backend = picker.pick(noctalia.getConfig("source"))
local windowDays = noctalia.getConfig("window_days") or 45
local refreshSeconds = noctalia.getConfig("refresh_seconds") or 300

local cachePath: string? = nil
do
  local dir = noctalia.pluginDataDir()
  if dir then cachePath = dir .. "/events.json" end
end

local function window()
  local today = date.startOfDay(os.time())
  return date.addDays(today, -windowDays), date.addDays(today, windowDays)
end

-- The last slice published, encoded, so an unchanged fetch neither
-- re-renders every view nor rewrites the cache.
local lastEncoded: string? = nil

local function publish(events, err: string?)
  if events then
    local encoded = noctalia.json.encode(events)
    if encoded == nil or encoded ~= lastEncoded then
      lastEncoded = encoded
      noctalia.state.set("events", events)
      if cachePath and encoded then noctalia.writeFile(cachePath, encoded) end
    end
  end
  noctalia.state.set("sync", {
    ok = err == nil,
    lastMs = noctalia.nowMs(),
    backend = backend,
    error = err,
  })
  if err then noctalia.log("fiaker: fetch failed - " .. err) end
end

-- One fetch at a time; asking again meanwhile runs one more afterwards. Each
-- fetch has a number, so the answer of one that was overtaken (say, for the
-- old vdir path after the setting changed) is dropped.
local fetchGen, fetching, fetchAgain = 0, false, false
local lastFetchMs = 0

local function fetch()
  if fetching then
    fetchAgain = true
    return
  end
  fetching = true
  fetchGen += 1
  local gen = fetchGen
  lastFetchMs = noctalia.nowMs()
  local from, to = window()
  source.fetch({
    from = from,
    to = to,
    vdirPath = noctalia.getConfig("vdir_path"),
  }, function(events, err)
    if gen ~= fetchGen then return end
    fetching = false
    publish(events, err)
    if fetchAgain then
      fetchAgain = false
      fetch()
    end
  end)
end

-- A changed source or path makes any fetch in flight the wrong one.
local function refetch()
  fetchGen += 1
  fetching, fetchAgain = false, false
  fetch()
end

-- At midnight, views still on the old today move on to the new one.
local today = date.iso(os.time())
local function rollDay()
  local now = date.iso(os.time())
  if now == today then return end
  local old = today
  today = now
  if noctalia.state.get("selected_date") == old then
    noctalia.state.set("selected_date", now)
  end
  local oldMonth, newMonth = string.sub(old, 1, 7), string.sub(now, 1, 7)
  if oldMonth ~= newMonth and noctalia.state.get("view_month") == oldMonth then
    noctalia.state.set("view_month", newMonth)
  end
  fetch() -- the window moved by a day
end

-- Seed: today's date, plus whatever the last run cached.
noctalia.state.set("selected_date", date.iso(os.time()))
noctalia.state.set("view_month", os.date("%Y-%m", os.time()))

if cachePath and noctalia.fileExists(cachePath) then
  local contents = noctalia.readFile(cachePath)
  if contents then
    local ok, cached = pcall(noctalia.json.decode, contents)
    if ok and type(cached) == "table" then
      noctalia.state.set("events", cached)
    end
  end
end

-- A minute's tick for the midnight roll; fetches keep to refresh_seconds.
noctalia.setUpdateInterval(60000)

-- onEnable() only fires on an explicit enable, and update() not until the first
-- interval elapses - so fetch once at load or a normal shell start shows the
-- cached slice (or nothing) for a full refresh interval.
fetch()

function update()
  rollDay()
  if noctalia.nowMs() - lastFetchMs >= refreshSeconds * 1000 then
    fetch()
  end
end

function onEnable()
  fetch()
end

-- A changed source, path or window means the cached slice is the wrong
-- shape; any other setting (accent, zoom) needs no fetch.
local fetchKey = nil
local function currentFetchKey()
  return table.concat({
    tostring(noctalia.getConfig("source")),
    tostring(noctalia.getConfig("vdir_path")),
    tostring(noctalia.getConfig("window_days")),
  }, "|")
end
fetchKey = currentFetchKey()

function onConfigChanged()
  refreshSeconds = noctalia.getConfig("refresh_seconds") or 300
  local key = currentFetchKey()
  if key == fetchKey then return end
  fetchKey = key
  source, backend = picker.pick(noctalia.getConfig("source"))
  windowDays = noctalia.getConfig("window_days") or 45
  refetch()
end

function onIpc(event: string)
  if event == "refresh" then fetch() end
end

-- The panel's refresh button writes a timestamp rather than calling IPC, so the
-- whole refresh path stays inside the plugin.
noctalia.state.watch("refresh_request", function(value)
  if value ~= nil then fetch() end
end)
