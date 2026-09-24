--!nonstrict
-- [[service]]: keeps the listed apps quiet while Do Not Disturb is on.
--
-- Noctalia's Do Not Disturb already hides popups and skips the sounds the
-- shell plays itself; notifications still go to the history. What it cannot
-- reach is an app that plays its own ping, such as Discord, through its own
-- audio stream. So while Do Not Disturb is on, this mutes those apps' streams,
-- and gives them back when it ends. lib/quiet decides; this file only looks
-- and acts.
--
-- Do Not Disturb is not published to plugins, so it is read with
-- `noctalia msg notification-dnd-status` on a short interval. New streams are
-- seen through `pactl subscribe`, so a ping's stream is muted as it opens;
-- PipeWire also replays the mute on it, which catches the first milliseconds.
--
--   noctalia msg plugin 137-trimethylxanthin/goschen:watch all toggle   # Do Not Disturb on/off
--   noctalia msg plugin 137-trimethylxanthin/goschen:watch all on
--   noctalia msg plugin 137-trimethylxanthin/goschen:watch all off

local quiet = require("./lib/quiet.luau")

local TOOLS = { "pactl", "pacat", "noctalia" }

local missing = {}
for _, tool in ipairs(TOOLS) do
  if not noctalia.commandExists(tool) then
    table.insert(missing, tool)
  end
end

-- nil until the first answer: nothing is muted or given back on a guess.
local dnd = nil
local dndFailures = 0
-- { [key] = { names, streams, seen, returning } }, see lib/quiet: apps muted
-- by Goschen that still have to be given back. On disk, so a crash or restart
-- cannot leave an app muted for good.
local owned = {}
local ownedSaved = nil
local firstSeen = {}
local startedAt = noctalia.nowMs()
local lastStatus = { quiet = {}, busy = {} }

local function ownedPath()
  local dir = noctalia.pluginDataDir()
  return dir and (dir .. "/owned.json") or nil
end

local function loadOwned()
  local path = ownedPath()
  local raw = path and noctalia.fileExists(path) and noctalia.readFile(path)
  local value = raw and noctalia.json.decode(raw)
  if type(value) ~= "table" then
    return {}
  end
  local out = {}
  for key, entry in pairs(value) do
    if type(key) == "string" and type(entry) == "table" and type(entry.names) == "table" then
      out[key] = entry
    end
  end
  return out
end

local function saveOwned()
  local path = ownedPath()
  if path == nil then
    return
  end
  local text = if next(owned) == nil then "" else noctalia.json.encode(owned)
  if text == ownedSaved then
    return
  end
  ownedSaved = text
  if text == "" then
    if noctalia.fileExists(path) then
      noctalia.removeFile(path)
    end
  else
    noctalia.writeFile(path, text)
  end
end

owned = loadOwned()

local function publish()
  noctalia.state.set("status", {
    dnd = dnd == true,
    available = #missing == 0,
    quiet = lastStatus.quiet,
    busy = lastStatus.busy,
  })
end

local function settings()
  local seconds = tonumber(noctalia.getConfig("busy_after")) or 0
  return {
    apps = quiet.parseApps(noctalia.getConfig("apps") or quiet.DEFAULT_APPS),
    respectCalls = noctalia.getConfig("respect_calls") ~= false,
    busyAfterMs = math.max(0, math.min(600, seconds)) * 1000,
  }
end

local function unmuteScript()
  local dir = noctalia.pluginDir()
  return dir and (dir .. "/lib/unmute.sh") or nil
end

-- ── Resets ───────────────────────────────────────────────────────────────────
--
-- A name leaves `owned` only once its reset has worked; a failed one is tried
-- again on a later look, at most every 30 seconds.

local resetting = {}
local resetFailedAt = {}

local function dropName(name)
  local changed = false
  for key, entry in pairs(owned) do
    if entry.returning and entry.names[name] then
      entry.names[name] = nil
      changed = true
      if next(entry.names) == nil and next(entry.streams or {}) == nil then
        owned[key] = nil
      end
    end
  end
  if changed then
    saveOwned()
  end
end

local function resetSaved(name)
  local script = unmuteScript()
  local args = quiet.restoreArgs(name)
  if script == nil or args == nil or resetting[name] then
    return
  end
  local failed = resetFailedAt[name]
  if failed ~= nil and noctalia.nowMs() - failed < 30000 then
    return
  end
  resetting[name] = true
  noctalia.runAsync({ "sh", script, args[1], args[2] }, function(result)
    resetting[name] = nil
    if result.exitCode == 0 then
      resetFailedAt[name] = nil
      dropName(name)
    else
      if resetFailedAt[name] == nil then
        noctalia.log("goschen: could not clear the remembered mute of " .. name .. "; trying again")
      end
      resetFailedAt[name] = noctalia.nowMs()
    end
  end)
