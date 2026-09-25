--!nonstrict
-- [[service]]: runs the light, and tells it when to glow and when to flash.
--
-- The light is lib/kerzenlicht.py, a small Wayland client run through uv: no
-- plugin entry can draw over the whole screen, so it is its own process. It
-- runs for as long as the plugin is enabled, since telling a shake needs the
-- cursor while nothing shows. It prints "on" once a second while it runs;
-- this watches for that, and starts it again if it dies. When the service
-- goes away, the helper's next "on" hits a closed pipe and it quits, so the
-- light is never left behind without the shell.
--
-- Commands go to the helper as signals, to the pid it writes itself (never
-- pkill -f: that would hit the uv parent too, and a user signal kills uv):
-- SIGUSR1 flashes, SIGUSR2 has it read the glow file again. It answers with
-- "glow on" / "glow off", and the tile follows that.
--
-- A new notification flashes too: `busctl --user monitor` sees every Notify
-- call on the session bus, since plugins are not told about notifications.
--
--   noctalia msg plugin 137-trimethylxanthin/kerzenlicht:watch all toggle   # the glow
--   noctalia msg plugin 137-trimethylxanthin/kerzenlicht:watch all on
--   noctalia msg plugin 137-trimethylxanthin/kerzenlicht:watch all off
--   noctalia msg plugin 137-trimethylxanthin/kerzenlicht:watch all flash    # a flash

local TOOLS = { "uv", "pkill", "pgrep", "noctalia" }
local TAG = "noctalia-kerzenlicht-"

local missing = {}
for _, tool in ipairs(TOOLS) do
  if not noctalia.commandExists(tool) then
    table.insert(missing, tool)
  end
end
local hasBusctl = noctalia.commandExists("busctl")

-- The helper: "off", "starting" (uv may still be fetching pywayland), "on".
local mode = "off"
local lastBeat = 0
local startedAt = 0
-- The glow as asked for, and as the helper last said it is.
local glow = false
local glowShown = false
-- A flash asked for while the helper was still starting.
local flashPending = 0
-- Set for good once the compositor turns out not to have what it takes.
local unsupported = nil
-- Starts that failed in a row; each waits longer before the next.
local failures = 0
local retryAt = 0
-- Do Not Disturb as it was before the glow turned it on, or nil.
local dndBefore = nil
-- Bumped on every start and stop, so lines from a helper that was already
-- told to stop do not count. It is also in the helper's command line
-- (--tag), so stopping one run can never hit the next.
local generation = 0
local session = tostring(noctalia.nowMs())
-- Until helpers left over from an earlier session are cleared away, a start
-- waits here instead of racing the cleanup.
local ready = false

local STARTUP_GRACE_MS = 90000 -- a first run downloads pywayland
local BEAT_TIMEOUT_MS = 5000
local RETRY_MS = { 2000, 10000, 60000 }
local STEADY_MS = 30000 -- running this long, a helper's failures are forgotten
local FLASH_PENDING_MS = 5000

local function publish()
  local shown = "off"
  if glow then
    shown = if glowShown then "on" else "starting"
  end
  noctalia.state.set("status", {
    mode = shown,
    available = #missing == 0 and unsupported == nil,
  })
end

-- The same bounds as plugin.toml and the helper, so every path agrees.
local RADIUS = { 5, 400 }
local SOFTNESS = { 0, 300 }
local BRIGHTNESS = { 0.1, 1.0 }
local DIM = { 0.1, 0.9 }
local FLASH = { 0.3, 10 }

local function number(key, default, bounds)
  local value = tonumber(noctalia.getConfig(key)) or default
  return math.max(bounds[1], math.min(bounds[2], value))
end


local function tag(gen)
  return TAG .. session .. "-" .. gen
end

local function dataPath(name)
  local dir = noctalia.pluginDataDir()
  if dir == nil or string.find(dir, "'", 1, true) then
    return nil
  end
  return dir .. "/" .. name
end

local function pidPath(gen)
  return dataPath("helper-" .. session .. "-" .. gen .. ".pid")
end

local function glowPath()
  return dataPath("glow")
end

