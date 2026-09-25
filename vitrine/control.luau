--!nonstrict
-- [[service]]: owns the monitors. It reads them every few seconds and after
-- every switch, publishes what it found on noctalia.state ("status") for the
-- launcher and the tile, and is the only entry that changes anything: the
-- launcher and the tile ask through noctalia.state ("request"), a keybind
-- through IPC.
--
--   noctalia msg plugin 137-trimethylxanthin/vitrine:control all cycle
--   noctalia msg plugin 137-trimethylxanthin/vitrine:control all set mirror
--
-- Two backends: Hyprland through hyprctl (the only one with real mirroring),
-- and the standard wlr-output-management protocol for every other
-- compositor (lib/outputs.py, through uv).

local core = require("./lib/core.luau")
local hyprland = require("./lib/hyprland.luau")
local wlr = require("./lib/wlr.luau")

local backend = nil
if hyprland.available() then
  backend = hyprland
elseif wlr.available() then
  backend = wlr
end

-- ── Memory ───────────────────────────────────────────────────────────────────
--
-- How the built-in panel ran while it was on (mode, scale, rotation,
-- position), and the last extended layout. On disk, so a restart while the
-- panel is off still brings it back as it was.

local memory = { internal = nil, extend = nil }
local memorySaved = nil

local function memoryPath()
  local dir = noctalia.pluginDataDir()
  return dir and (dir .. "/memory.json") or nil
end

do
  local path = memoryPath()
  local raw = path and noctalia.fileExists(path) and noctalia.readFile(path)
  local value = raw and noctalia.json.decode(raw)
  -- A file edited by hand, or cut short, must not break a switch later:
  -- only whole records are kept.
  if type(value) == "table" then
    memory.internal = core.validRecord(value.internal) and value.internal or nil
    if type(value.extend) == "table" and type(value.extend.outputs) == "table" then
      local outputs = {}
      for _, rec in ipairs(value.extend.outputs) do
        if core.validRecord(rec) then
          table.insert(outputs, rec)
        end
      end
      memory.extend = if #outputs >= 2 then { outputs = outputs } else nil
    end
  end
end

local function remember(info)
  local rec = core.record(info.internal)
  if rec then
    memory.internal = rec
  end
  local snap = core.snapshot(info)
  if snap and #snap.outputs >= 2 then
    memory.extend = snap
  end
  local path = memoryPath()
  local text = noctalia.json.encode(memory)
  if path and text and text ~= memorySaved then
    memorySaved = text
    noctalia.writeFile(path, text)
  end
end

-- ── Reading ──────────────────────────────────────────────────────────────────

-- The lid, from ACPI where there is one. Many newer laptops (s2idle only,
-- ARM) have no /proc/acpi/button/lid; there logind's LidClosed says it,
-- asked on every look and used from the last answer.
local logindLid = nil
local askingLogind = false

local function askLogind()
  if askingLogind or not noctalia.commandExists("busctl") then
    return
  end
  askingLogind = true
  local accepted = noctalia.runAsync({
    "busctl", "get-property", "org.freedesktop.login1", "/org/freedesktop/login1",
    "org.freedesktop.login1.Manager", "LidClosed",
  }, function(result)
    askingLogind = false
    logindLid = core.parseLogindLid(result.exitCode == 0 and result.stdout or nil)
  end)
  if not accepted then
    askingLogind = false
  end
end

local function lidClosed(info)
  -- Without a built-in panel there is no lid to ask about.
  if info == nil or info.internal == nil or not core.isInternal(info.internal.name) then
    return false
  end
  local dirs = noctalia.listDir("/proc/acpi/button/lid")
  if dirs ~= nil and #dirs > 0 then
    for _, name in ipairs(dirs) do
      local text = noctalia.readFile("/proc/acpi/button/lid/" .. name .. "/state")
      if core.parseLid(text) == "closed" then
        return true
      end
    end
    return false
  end
  askLogind()
  return logindLid == true
end

local last = nil -- the last info read

local function caps(info)
  return {
    mirror = backend ~= nil and backend.caps.mirror == true,
    lidClosed = lidClosed(info),
    external = info and #info.external or 0,
  }
end

local function publish(info, reason)
  local c = caps(info)
  local allowed = {}
  for _, mode in ipairs(core.MODES) do
    local ok, why = core.allowed(mode, c)
    allowed[mode] = if ok then true else why
  end
  noctalia.state.set("status", {
    available = info ~= nil,
    reason = reason,
    backend = backend and backend.name or nil,
    mode = info and info.mode or nil,
    external = c.external,
    allowed = allowed,
    lidClosed = c.lidClosed,
  })
end

local reading = false
local readWaiters = {}

local function read(done)
  if done then
    table.insert(readWaiters, done)
  end
  if reading then
    return
  end
  if backend == nil then
    local waiting = readWaiters
    readWaiters = {}
    publish(nil, "no-backend")
    for _, fn in ipairs(waiting) do
      fn(nil)
    end
    return
  end
  reading = true
  backend.list(function(heads)
    reading = false
    local info = heads and core.classify(heads) or nil
    if info and info.internal == nil then
      info = nil
    end
    if info then
      last = info
      remember(info)
    end
    publish(info, if info then nil else (backend.unsupported and "unsupported" or "no-answer"))
    local waiting = readWaiters
    readWaiters = {}
    for _, fn in ipairs(waiting) do
      fn(info)
    end
  end)
end

-- ── Switching ────────────────────────────────────────────────────────────────

