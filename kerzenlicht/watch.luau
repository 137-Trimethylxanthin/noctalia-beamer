--!nonstrict
-- [[service]]: switches the flashlight on and off.
--
-- The flashlight is lib/kerzenlicht.py, a small Wayland client run through uv: no
-- plugin entry can draw over the whole screen, so it is its own process. It
-- prints "on" once a second while it runs; this watches for that, so a
-- helper that died (or never started) turns the tile off again. When the
-- service goes away, the helper's next "on" hits a closed pipe and it quits,
-- so the glow is never left behind without the shell.
--
--   noctalia msg plugin 137-trimethylxanthin/kerzenlicht:watch all toggle
--   noctalia msg plugin 137-trimethylxanthin/kerzenlicht:watch all on
--   noctalia msg plugin 137-trimethylxanthin/kerzenlicht:watch all off

local TOOLS = { "uv", "pkill", "pgrep" }
local TAG = "noctalia-kerzenlicht-"

local missing = {}
for _, tool in ipairs(TOOLS) do
  if not noctalia.commandExists(tool) then
    table.insert(missing, tool)
  end
end

-- "off", "starting" (uv may still be fetching pywayland), "on"
local mode = "off"
local lastBeat = 0
local startedAt = 0
-- Do Not Disturb as it was before the flashlight turned it on, or nil.
local dndBefore = nil
-- Bumped on every start and stop, so lines from a helper that was already
-- told to stop do not count. It is also in the helper's command line
-- (--tag), so stopping one run can never hit the next.
local generation = 0
local session = tostring(noctalia.nowMs())
-- Until helpers left over from an earlier session are cleared away, a start
-- waits here instead of racing the cleanup.
local ready = false
local startWhenReady = false

local STARTUP_GRACE_MS = 90000 -- a first run downloads pywayland
local BEAT_TIMEOUT_MS = 5000

