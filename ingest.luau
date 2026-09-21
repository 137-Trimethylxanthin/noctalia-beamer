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

local function publish(events, err: string?)
  if events then
    noctalia.state.set("events", events)
    if cachePath then
      local ok = noctalia.json.encode(events)
      if ok then noctalia.writeFile(cachePath, ok) end
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

local function fetch()
  local from, to = window()
  source.fetch({
    from = from,
    to = to,
    vdirPath = noctalia.getConfig("vdir_path"),
  }, publish)
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

noctalia.setUpdateInterval(refreshSeconds * 1000)

-- onEnable() only fires on an explicit enable, and update() not until the first
-- interval elapses - so fetch once at load or a normal shell start shows the
-- cached slice (or nothing) for a full refresh interval.
fetch()

function update()
  fetch()
end

function onEnable()
  fetch()
end

-- A changed source or window means the cached slice is the wrong shape.
function onConfigChanged()
  source, backend = picker.pick(noctalia.getConfig("source"))
  windowDays = noctalia.getConfig("window_days") or 45
  refreshSeconds = noctalia.getConfig("refresh_seconds") or 300
  noctalia.setUpdateInterval(refreshSeconds * 1000)
  fetch()
end

function onIpc(event: string)
  if event == "refresh" then fetch() end
end

-- The panel's refresh button writes a timestamp rather than calling IPC, so the
-- whole refresh path stays inside the plugin.
noctalia.state.watch("refresh_request", function(value)
  if value ~= nil then fetch() end
end)
