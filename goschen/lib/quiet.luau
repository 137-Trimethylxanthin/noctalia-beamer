--!nonstrict
-- Pure decisions for Goschen: no pactl, no noctalia.*, so the tests can run it
-- under plain Lua.
--
-- It works on what `pactl -f json list sink-inputs` / `source-outputs` print:
--
--   stream  { index = 123, mute = false, properties = { ["application.name"] = "vesktop",
--             ["application.process.binary"] = "vesktop", ... } }
--
-- WirePlumber remembers a mute and puts it on the app's next stream. Its key
-- is the stream's application.id if it has one, else its application.name
-- (Output/Audio:application.name:vesktop in its state file), so muting one
-- Vesktop stream also mutes the next one, a voice call included, until
-- something unmutes it. Streams with the "Notification" role (pactl: "event")
-- share one key across every app, Noctalia's own sounds included, so those are
-- never muted. And an app Goschen muted is only let go once its remembered
-- mute has been cleared (`reset`), not when its last stream closes.

local M = {}

M.DEFAULT_APPS = "vesktop, discord, equibop, legcord, webcord, telegram-desktop, telegram, signal-desktop, slack, element-desktop, element"

-- Names an engine gives every app built on it. WirePlumber remembers a mute
-- per name, so muting one stream with such a name would also mute the next
-- browser tab, editor or game that shares it, and Goschen would never know to
-- give that back. Streams whose remembered key is one of these stay alone.
local GENERIC = {
  ["chromium"] = true, ["chromium input"] = true, ["google chrome"] = true, ["electron"] = true,
  ["webrtc voiceengine"] = true, ["openal soft"] = true, ["sdl application"] = true,
  ["firefox"] = true, ["pipewire"] = true, ["pulseaudio"] = true,
}

function M.isGeneric(key)
  if type(key) ~= "string" then
    return false
  end
  key = string.lower(key)
  return GENERIC[key] == true or string.sub(key, 1, 12) == "alsa plug-in"
end

local function lower(value)
  if type(value) ~= "string" or value == "" then
    return nil
  end
  return string.lower(value)
end

-- "Vesktop, discord  telegram-desktop" -> { vesktop = true, discord = true, ... }
function M.parseApps(text)
  local apps = {}
  if type(text) ~= "string" then
    return apps
  end
  for name in string.gmatch(text, "[^,%s]+") do
    apps[string.lower(name)] = true
  end
  return apps
end

-- Which app a stream belongs to, by its process binary first and its app name
-- second, or nil when it is none of `apps`. Official Discord's voice stream is
-- named "WEBRTC VoiceEngine" but runs in the Discord binary, so the binary
-- groups it with the rest of Discord.
function M.appKey(stream, apps)
  local props = type(stream) == "table" and stream.properties or nil
  if type(props) ~= "table" then
    return nil
  end
  local binary = lower(props["application.process.binary"])
  if binary ~= nil and apps[binary] then
    return binary
  end
  local name = lower(props["application.name"])
  if name ~= nil and apps[name] then
    return name
  end
  return nil
end

-- What identifies a stream to WirePlumber's memory, as "name|id":
-- application.name and application.id. unmute.sh opens a stream with the same
-- two, so WirePlumber files it under the same key, whichever of them wins.
-- nil for a stream Goschen must not mute: one keyed by the shared
-- Notification role, or one with neither property (its key would be its
-- media.name, which no helper stream can reproduce).
local SHARED_ROLES = { event = true, notification = true }

local function prop(props, key)
  local value = props[key]
  if type(value) == "string" and value ~= "" and not string.find(value, "[%c|]") and #value <= 160 then
    return value
  end
  return ""
end