local function publish()
  noctalia.state.set("status", { mode = mode, available = #missing == 0 })
end

-- The same bounds as plugin.toml and the helper, so every path agrees.
local RADIUS = { 5, 400 }
local SOFTNESS = { 0, 300 }
local BRIGHTNESS = { 0.1, 1.0 }

local function number(key, default, bounds)
  local value = tonumber(noctalia.getConfig(key)) or default
  return math.max(bounds[1], math.min(bounds[2], value))
end

local function tag(gen)
  return TAG .. session .. "-" .. gen
end

-- The helper runs under sh rather than exec'd, so that when it ends, however
-- it ends, the stream gets one last line saying so.
local function command(gen)
  local dir = noctalia.pluginDir()
  if dir == nil or string.find(dir, "'", 1, true) then
    noctalia.log("kerzenlicht: cannot quote the plugin path " .. tostring(dir))
    return nil
  end
  -- Only numbers and the tag go in besides the single-quoted path, so this
  -- string is safe for the shell runStream hands it to.
  return string.format(
    "uv run --quiet --script '%s/lib/kerzenlicht.py' --radius %d --softness %d --brightness %.3f --tag %s 2>&1; echo \"exited $?\"",
    dir,
    math.floor(number("radius", 30, RADIUS)),
    math.floor(number("softness", 15, SOFTNESS)),
    number("brightness", 0.6, BRIGHTNESS),
    tag(gen)
  )
end

-- Stops one run, or with no generation every helper any session started
-- (one left over from a crash), and calls `done` once it is really gone:
-- SIGTERM, up to two seconds to exit, then SIGKILL. pkill -f matches the
-- whole command line, the uv parent and the python child alike; the tag is
-- only digits and dashes, so it needs no escaping.
local KILL = [[
pkill -f -- "$1"
i=0
while [ $i -lt 20 ]; do
  pgrep -f -- "$1" >/dev/null || exit 0
  sleep 0.1
  i=$((i + 1))
done
pkill -KILL -f -- "$1"
]]

local function kill(gen, done)
  local pattern = if gen ~= nil then ("--tag " .. tag(gen) .. "$") else ("kerzenlicht\\.py .*--tag " .. TAG)
  noctalia.runAsync({ "sh", "-c", KILL, "sh", pattern }, function()
    if done then
      done()
    end
  end)
end

local function setDnd(on)
  noctalia.runAsync({ "noctalia", "msg", "notification-dnd-set", on and "on" or "off" })
end

-- With "Also Do Not Disturb", the flashlight turns it on and puts it back the
-- way it was when the light goes off. An answer for an earlier run is
-- ignored, or it could remember "on" from its own doing.
local function takeDnd()
  if noctalia.getConfig("also_dnd") ~= true then
    return
  end
  local gen = generation
  noctalia.runAsync({ "noctalia", "msg", "notification-dnd-status" }, function(result)
    local text = noctalia.string.trim(result.stdout or "")
    if gen == generation and mode ~= "off" and (text == "on" or text == "off") then
      dndBefore = text == "on"
      if not dndBefore then
        setDnd(true)
      end
    end
  end)
end

local function giveDnd()
  if dndBefore == false then
    setDnd(false)
  end
  dndBefore = nil
end

-- The light went out by itself: say so, and put things back.
local function lost(message)
  generation = generation + 1
  mode = "off"
  giveDnd()
  publish()
  if message then
    noctalia.notifyError(noctalia.tr("title"), message)
  end
end

local function onLine(line, gen)
  if gen ~= generation then
    return
  end
  line = noctalia.string.trim(line or "")
  if line == "on" then
    lastBeat = noctalia.nowMs()
    if mode == "starting" then
      mode = "on"
      publish()
    end
  elseif string.sub(line, 1, 12) == "unsupported:" then
    local protocols = noctalia.string.trim(string.sub(line, 13))
    noctalia.log("kerzenlicht: compositor lacks " .. protocols)
    lost(noctalia.tr("unsupported", { protocols = protocols }))
  elseif string.sub(line, 1, 7) == "exited " then
    -- Only reached when nobody stopped it: a stop bumps the generation first.
    noctalia.log("kerzenlicht: helper " .. line)
    if mode ~= "off" then
      lost(noctalia.tr("failed"))
    end
  elseif line ~= "" then
    noctalia.log("kerzenlicht: " .. line)
  end
end

-- Launches a helper for the current generation; `keepDnd` is for a restart,
-- which must not take Do Not Disturb a second time.
local function launch(keepDnd)
  local gen = generation
  local cmd = command(gen)
  if cmd == nil then
    return lost(noctalia.tr("failed"))
  end
  mode = "starting"
  startedAt = noctalia.nowMs()
  lastBeat = 0
  publish()
  noctalia.runStream(cmd, function(line)
    onLine(line, gen)
  end)
  if not keepDnd then
    takeDnd()
  end
end

local function start()
  if #missing > 0 then
    return noctalia.notifyError(noctalia.tr("title"), noctalia.tr("missing", { tools = table.concat(missing, ", ") }))
  end
  if not ready then
    startWhenReady = true
    return
  end
  if mode ~= "off" then
    return
  end
  generation = generation + 1
  launch(false)
end

local function stop()
  startWhenReady = false
  if mode == "off" then
    return
  end
  local gen = generation
  generation = generation + 1
  mode = "off"
  kill(gen)
  giveDnd()
  publish()
end

-- The old helper is gone before the new one starts, so the two never
-- overlap. Only the newest of several quick restarts (a slider being dragged)
-- launches anything.
local function restart()
  if mode == "off" then
    return
  end
  local gen = generation
  generation = generation + 1
  local want = generation
  mode = "starting"
  startedAt = noctalia.nowMs() -- or the startup timeout counts from the last launch
  publish()
  kill(gen, function()
    if generation == want and mode == "starting" then
      launch(true)
    end
  end)
end

local function toggle()
  if mode == "off" and not startWhenReady then
    start()
  else
    stop()
  end
end

-- A helper that stopped beating is gone: crashed, killed, or never came up.
noctalia.setUpdateInterval(2000)
function update()
  if mode == "off" then
    return
  end
  local now = noctalia.nowMs()
  if mode == "starting" and startedAt > 0 and now - startedAt > STARTUP_GRACE_MS then
    local gen = generation
    lost(noctalia.tr("failed"))
    kill(gen)
  elseif mode == "on" and now - lastBeat > BEAT_TIMEOUT_MS then
    noctalia.log("kerzenlicht: helper stopped answering")
    local gen = generation
    lost(nil)
    kill(gen)
  end
end

local function handle(request)
  if type(request) ~= "table" then
    return
  end
  if request.op == "toggle" then
    toggle()
  elseif request.op == "on" then
    start()
  elseif request.op == "off" then
    stop()
  end
end

noctalia.state.watch("request", handle)

function onIpc(event, _payload)
  handle({ op = event })
end

-- A new radius, softness or brightness applies right away.
function onConfigChanged()
  restart()
end

-- Off with the shell, whatever the reason. A reload turns it back on, since
-- noctalia.state survives one; anything else leaves it off.
function onExit(_signal, reason)
  if mode == "off" then
    return
  end
  kill(generation)
  generation = generation + 1 -- its "exited" line is not a crash
  if reason == "reload" then
    noctalia.state.set("resume", { dndBefore = dndBefore })
  else
    giveDnd()
    noctalia.state.set("resume", nil)
  end
end

if #missing > 0 then
  noctalia.log("kerzenlicht: needs " .. table.concat(missing, ", "))
end

-- Whatever an earlier session left running goes first; a start asked for in
-- the meantime, or a reload that was on, follows once it is gone.
local resume = noctalia.state.get("resume")
noctalia.state.set("resume", nil)
kill(nil, function()
  ready = true
  if #missing > 0 or mode ~= "off" then
    return
  end
  if type(resume) == "table" then
    startWhenReady = false
    generation = generation + 1
    dndBefore = resume.dndBefore
    launch(true)
  elseif startWhenReady then
    startWhenReady = false
    start()
  end
end)

publish()