end

-- Runs every set-mute and calls `done` once they have all been carried out,
-- so the next look never reads a mute that is still on its way.
local function setMutes(mutes, unmutes, done)
  local pending = #mutes + #unmutes
  if pending == 0 then
    return done()
  end
  local function one()
    pending = pending - 1
    if pending == 0 then
      done()
    end
  end
  for _, index in ipairs(mutes) do
    noctalia.runAsync({ "pactl", "set-sink-input-mute", tostring(index), "1" }, one)
  end
  for _, index in ipairs(unmutes) do
    noctalia.runAsync({ "pactl", "set-sink-input-mute", tostring(index), "0" }, one)
  end
end

local function listJson(what, done)
  noctalia.runAsync({ "pactl", "-f", "json", "list", what }, function(result)
    if result.exitCode ~= 0 then
      return done(nil)
    end
    local value = noctalia.json.decode(result.stdout or "")
    done(if type(value) == "table" then value else nil)
  end)
end

-- ── Looking ──────────────────────────────────────────────────────────────────
--
-- One look at a time, and a look is only over once its mutes have landed and
-- its resets are on their way; a request that comes in meanwhile makes it
-- look once more, so a burst of stream events is two looks.

local looking, again = false, false
local lookStartedAt = 0
local look -- defined below; finishLook needs it first

local function finishLook()
  looking = false
  if again then
    again = false
    look()
  end
end

look = function()
  if #missing > 0 or dnd == nil then
    return
  end
  if looking then
    again = true
    return
  end
  looking = true
  lookStartedAt = noctalia.nowMs()
  listJson("sink-inputs", function(sinks)
    listJson("source-outputs", function(sources)
      if sinks == nil or sources == nil then
        return finishLook()
      end
      local now = noctalia.nowMs()
      local live = {}
      for _, stream in ipairs(sinks) do
        if type(stream.index) == "number" then
          live[stream.index] = true
          firstSeen[stream.index] = firstSeen[stream.index] or now
        end
      end
      for index in pairs(firstSeen) do
        if not live[index] then
          firstSeen[index] = nil
        end
      end

      local config = settings()
      local plan = quiet.plan({
        dnd = dnd == true,
        apps = config.apps,
        sinks = sinks,
        sources = sources,
        owned = owned,
        now = now,
        firstSeen = firstSeen,
        respectCalls = config.respectCalls,
        busyAfterMs = config.busyAfterMs,
      })
      owned = plan.owned
      saveOwned()
      lastStatus = { quiet = plan.quiet, busy = plan.busy }
      publish()
      setMutes(plan.mute, plan.unmute, function()
        for _, name in ipairs(plan.reset) do
          resetSaved(name)
        end
        finishLook()
      end)
    end)
  end)
end

-- Nothing to do while Do Not Disturb is off and nothing is owed back.
local function needed()
  return dnd == true or next(owned) ~= nil
end

local function readDnd(done)
  noctalia.runAsync({ "noctalia", "msg", "notification-dnd-status" }, function(result)
    local text = noctalia.string.trim(result.stdout or "")
    if result.exitCode == 0 and (text == "on" or text == "off") then
      done(text == "on")
    else
      done(nil)
    end
  end)
end

local function refresh()
  readDnd(function(state)
    if state == nil then
      dndFailures = dndFailures + 1
      if dndFailures == 5 then
        noctalia.log("goschen: cannot read Do Not Disturb (noctalia msg notification-dnd-status); waiting")
      end
      return
    end
    dndFailures = 0
    if state ~= dnd then
      dnd = state
      publish()
    end
    if needed() then
      look()
    end
  end)
end

local function setDnd(state)
  local argv = if state == nil
    then { "noctalia", "msg", "notification-dnd-toggle" }
    else { "noctalia", "msg", "notification-dnd-set", state and "on" or "off" }
  noctalia.runAsync(argv, function()
    refresh()
  end)
end

-- ── Events ───────────────────────────────────────────────────────────────────
--
-- `pactl subscribe` ends when pipewire-pulse restarts; the echo after it says
-- so, and the next tick starts a new one. Lines from an old one are ignored.