-- The helper runs under sh rather than exec'd, so that when it ends, however
-- it ends, the stream gets one last line saying so.
local function command(gen)
  local dir = noctalia.pluginDir()
  local pidfile, glowfile = pidPath(gen), glowPath()
  if dir == nil or string.find(dir, "'", 1, true) or pidfile == nil or glowfile == nil then
    noctalia.log("kerzenlicht: cannot quote the plugin paths " .. tostring(dir))
    return nil
  end
  -- Only numbers, a fixed word and the tag go in besides the single-quoted
  -- paths, so this string is safe for the shell runStream hands it to.
  return string.format(
    "uv run --quiet --script '%s/lib/kerzenlicht.py' --radius %d --softness %d --brightness %.3f"
      .. " --flash-radius %d --dim %.3f --flash %.2f%s --pidfile '%s' --glow-file '%s' --tag %s 2>&1; echo \"exited $?\"",
    dir,
    math.floor(number("radius", 30, RADIUS)),
    math.floor(number("softness", 15, SOFTNESS)),
    number("brightness", 0.6, BRIGHTNESS),
    math.floor(number("flash_radius", 18, RADIUS)),
    number("dim", 0.65, DIM),
    number("flash_seconds", 1.5, FLASH),
    if noctalia.getConfig("on_shake") ~= false then " --shake" else "",
    pidfile,
    glowfile,
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

-- Stops still in progress, and what waits for all of them: a new light only
-- starts once every old one is really gone, so two never overlap.
local killing = 0
local afterKills = {}

local function whenQuiet(fn)
  if killing == 0 then
    fn()
  else
    table.insert(afterKills, fn)
  end
end

local function kill(gen, done)
  local pattern = if gen ~= nil then ("--tag " .. tag(gen) .. "$") else ("kerzenlicht\\.py .*--tag " .. TAG)
  killing += 1
  local function finished()
    killing -= 1
    local pidfile = gen ~= nil and pidPath(gen)
    if pidfile and noctalia.fileExists(pidfile) then
      noctalia.removeFile(pidfile) -- a SIGKILL leaves it behind
    end
    if done then
      done()
    end
    if killing == 0 then
      local waiting = afterKills
      afterKills = {}
      for _, fn in ipairs(waiting) do
        fn()
      end
    end
  end
  -- Noctalia runs a handful of commands per plugin at once and refuses the
  -- rest without calling back; a refused stop must still count as done, or
  -- no helper would ever start again. (The helper's own heartbeat still
  -- ends it once the service lets go of its pipe.) Ten seconds covers the
  -- two the script can take.
  if not noctalia.runAsync({ "sh", "-c", KILL, "sh", pattern }, finished, 10000) then
    noctalia.log("kerzenlicht: could not run pkill; going on")
    finished()
  end
end

-- Pid files from runs that were killed outright, in earlier sessions too.
local function sweepPidFiles()
  local dir = noctalia.pluginDataDir()
  local names = dir and noctalia.listDir(dir)
  if type(names) ~= "table" then
    return
  end
  for _, entry in ipairs(names) do
    local name = if type(entry) == "table" then entry.name else entry
    if type(name) == "string" and string.match(name, "^helper%-[%d%-]+%.pid$") then
      noctalia.removeFile(dir .. "/" .. name)
    end
  end
end

-- Sends the running helper a signal, by the pid it wrote.
local function signal(name)
  if mode ~= "on" then
    return false
  end
  local pidfile = pidPath(generation)
  local pid = pidfile and noctalia.fileExists(pidfile) and noctalia.string.trim(noctalia.readFile(pidfile) or "")
  if not pid or not string.match(pid, "^%d+$") then
    return false
  end
  noctalia.runAsync({ "kill", "-" .. name, pid })
  return true
end

-- One Do Not Disturb change at a time, in order: an "on" and a quick "off"
-- sent side by side could land the other way round and leave it on.
local dndSending = false
local dndWanted = nil

local function sendDnd()
  if dndSending or dndWanted == nil then
    return
  end
  local on = dndWanted
  dndWanted = nil
  dndSending = true
  local accepted = noctalia.runAsync({ "noctalia", "msg", "notification-dnd-set", on and "on" or "off" }, function()
    dndSending = false
    sendDnd()
  end)
  if not accepted then
    dndSending = false
    noctalia.runAsync({ "noctalia", "msg", "notification-dnd-set", on and "on" or "off" })
  end
end

local function setDnd(on)
  dndWanted = on
  sendDnd()
end

-- With "Also Do Not Disturb", the glow turns it on and puts it back the way
-- it was when the glow goes out. An answer that arrives after the glow was
-- switched off and on again is ignored, or it could remember "on" from its
-- own doing.
local dndToken = 0
local function takeDnd()
  if noctalia.getConfig("also_dnd") ~= true then
    return
  end
  local token = dndToken
  noctalia.runAsync({ "noctalia", "msg", "notification-dnd-status" }, function(result)
    local text = noctalia.string.trim(result.stdout or "")
    if token == dndToken and glow and (text == "on" or text == "off") then
      dndBefore = text == "on"
      if not dndBefore then
        setDnd(true)
      end
    end
  end)
end

local function giveDnd()
  dndToken += 1
  if dndBefore == false then
    setDnd(false)
  end
  dndBefore = nil
end

-- Tells the helper what the glow should be: the file first, then the signal
-- to read it. One that is still starting reads the file on its own.
local function sendGlow()
  local path = glowPath()
  if path then
    noctalia.writeFile(path, if glow then "on" else "off")
  end
  signal("USR2")
end

local function setGlow(on)
  if on == glow then
    return
  end
  glow = on
  if on then
    takeDnd()
  else
    giveDnd()
  end
  sendGlow()
  publish()
end

-- The helper is gone for good (this compositor lacks what it needs, or it
-- failed too often): the glow goes out with it.
local function giveUp()
  generation = generation + 1
  mode = "off"
  retryAt = 0
  glowShown = false
  if glow then
    glow = false
    giveDnd()
    sendGlow()
  end
  publish()
end

-- The helper went away by itself: try again a little later, a little later
-- each time. The glow stays asked for, and comes back with it.
local function lost(why)
  noctalia.log("kerzenlicht: " .. why)
  local pidfile = pidPath(generation)
  if pidfile and noctalia.fileExists(pidfile) then
    noctalia.removeFile(pidfile) -- a helper that was killed leaves it behind
  end
  generation = generation + 1
  mode = "off"
  glowShown = false
  failures += 1
  if failures > #RETRY_MS then
    local wanted = glow
    giveUp()
    if wanted then
      noctalia.notifyError(noctalia.tr("title"), noctalia.tr("failed"))
    end
    return
  end
  retryAt = noctalia.nowMs() + RETRY_MS[failures]
  publish()
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
      if glowShown ~= glow then
        sendGlow() -- asked for while it was starting, and not yet signalled
      end
      if flashPending > 0 and lastBeat - flashPending < FLASH_PENDING_MS then
        signal("USR1")
      end
      flashPending = 0
    end
  elseif line == "glow on" or line == "glow off" then
    glowShown = line == "glow on"
    if glowShown ~= glow then
      sendGlow() -- it read the file before the last change
    end
    publish()
  elseif string.sub(line, 1, 12) == "unsupported:" then
    unsupported = noctalia.string.trim(string.sub(line, 13))
    noctalia.log("kerzenlicht: compositor lacks " .. unsupported)
    giveUp()
  elseif string.sub(line, 1, 7) == "exited " then
    -- Only reached when nobody stopped it: a stop bumps the generation first.
    if unsupported == nil then
      lost("helper " .. line)
    end
  elseif line ~= "" then
    noctalia.log("kerzenlicht: " .. line)
  end
end

-- Launches a helper for the current generation.
local function launch()
  local gen = generation
  local cmd = command(gen)
  if cmd == nil then
    return giveUp()
  end
  mode = "starting"
  startedAt = noctalia.nowMs()
  lastBeat = 0
  glowShown = false
  publish()
  local ok = noctalia.runStream(cmd, function(line)
    onLine(line, gen)
  end)
  if not ok then
    lost("could not start the helper")
  end
end

local function start()
  if #missing > 0 or unsupported ~= nil or not ready or mode ~= "off" then
    return
  end
  retryAt = 0
  generation = generation + 1
  local want = generation
  mode = "starting"
  startedAt = noctalia.nowMs()
  publish()
  whenQuiet(function()
    if generation == want and mode == "starting" then
      launch()
    end
  end)
end

-- The old helper is gone before the new one starts, so the two never
-- overlap. Only the newest of several quick restarts (a slider being dragged)
-- launches anything.
local function restart()
  if mode == "off" then
    return start()
  end
  local gen = generation
  generation = generation + 1
  local want = generation
  mode = "starting"
  startedAt = noctalia.nowMs() -- or the startup timeout counts from the last launch
  glowShown = false
  publish()
  kill(gen, function()
    whenQuiet(function()
      if generation == want and mode == "starting" then
        launch()
      end
    end)
  end)
end

-- Says why nothing happens, when someone asked for something.
local function complain()
  if #missing > 0 then
    noctalia.notifyError(noctalia.tr("title"), noctalia.tr("missing", { tools = table.concat(missing, ", ") }))
    return true
  elseif unsupported ~= nil then
    noctalia.notifyError(noctalia.tr("title"), noctalia.tr("unsupported", { protocols = unsupported }))
    return true
  end
  return false
end

-- A flash someone asked for says why when there can be none; one from a
-- message or a shake just does not happen.
local function flash(asked)
  if #missing > 0 or unsupported ~= nil then
    if asked then
      complain()
    end
    return
  end
  if not signal("USR1") then
    flashPending = noctalia.nowMs()
    -- Only someone asking starts over a helper that gave up; a message or
    -- a shake does not, or every notification would set off new retries.
    if asked and mode == "off" and retryAt == 0 then
      failures = 0
      start()
    end
  end
end

local function toggleGlow(on)
  if on == nil then
    on = not glow
  end
  if on and complain() then
    return
  end
  setGlow(on)
  if on and mode == "off" and retryAt == 0 then
    failures = 0 -- it gave up earlier; asking is a fresh start
    start()
  end
end

-- ── Notifications ─────────────────────────────────────────────────────────────
--
-- `busctl --user monitor` prints every matching message on the session bus
-- as one JSON line; the payload of Notify is (app, replaces_id, icon,
-- summary, body, actions, hints, timeout). It ends when the bus goes away;
-- the echo after it says so, and a tick later a new one starts.

-- A notification with a picture (an avatar, a cover) carries it as a long
-- array of numbers, easily past the 64 KiB a stream line may have, and such a
-- line would be dropped. awk swaps those arrays for null first; they hold no
-- braces of their own, so the JSON stays whole. fflush keeps it line by line.
local MONITOR = "busctl --user monitor --json=short --match "
  .. "\"type='method_call',interface='org.freedesktop.Notifications',member='Notify'\""
  .. " 2>/dev/null | awk '{ gsub(/\"(image-data|image_data|icon_data)\":\\{[^}]*\\}/, \"\\\"x\\\":null\"); print; fflush() }'"
  .. "; echo kerzenlicht:ended"

local monitorGen = 0
local monitoring = false
local monitorAfter = 0

local function onMessages()
  return noctalia.getConfig("on_message") ~= false
end

-- The apps to flash for, lowercased; empty means every app.
local function appList()
  local list = {}
  for name in string.gmatch(string.lower(tostring(noctalia.getConfig("message_apps") or "")), "[^,]+") do
    name = noctalia.string.trim(name)
    if name ~= "" then
      list[name] = true
    end
  end
  return list
end

local function hint(hints, key)
  local entry = type(hints) == "table" and hints[key]
  return if type(entry) == "table" then entry.data else nil
end

-- Whether one Notify call is a message worth a flash.
local function worthFlash(data)
  if type(data) ~= "table" then
    return false
  end
  local app, replaces, hints = data[1], data[2], data[7]
  -- An update to one already showing (a player's track, a download's
  -- progress, a volume popup) is not a new message.
  if tonumber(replaces) ~= 0 then
    return false
  end
  if tonumber(hint(hints, "urgency")) == 0 then
    return false -- low urgency: background chatter
  end
  local apps = appList()
  if next(apps) == nil then
    return true
  end
  local names = { app, hint(hints, "desktop-entry") }
  for _, name in ipairs(names) do
    if type(name) == "string" and apps[string.lower(name)] then
      return true
    end
  end
  return false
end

local function onMonitorLine(line, gen)
  if gen ~= monitorGen then
    return
  end
  line = noctalia.string.trim(line or "")
  if line == "kerzenlicht:ended" then
    monitoring = false
    monitorAfter = noctalia.nowMs() + 5000
    return
  end
  if not onMessages() or string.sub(line, 1, 1) ~= "{" then
    return
  end
  local message = noctalia.json.decode(line)
  local payload = type(message) == "table" and message.payload
  if type(payload) ~= "table" or not worthFlash(payload.data) then
    return
  end
  -- Not while Do Not Disturb is on: that is what it is for.
  noctalia.runAsync({ "noctalia", "msg", "notification-dnd-status" }, function(result)
    if noctalia.string.trim(result.stdout or "") == "off" then
      flash(false)
    end
  end)
end

local function monitor()
  monitorGen = monitorGen + 1
  local gen = monitorGen
  monitoring = true
  local ok = noctalia.runStream(MONITOR, function(line)
    onMonitorLine(line, gen)
  end)
  if not ok then
    noctalia.log("kerzenlicht: could not watch for messages; trying again in a minute")
    monitoring = false
    monitorAfter = noctalia.nowMs() + 60000
  end
end

-- ── Ticks ────────────────────────────────────────────────────────────────────

-- A helper that stopped beating is gone: crashed, killed, or never came up.
-- The same tick starts it again after a failure, and the message monitor.
noctalia.setUpdateInterval(2000)
local lastTick = noctalia.nowMs()
function update()
  local now = noctalia.nowMs()
  -- nowMs is the wall clock: after a suspend, or when NTP steps it, the
  -- gap says nothing about the helper, so this tick only starts counting
  -- again.
  local gap = now - lastTick
  lastTick = now
  if gap > 6000 or gap < 0 then
    lastBeat, startedAt = now, now
    if retryAt > 0 then retryAt = now + 2000 end
    return
  end
  if mode == "starting" and startedAt > 0 and now - startedAt > STARTUP_GRACE_MS then
    local gen = generation
    lost("helper did not start")
    kill(gen)
  elseif mode == "on" and now - lastBeat > BEAT_TIMEOUT_MS then
    local gen = generation
    lost("helper stopped answering")
    kill(gen)
  elseif mode == "on" and failures > 0 and now - startedAt > STEADY_MS then
    failures = 0
  elseif mode == "off" and ready and retryAt > 0 and now >= retryAt then
    retryAt = 0
    start()
  end
  if hasBusctl and onMessages() and not monitoring and now >= monitorAfter then
    monitor()
  end
end

local function handle(request)
  if type(request) ~= "table" then
    return
  end
  if request.op == "toggle" then
    toggleGlow(nil)
  elseif request.op == "on" then
    toggleGlow(true)
  elseif request.op == "off" then
    toggleGlow(false)
  elseif request.op == "flash" then
    flash(true)
  end
end

noctalia.state.watch("request", handle)

function onIpc(event, _payload)
  handle({ op = event })
end

-- Any setting the helper is started with applies right away; the others
-- (Also Do Not Disturb, messages and their apps) are read when they are
-- needed.
local function helperKey()
  return table.concat({
    tostring(number("radius", 30, RADIUS)),
    tostring(number("softness", 15, SOFTNESS)),
    tostring(number("brightness", 0.6, BRIGHTNESS)),
    tostring(number("flash_radius", 18, RADIUS)),
    tostring(number("dim", 0.65, DIM)),
    tostring(number("flash_seconds", 1.5, FLASH)),
    tostring(noctalia.getConfig("on_shake") ~= false),
  }, "|")
end
local lastHelperKey = helperKey()

function onConfigChanged()
  local key = helperKey()
  if key == lastHelperKey then
    return
  end
  lastHelperKey = key
  if ready then
    restart()
  end
end

-- Off with the shell, whatever the reason. A reload keeps the glow as it
-- was, since noctalia.state survives one; anything else puts it out, and
-- Do Not Disturb back.
function onExit(_signal, reason)
  if mode ~= "off" then
    kill(generation)
    generation = generation + 1 -- its "exited" line is not a crash
  end
  if reason == "reload" then
    noctalia.state.set("resume", { glow = glow, dndBefore = dndBefore })
  else
    if glow then
      giveDnd()
    end
    local path = glowPath()
    if path then
      noctalia.writeFile(path, "off")
    end
    noctalia.state.set("resume", nil)
  end
end

if #missing > 0 then
  noctalia.log("kerzenlicht: needs " .. table.concat(missing, ", "))
end
if not hasBusctl then
  noctalia.log("kerzenlicht: busctl not found; messages will not flash")
end

-- Whatever an earlier session left running goes first; the helper follows
-- once it is gone, with the glow as a reload left it, or off.
local resume = noctalia.state.get("resume")
noctalia.state.set("resume", nil)
if type(resume) == "table" and resume.glow == true then
  glow = true
  dndBefore = resume.dndBefore
end
do
  local path = glowPath()
  if path then
    noctalia.writeFile(path, if glow then "on" else "off")
  end
end
sweepPidFiles()
kill(nil, function()
  ready = true
  start()
end)

publish()