function M.restoreName(stream)
  local props = type(stream) == "table" and stream.properties or nil
  if type(props) ~= "table" then
    return nil
  end
  local role = props["media.role"]
  if type(role) == "string" and SHARED_ROLES[string.lower(role)] then
    return nil
  end
  -- An id that is there but cannot be passed on would make the reset clear
  -- the name's key instead of the id's, so such a stream is left alone.
  local rawId = props["application.id"]
  local name, id = prop(props, "application.name"), prop(props, "application.id")
  if (rawId ~= nil and rawId ~= "" and id == "") or (name == "" and id == "") then
    return nil
  end
  -- WirePlumber's key is the id when there is one, else the name.
  local key = name
  if id ~= "" then
    key = id
  end
  if M.isGeneric(key) then
    return nil
  end
  return name .. "|" .. id
end

-- The two fields of a restoreName, for unmute.sh; nil if it is not one.
function M.restoreArgs(key)
  if type(key) ~= "string" or string.find(key, "%c") then
    return nil
  end
  local name, id = string.match(key, "^([^|]*)|([^|]*)$")
  if name == nil or (name == "" and id == "") then
    return nil
  end
  return { name, id }
end

-- A recording stream that is someone capturing a monitor (a screen share's
-- audio, a visualizer), not a microphone.
local function isMonitorCapture(stream)
  local props = stream.properties or {}
  return props["stream.capture.sink"] == "true" or props["stream.monitor"] == "true"
end

local function copyOwned(input)
  local owned = {}
  for key, entry in pairs(input or {}) do
    if type(entry) == "table" then
      local copy = { names = {}, streams = {}, seen = {}, returning = entry.returning == true }
      for name in pairs(entry.names or {}) do
        copy.names[name] = true
      end
      for index in pairs(entry.streams or {}) do
        copy.streams[tostring(index)] = true
      end
      for index in pairs(entry.seen or {}) do
        copy.seen[tostring(index)] = true
      end
      owned[key] = copy
    end
  end
  return owned
end

local function sortedKeys(t)
  local keys = {}
  for key in pairs(t) do
    table.insert(keys, key)
  end
  table.sort(keys)
  return keys
end