local subscription = 0
local subscribed = false
local subscribeAfter = 0

local function onStreamLine(line, gen)
  if gen ~= subscription then
    return
  end
  if line == "goschen:ended" then
    subscribed = false
    subscribeAfter = noctalia.nowMs() + 3000
    return
  end
  local kind, facility, index = quiet.parseEvent(line)
  if kind == nil then
    return
  end
  if facility == "sink-input" and index ~= nil then
    if kind == "new" then
      firstSeen[index] = noctalia.nowMs()
    elseif kind == "remove" then
      firstSeen[index] = nil
    end
  end
  -- A new playback stream may be a ping; a new or closed recording stream
  -- is a call starting or ending.
  if (facility == "sink-input" and kind == "new") or facility == "source-output" then
    if needed() then
      look()
    end
  end
end

local function subscribe()
  subscription = subscription + 1
  local gen = subscription
  subscribed = true
  noctalia.runStream("pactl subscribe 2>/dev/null; echo goschen:ended", function(line)
    onStreamLine(noctalia.string.trim(line or ""), gen)
  end)
end

-- Streams already open at startup count as old for the age rule, since they
-- were playing before Goschen could see them start; ages kept over a reload
-- win, and a stream that is Goschen's doing is never old, or a reload during
-- Do Not Disturb would hand its pings back.
local function seedAges(sinks)
  local kept = noctalia.state.get("firstSeen")
  noctalia.state.set("firstSeen", nil)
  local ours = {}
  for _, entry in pairs(owned) do
    for index in pairs(entry.streams or {}) do
      ours[tostring(index)] = true
    end
  end
  for _, stream in ipairs(sinks or {}) do
    local index = stream.index
    if type(index) == "number" and firstSeen[index] == nil then
      local since = type(kept) == "table" and tonumber(kept[tostring(index)]) or nil
      if since ~= nil then
        firstSeen[index] = since
      elseif ours[tostring(index)] then
        firstSeen[index] = startedAt
      else
        firstSeen[index] = startedAt - 24 * 3600 * 1000
      end
    end
  end
end

if #missing > 0 then
  noctalia.log("goschen: needs " .. table.concat(missing, ", ") .. "; staying idle")
  noctalia.notifyError(noctalia.tr("title"), noctalia.tr("missing", { tools = table.concat(missing, ", ") }))
else
  listJson("sink-inputs", function(sinks)
    seedAges(sinks)
    subscribe()
    refresh()
  end)
end

-- Do Not Disturb can be flipped anywhere (the control center, a keybind,
-- noctalia msg), and only this notices it. The same tick is the safety net
-- for stream events that were missed.
noctalia.setUpdateInterval(2000)
function update()
  if #missing > 0 then
    return
  end
  local now = noctalia.nowMs()
  if looking and now - lookStartedAt > 15000 then
    noctalia.log("goschen: a look never finished; starting over")
    looking, again = false, false
  end
  if not subscribed and now >= subscribeAfter then
    subscribe()
  end
  refresh()
end

local function handle(request)
  if type(request) ~= "table" then
    return
  end
  if request.op == "toggle" then
    setDnd(nil)
  elseif request.op == "on" then
    setDnd(true)
  elseif request.op == "off" then
    setDnd(false)
  end
end

noctalia.state.watch("request", handle)

function onIpc(event, _payload)
  handle({ op = event })
end

function onConfigChanged()
  if needed() then
    look()
  end
end

-- Give every app back before going away, unless this is only a reload, which
-- picks the owned apps up again from disk and keeps the stream ages. The
-- service is gone before these finish, so each one is fire-and-forget, and
-- unmute.sh does not need it. owned.json stays: nothing here can tell whether
-- the resets finished, and the next start runs them again if Do Not Disturb
-- is off. They are harmless twice.
function onExit(_signal, reason)
  if reason == "reload" then
    local kept = {}
    for index, since in pairs(firstSeen) do
      kept[tostring(index)] = since
    end
    noctalia.state.set("firstSeen", kept)
    return
  end
  local script = unmuteScript()
  for _, entry in pairs(owned) do
    for index in pairs(entry.streams or {}) do
      noctalia.runAsync({ "pactl", "set-sink-input-mute", tostring(index), "0" })
    end
    for name in pairs(entry.names or {}) do
      local args = quiet.restoreArgs(name)
      if script ~= nil and args ~= nil then
        noctalia.runAsync({ "sh", script, args[1], args[2] })
      end
    end
  end
end

publish()