local switching = false
local switchingSince = 0
-- A switch that never reports back (a helper that hung) must not lock the
-- display key for good.
local SWITCH_TIMEOUT_MS = 30000

local function announce(mode, ok, reason)
  if ok then
    return noctalia.notify(noctalia.tr("title"), noctalia.tr("mode." .. mode .. ".title"))
  end
  if reason == "no-external" then
    noctalia.notify(noctalia.tr("title"), noctalia.tr("nothing-attached"))
  elseif reason == "lid-closed" then
    noctalia.notify(noctalia.tr("title"), noctalia.tr("lid-closed"))
  elseif reason == "no-mirror" then
    noctalia.notify(noctalia.tr("title"), noctalia.tr("no-mirror"))
  elseif reason == "not-up" then
    noctalia.notifyError(noctalia.tr("title"), noctalia.tr("not-up"))
  elseif reason == "no-backend" then
    noctalia.notifyError(noctalia.tr("title"), noctalia.tr("unavailable.subtitle"))
  else
    noctalia.notifyError(noctalia.tr("title"), noctalia.tr("failed"))
  end
end

-- Whether any name in `names` is on, by a fresh look. A screen can take a
-- moment to come up after the compositor accepted the change (a modeset, a
-- config reload), so it looks again every quarter second for up to three.
local CHECK_TRIES = 12

local function checkUp(names, done, tries)
  tries = tries or 1
  read(function(info)
    if info ~= nil then
      local on = {}
      for _, head in ipairs({ info.internal, table.unpack(info.external) }) do
        if head.enabled then
          on[head.name] = true
        end
      end
      -- One screen up is enough to switch another off; they need not all be.
      for _, name in ipairs(names) do
        if on[name] then
          return done(true)
        end
      end
    end
    if tries >= CHECK_TRIES then
      return done(false)
    end
    local accepted = noctalia.runAsync({ "sleep", "0.25" }, function()
      checkUp(names, done, tries + 1)
    end)
    if not accepted then
      done(false)
    end
  end)
end

local function runSteps(steps, done)
  local i = 0
  local function nextStep()
    i += 1
    local step = steps[i]
    if step == nil then
      return done(true)
    end
    local function go()
      local configs = {}
      for _, cfg in ipairs(step) do
        table.insert(configs, cfg)
      end
      if #configs == 0 then
        return nextStep()
      end
      backend.apply(configs, function(ok, output)
        if not ok then
          noctalia.log("vitrine: switch refused: " .. noctalia.string.trim(output or ""))
          return done(false, "failed")
        end
        nextStep()
      end)
    end
    if step.requires then
      checkUp(step.requires, function(up)
        if not up then
          return done(false, "not-up")
        end
        go()
      end)
    else
      go()
    end
  end
  nextStep()
end

local function switch(mode)
  if switching then
    return
  end
  if backend == nil then
    return announce(mode, false, "no-backend")
  end
  switching = true
  switchingSince = noctalia.nowMs()
  read(function(info)
    if info == nil then
      switching = false
      return announce(mode, false, "failed")
    end
    local planned, steps, reason = pcall(core.plan, mode, info, memory, caps(info))
    if not planned then
      switching = false
      noctalia.log("vitrine: could not plan " .. mode .. ": " .. tostring(steps))
      return announce(mode, false, "failed")
    end
    if steps == nil then
      switching = false
      return announce(mode, false, reason)
    end
    -- Extend with nothing remembered, on Hyprland: the user's own config
    -- describes it, so re-apply that rather than guess.
    local mine = switchingSince
    local function finish(ok, why)
      if switchingSince ~= mine then
        return -- timed out long ago; a newer switch owns the state
      end
      switching = false
      announce(mode, ok, why)
      read()
    end
    if steps.fallback and backend.restoreConfig then
      return backend.restoreConfig(function(ok)
        finish(ok, if ok then nil else "failed")
      end)
    end
    runSteps(steps, finish)
  end)
end

local function cycle()
  read(function(info)
    if info == nil then
      return announce("extend", false, "no-backend")
    end
    if #info.external == 0 then
      return announce("extend", false, "no-external")
    end
    switch(core.nextMode(info.mode, caps(info)))
  end)
end

local function handle(request)
  if type(request) ~= "table" then
    return
  end
  if request.op == "cycle" then
    cycle()
  elseif request.op == "set" and type(request.mode) == "string" then
    for _, mode in ipairs(core.MODES) do
      if mode == request.mode then
        return switch(mode)
      end
    end
  elseif request.op == "refresh" then
    read()
  end
end

noctalia.state.watch("request", handle)

function onIpc(event, payload)
  if event == "cycle" then
    cycle()
  elseif event == "set" and type(payload) == "string" then
    for _, mode in ipairs(core.MODES) do
      if mode == payload then
        return switch(mode)
      end
    end
    noctalia.log("vitrine: unknown mode '" .. payload .. "'")
  end
end

-- Hotplug, a lid, a layout changed by hand: a slow look keeps the launcher
-- and the tile right. Cheap on Hyprland; on the wlr backend one short-lived
-- helper process per look.
noctalia.setUpdateInterval(if backend == hyprland then 3000 else 6000)
function update()
  if switching and noctalia.nowMs() - switchingSince > SWITCH_TIMEOUT_MS then
    noctalia.log("vitrine: a switch never finished; giving up on it")
    switching = false
    switchingSince = 0
  end
  if not switching then
    read()
  end
end

if backend == nil then
  noctalia.log("vitrine: neither Hyprland nor uv for wlr-output-management; staying idle")
end
read()