-- One look at the streams, and what to do about them.
--
--   input  { dnd, apps, sinks, sources, owned, now, firstSeen, respectCalls, busyAfterMs }
--          `owned`      { [key] = { names, streams, seen, returning } }: apps Goschen
--                       muted and has not given back yet; kept on disk.
--                       `names`   the restoreNames it muted under
--                       `streams` the stream indices that are its doing (as strings)
--                       `seen`    every stream of the app it has looked at
--                       `returning` given back, waiting for the resets to finish
--          `firstSeen`  { [sink index] = ms } for the age rule; a stream without an
--                       entry counts as new.
--   output { mute = { index… }, unmute = { index… }, reset = { restoreName… },
--            owned = new owned table, quiet = { key… }, busy = { key… } }
--
-- While Do Not Disturb is on, every stream of a listed app is muted unless
-- the app is busy: recording (in a call), or, with the age rule on, playing a
-- stream for longer than `busyAfterMs`. A busy app gets back the streams
-- Goschen muted. When Do Not Disturb ends, or an app leaves the list, those
-- streams are unmuted and every name it muted under is reset. A stream is
-- Goschen's doing only if it muted it, or if it arrived muted under a name
-- Goschen had muted; a mute of the user's own is never undone.
--
-- `reset` names stay in `owned` until the service drops them one by one as
-- their reset succeeds, so a failed one is tried again on the next look.
function M.plan(input)
  local apps = input.apps or {}
  local owned = copyOwned(input.owned)

  -- An owned app still has to be recognized after it left the list, so it
  -- can be given back.
  local known = {}
  for key in pairs(apps) do
    known[key] = true
  end
  for key in pairs(owned) do
    known[key] = true
  end

  local groups = {}
  for _, stream in ipairs(input.sinks or {}) do
    local key = M.appKey(stream, known)
    if key ~= nil and type(stream.index) == "number" then
      groups[key] = groups[key] or {}
      table.insert(groups[key], stream)
    end
  end

  local recording = {}
  for _, stream in ipairs(input.sources or {}) do
    local key = M.appKey(stream, known)
    if key ~= nil and not isMonitorCapture(stream) then
      recording[key] = true
    end
  end

  local now = input.now or 0
  local firstSeen = input.firstSeen or {}
  local busyAfter = input.busyAfterMs or 0

  -- Old enough that WirePlumber has had its chance to put a remembered mute
  -- on it; a stream of unknown age is taken as settled.
  local function settled(stream)
    local since = firstSeen[stream.index]
    return since == nil or now - since >= (input.settleMs or 2000)
  end

  local function busy(key)
    if input.respectCalls ~= false and recording[key] then
      return true
    end
    if busyAfter > 0 then
      for _, stream in ipairs(groups[key] or {}) do
        local since = firstSeen[stream.index]
        if not stream.corked and since ~= nil and now - since >= busyAfter then
          return true
        end
      end
    end
    return false
  end

  local out = { mute = {}, unmute = {}, reset = {}, owned = owned, quiet = {}, busy = {} }

  local keys = {}
  for key in pairs(groups) do
    keys[key] = true
  end
  for key in pairs(owned) do
    keys[key] = true
  end

  for _, key in ipairs(sortedKeys(keys)) do
    local group = groups[key] or {}
    local entry = owned[key]
    local live = {}

    -- A stream Goschen has not looked at before that arrives muted under a
    -- name it muted is PipeWire replaying Goschen's mute: its doing too.
    -- WirePlumber replays the mute a moment after the stream appears, so one
    -- that is still new and unmuted is not settled yet: the next look sees
    -- it again.
    if entry ~= nil then
      for _, stream in ipairs(group) do
        local index = tostring(stream.index)
        live[index] = true
        if not entry.seen[index] then
          local name = M.restoreName(stream)
          if stream.mute and name ~= nil and entry.names[name] then
            entry.streams[index] = true
            entry.seen[index] = true
          elseif stream.mute or settled(stream) then
            entry.seen[index] = true
          end
        end
      end
      for index in pairs(entry.streams) do
        if not live[index] then
          entry.streams[index] = nil
        end
      end
      for index in pairs(entry.seen) do
        if not live[index] then
          entry.seen[index] = nil
        end
      end
    end

    local listed = apps[key] == true
    if input.dnd and listed and not busy(key) then
      table.insert(out.quiet, key)
      for _, stream in ipairs(group) do
        local name = M.restoreName(stream)
        local index = tostring(stream.index)
        if name ~= nil and not stream.mute then
          table.insert(out.mute, stream.index)
          entry = entry or { names = {}, streams = {}, seen = {}, returning = false }
          owned[key] = entry
          entry.names[name] = true
          entry.streams[index] = true
          entry.seen[index] = true
        end
      end
      if entry ~= nil then
        entry.returning = false
        -- Everything in the group has been looked at now, a mute of the
        -- user's own that came before the first stream Goschen muted too.
        for _, stream in ipairs(group) do
          entry.seen[tostring(stream.index)] = true
        end
      end
    elseif entry ~= nil then
      for _, stream in ipairs(group) do
        local index = tostring(stream.index)
        if entry.streams[index] then
          if stream.mute then
            table.insert(out.unmute, stream.index)
          end
          entry.streams[index] = nil
        end
      end
      if input.dnd and listed then
        -- Busy: the call keeps its sound, and Goschen keeps the app so it can
        -- mute it again once the call is over.
        table.insert(out.busy, key)
      else
        entry.returning = true
        for _, name in ipairs(sortedKeys(entry.names)) do
          table.insert(out.reset, name)
        end
        if next(entry.names) == nil and next(entry.streams) == nil then
          owned[key] = nil
        end
      end
    end
  end

  return out
end

-- Sink input indices out of a `pactl subscribe` line:
--   Event 'new' on sink-input #412   ->  "new", "sink-input", 412
function M.parseEvent(line)
  if type(line) ~= "string" then
    return nil
  end
  local kind, facility, index = string.match(line, "^Event '(%a+)' on ([%a%-]+) #(%d+)")
  if kind == nil then
    return nil
  end
  return kind, facility, tonumber(index)
end

return M
