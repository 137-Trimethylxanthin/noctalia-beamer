local quiet = require("lib.quiet")

local fails = 0
local function check(name, cond, extra)
  if cond then print("  ok   " .. name)
  else fails = fails + 1; print("  FAIL " .. name .. (extra and ("  -> " .. tostring(extra)) or "")) end
end

local function stream(index, binary, name, mute, extra)
  local props = { ["application.process.binary"] = binary, ["application.name"] = name }
  for k, v in pairs(extra or {}) do props[k] = v end
  return { index = index, mute = mute == true, properties = props }
end

local function has(list, value)
  for _, v in ipairs(list) do
    if v == value then return true end
  end
  return false
end

local function list(t)
  local out = {}
  for _, v in ipairs(t) do out[#out + 1] = tostring(v) end
  return table.concat(out, ",")
end

-- what the service does when a reset succeeds
local function dropName(owned, name)
  for key, entry in pairs(owned) do
    if entry.returning and entry.names[name] then
      entry.names[name] = nil
      if next(entry.names) == nil and next(entry.streams) == nil then owned[key] = nil end
    end
  end
end

local apps = quiet.parseApps("Vesktop, discord  telegram-desktop,,")
local V = "vesktop|"

print("== apps ==")
check("lowercased, commas and spaces", apps.vesktop and apps.discord and apps["telegram-desktop"])
check("defaults parse", quiet.parseApps(quiet.DEFAULT_APPS).vesktop)
check("binary first", quiet.appKey(stream(1, "Discord", "WEBRTC VoiceEngine"), apps) == "discord")
check("name second", quiet.appKey(stream(1, "pacat", "vesktop"), apps) == "vesktop")
check("unlisted", quiet.appKey(stream(1, "spotify", "Spotify"), apps) == nil)
check("no properties", quiet.appKey({ index = 1 }, apps) == nil)

print("== identity ==")
check("name", quiet.restoreName(stream(1, "vesktop", "vesktop")) == V)
check("name and id", quiet.restoreName(stream(1, "x", "Telegram", false, { ["application.id"] = "org.telegram.desktop" }))
  == "Telegram|org.telegram.desktop")
check("shared event role: never", quiet.restoreName(stream(1, "x", "Telegram", false, { ["media.role"] = "event" })) == nil)
check("shared Notification role: never", quiet.restoreName(stream(1, "x", "T", false, { ["media.role"] = "Notification" })) == nil)
check("other roles are fine", quiet.restoreName(stream(1, "x", "T", false, { ["media.role"] = "music" })) == "T|")
check("media name alone: never", quiet.restoreName({ properties = { ["media.name"] = "ping" } }) == nil)
check("separator in a value dropped", quiet.restoreName({ properties = { ["application.name"] = "a|b" } }) == nil)
local args = quiet.restoreArgs("Telegram|org.telegram.desktop")
check("args split", args and args[1] == "Telegram" and args[2] == "org.telegram.desktop")
check("args refused", quiet.restoreArgs("|") == nil and quiet.restoreArgs("vesktop") == nil and quiet.restoreArgs("a\n|") == nil)

print("== events ==")
local kind, facility, index = quiet.parseEvent("Event 'new' on sink-input #412")
check("new sink input", kind == "new" and facility == "sink-input" and index == 412)
kind, facility = quiet.parseEvent("Event 'remove' on source-output #7")
check("removed source output", kind == "remove" and facility == "source-output")
check("other lines", quiet.parseEvent("Event 'change' on client") == nil and quiet.parseEvent(nil) == nil)

print("== do not disturb on ==")
local sinks = { stream(10, "vesktop", "vesktop"), stream(11, "spotify", "Spotify"), stream(12, "vesktop", "vesktop") }
local p = quiet.plan({ dnd = true, apps = apps, sinks = sinks, sources = {}, owned = {} })
check("vesktop streams muted", has(p.mute, 10) and has(p.mute, 12), list(p.mute))
check("music untouched", not has(p.mute, 11) and #p.unmute == 0)
local e = p.owned.vesktop
check("owned by name, both streams its doing", e and e.names[V] and e.streams["10"] and e.streams["12"])
check("reported quiet", has(p.quiet, "vesktop"))

p = quiet.plan({ dnd = true, apps = apps, sinks = { stream(10, "vesktop", "vesktop", true) }, sources = {}, owned = {} })
check("already muted by the user: not claimed", p.owned.vesktop == nil and #p.mute == 0)

p = quiet.plan({ dnd = true, apps = apps, sinks = { stream(13, "x", "Telegram", false, { ["media.role"] = "event" }) },
  sources = {}, owned = {} })
check("a shared-role stream is left alone", #p.mute == 0 and p.owned.telegram == nil)

local owned = p.owned
owned = quiet.plan({ dnd = true, apps = apps, sinks = sinks, sources = {}, owned = {} }).owned
p = quiet.plan({ dnd = true, apps = apps, sinks = { stream(10, "vesktop", "vesktop", true), stream(20, "vesktop", "vesktop", true) },
  sources = {}, owned = owned })
check("a new stream arriving muted is Goschen's doing", p.owned.vesktop.streams["20"])
check("nothing muted twice", #p.mute == 0 and #p.unmute == 0)
check("gone stream forgotten", p.owned.vesktop.streams["12"] == nil)
check("input owned not changed", owned.vesktop.streams["12"] and p.owned ~= owned)

print("== calls ==")
owned = p.owned
local mic = { stream(5, "vesktop", "vesktop") }
-- 30: arrived muted (remembered mute) when the call started; 10: muted by Goschen; 40: muted by the user mid-call
local callSinks = { stream(10, "vesktop", "vesktop", true), stream(20, "vesktop", "vesktop", true), stream(30, "vesktop", "vesktop", true) }
p = quiet.plan({ dnd = true, apps = apps, sinks = callSinks, sources = mic, owned = owned })
check("in a call: its streams given back", has(p.unmute, 10) and has(p.unmute, 20) and has(p.unmute, 30), list(p.unmute))
check("still owned, nothing reset", p.owned.vesktop and #p.reset == 0 and not p.owned.vesktop.returning)
check("reported busy", has(p.busy, "vesktop"))
local during = p.owned
local playing = { stream(10, "vesktop", "vesktop"), stream(20, "vesktop", "vesktop"), stream(30, "vesktop", "vesktop"),
  stream(40, "vesktop", "vesktop") }
during = quiet.plan({ dnd = true, apps = apps, sources = mic, owned = during, sinks = playing }).owned
p = quiet.plan({ dnd = true, apps = apps, sources = mic, owned = during,
  sinks = { stream(10, "vesktop", "vesktop"), stream(20, "vesktop", "vesktop"), stream(30, "vesktop", "vesktop"),
    stream(40, "vesktop", "vesktop", true) } })
check("the user's own mute during the call is left alone", not has(p.unmute, 40), list(p.unmute))
p = quiet.plan({ dnd = true, apps = apps, sinks = { stream(30, "vesktop", "vesktop") }, sources = mic, owned = {} })
check("in a call, not owned: left alone", #p.mute == 0 and #p.unmute == 0 and p.owned.vesktop == nil)
p = quiet.plan({ dnd = true, apps = apps, sinks = { stream(30, "vesktop", "vesktop") }, sources = mic, owned = {}, respectCalls = false })
check("calls not respected: muted anyway", has(p.mute, 30))
p = quiet.plan({ dnd = true, apps = apps, sinks = { stream(31, "Discord", "WEBRTC VoiceEngine") },
  sources = { stream(6, "Discord", "WEBRTC VoiceEngine") }, owned = {} })
check("official Discord call by binary", #p.mute == 0)
p = quiet.plan({ dnd = true, apps = apps, sinks = { stream(32, "vesktop", "vesktop") },
  sources = { stream(7, "vesktop", "vesktop", false, { ["stream.capture.sink"] = "true" }) }, owned = {} })
check("capturing a monitor is not a call", has(p.mute, 32))

print("== long playback ==")
local seen = { [40] = 0, [41] = 50000, [43] = 0 }
local two = { stream(40, "telegram-desktop", "Telegram"), stream(41, "vesktop", "vesktop") }
p = quiet.plan({ dnd = true, apps = apps, sinks = two, sources = {}, owned = {}, now = 60000, firstSeen = seen, busyAfterMs = 30000 })
check("playing a minute: left alone", not has(p.mute, 40))
check("a fresh ping: muted", has(p.mute, 41))
local corked = { index = 43, mute = false, corked = true, properties = { ["application.process.binary"] = "vesktop", ["application.name"] = "vesktop" } }
p = quiet.plan({ dnd = true, apps = apps, sinks = { corked }, sources = {}, owned = {}, now = 60000, firstSeen = seen, busyAfterMs = 30000 })
check("an old but paused stream is not long playback", has(p.mute, 43))
p = quiet.plan({ dnd = true, apps = apps, sinks = two, sources = {}, owned = {}, now = 60000, firstSeen = seen, busyAfterMs = 0 })
check("rule off: both muted", has(p.mute, 40) and has(p.mute, 41))
p = quiet.plan({ dnd = true, apps = apps, sinks = { stream(42, "vesktop", "vesktop") }, sources = {}, owned = {}, now = 60000, firstSeen = {}, busyAfterMs = 30000 })
check("unknown age counts as new", has(p.mute, 42))

print("== do not disturb off ==")
owned = quiet.plan({ dnd = true, apps = apps, owned = {}, sources = {},
  sinks = { stream(50, "vesktop", "vesktop"), stream(52, "telegram-desktop", "Telegram", false, { ["application.id"] = "org.telegram.desktop" }) } }).owned
local offSinks = { stream(50, "vesktop", "vesktop", true), stream(51, "spotify", "Spotify", true), stream(53, "vesktop", "vesktop", true) }
p = quiet.plan({ dnd = false, apps = apps, sinks = offSinks, sources = {}, owned = owned })
check("Goschen's stream unmuted", has(p.unmute, 50))
check("someone else's mute left alone", not has(p.unmute, 51))
check("a new stream that arrived muted under its name is unmuted too", has(p.unmute, 53))
check("remembered mutes reset, with or without a stream", has(p.reset, V) and has(p.reset, "Telegram|org.telegram.desktop"), list(p.reset))
check("kept until the resets succeed", p.owned.vesktop and p.owned.vesktop.returning and p.owned["telegram-desktop"])
local after = p.owned
dropName(after, V)
p = quiet.plan({ dnd = false, apps = apps, sinks = {}, sources = {}, owned = after })
check("a reset that worked lets the app go", p.owned.vesktop == nil)
check("a failed one is asked for again", has(p.reset, "Telegram|org.telegram.desktop") and p.owned["telegram-desktop"])
p = quiet.plan({ dnd = false, apps = apps, sinks = { stream(54, "vesktop", "vesktop", true) }, sources = {}, owned = {} })
check("never muted by Goschen: untouched", #p.unmute == 0 and #p.reset == 0)

print("== back on before the reset finished ==")
p = quiet.plan({ dnd = true, apps = apps, sinks = { stream(60, "telegram-desktop", "Telegram", false, { ["application.id"] = "org.telegram.desktop" }) },
  sources = {}, owned = after })
check("owned again, not returning", p.owned["telegram-desktop"] and not p.owned["telegram-desktop"].returning and has(p.mute, 60))

print("== an app leaves the list ==")
owned = quiet.plan({ dnd = true, apps = apps, sinks = { stream(70, "vesktop", "vesktop") }, sources = {}, owned = {} }).owned
p = quiet.plan({ dnd = true, apps = quiet.parseApps("discord"), sinks = { stream(70, "vesktop", "vesktop", true) }, sources = {}, owned = owned })
check("given back during Do Not Disturb", has(p.unmute, 70) and has(p.reset, V) and p.owned.vesktop.returning)
p = quiet.plan({ dnd = true, apps = apps, sinks = {}, sources = {}, owned = owned })
check("still listed, no stream: kept for later", p.owned.vesktop and #p.reset == 0)

print()
if fails > 0 then print(fails .. " failed"); os.exit(1) end
print("all passed")
