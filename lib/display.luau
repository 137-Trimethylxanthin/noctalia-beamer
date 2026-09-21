--!nonstrict
-- Shared monitor handling for every Beamer entry.
--
-- Everything here goes through `hyprctl`. Two things about Hyprland make this
-- less direct than it looks:
--
--  * Mirroring is not a command, only a monitor rule -- there is no
--    "duplicate my screen" dispatcher to call.
--  * Hyprland can be configured with hyprlang (the usual hyprland.conf) or
--    with the newer Lua parser. `hyprctl keyword` is refused on the Lua one
--    ("keyword can't work with non-legacy parsers. Use eval."), so rules are
--    retried through `hyprctl eval` and hl.monitor{}. The parser is probed
--    once on the first switch and remembered for the session.

local M = {}

-- Built-in panels. Everything else counts as an external screen.
local INTERNAL_PREFIXES = { "eDP", "LVDS", "DSI" }

-- Output names come back from hyprctl as JSON. They only ever reach a shell
-- command after passing this, so a surprising name cannot turn into one.
local SAFE_NAME = "^[%w%-%._]+$"

M.MODES = { "extend", "mirror", "external", "internal" }

-- nil until the first rule is applied, then true for `eval`, false for
-- `keyword`. Only the probe writes it.
local useEval = nil

local function isInternal(name)
  for _, prefix in ipairs(INTERNAL_PREFIXES) do
    if string.sub(name, 1, #prefix) == prefix then
      return true
    end
  end
  return false
end

-- Splits `hyprctl monitors all -j` into the built-in panel and the rest.
-- "all" matters: a screen that is plugged in but currently disabled has to
-- count as attached, or turning it back on is unreachable.
local function classify(monitors)
  local info = { internal = nil, external = {}, mode = "internal" }
  for _, monitor in ipairs(monitors) do
    if type(monitor.name) == "string" and string.match(monitor.name, SAFE_NAME) then
      if info.internal == nil and isInternal(monitor.name) then
        info.internal = monitor
      else
        table.insert(info.external, monitor)
      end
    end
  end

  -- No eDP/LVDS/DSI at all (a desktop): treat the first output as the one
  -- that must never be switched off.
  if info.internal == nil and #info.external > 0 then
    info.internal = table.remove(info.external, 1)
  end

  local internalOn = info.internal ~= nil and info.internal.disabled ~= true
  local externalOn, mirroring = 0, 0
  for _, monitor in ipairs(info.external) do
    if monitor.disabled ~= true then
      externalOn += 1
    end
    if monitor.mirrorOf ~= nil and monitor.mirrorOf ~= "none" then
      mirroring += 1
    end
  end

  if externalOn == 0 then
    info.mode = "internal"
  elseif not internalOn then
    info.mode = "external"
  elseif mirroring > 0 then
    info.mode = "mirror"
  else
    info.mode = "extend"
  end

  return info
end

-- Remembers how the built-in panel was running while it was on, so switching
-- back does not silently reset it -- a 2560x1600 panel handed "scale 1"
-- becomes unreadable. Every switch re-reads the monitors first, so this is
-- refreshed right before it is needed; "preferred"/"auto" is the fallback if
-- the panel has not been seen running yet.
local function rememberInternal(info)
  local internal = info.internal
  if internal == nil or internal.disabled == true then
    return
  end
  local mode = "preferred"
  if internal.width and internal.height and internal.refreshRate then
    mode = string.format("%dx%d@%.5f", internal.width, internal.height, internal.refreshRate)
  end
  noctalia.state.set("internal_mode", mode)
  noctalia.state.set("internal_scale", tostring(internal.scale or "auto"))
end

local function internalRule(info)
  return {
    output = info.internal.name,
    mode = noctalia.state.get("internal_mode") or "preferred",
    scale = noctalia.state.get("internal_scale") or "auto",
  }
end

-- One rule in hyprlang's `monitor=` syntax.
local function keywordRule(rule)
  if rule.disabled then
    return string.format("hyprctl keyword monitor '%s,disable'", rule.output)
  end
  local parts = string.format("%s,%s,auto,%s", rule.output, rule.mode, rule.scale)
  if rule.mirror ~= nil then
    parts ..= ",mirror," .. rule.mirror
  end
  return string.format("hyprctl keyword monitor '%s'", parts)
end

-- The same rule for the Lua parser. An empty `mirror` is what clears an
-- existing mirror; leaving the field out would keep it.
local function evalRule(rule)
  if rule.disabled then
    return string.format("hl.monitor({output='%s', disabled=true})", rule.output)
  end
  return string.format(
    "hl.monitor({output='%s', mode='%s', position='auto', scale='%s', mirror='%s', disabled=false})",
    rule.output, rule.mode, rule.scale, rule.mirror or ""
  )
end

-- Chained with && on purpose. Rules are ordered so that a screen is switched
-- on before another is switched off, and hyprctl exits non-zero on a rule it
-- rejects -- so if enabling the external screen fails, the command that would
-- have turned the built-in one off never runs.
local function joinKeyword(rules)
  local parts = {}
  for _, rule in ipairs(rules) do
    table.insert(parts, keywordRule(rule))
  end
  return table.concat(parts, " && ")
end

local function joinEval(rules)
  local parts = {}
  for _, rule in ipairs(rules) do
    table.insert(parts, evalRule(rule))
  end
  return string.format("hyprctl eval %q", table.concat(parts, " "))
end

-- Rules are applied in order, so the built-in panel is always switched on
-- before anything asks for it to be switched off.
local function rulesFor(mode, info)
  local rules = {}
  if mode == "mirror" then
    table.insert(rules, internalRule(info))
    for _, monitor in ipairs(info.external) do
      table.insert(rules, {
        output = monitor.name,
        mode = "preferred",
        -- Scale 1 keeps the projector at its native resolution; "auto" can
        -- pick 2 on a 1080p beamer and upscale a 960x540 render.
        scale = "1",
        mirror = info.internal.name,
      })
    end
  elseif mode == "external" then
    for _, monitor in ipairs(info.external) do
      table.insert(rules, { output = monitor.name, mode = "preferred", scale = "auto" })
    end
    table.insert(rules, { output = info.internal.name, disabled = true })
  elseif mode == "internal" then
    table.insert(rules, internalRule(info))
    for _, monitor in ipairs(info.external) do
      table.insert(rules, { output = monitor.name, disabled = true })
    end
  end
  return rules
end

local function run(command, done)
  local accepted = noctalia.runAsync(command, function(result)
    done(result.exitCode == 0, (result.stdout or "") .. (result.stderr or ""))
  end)
  if not accepted then
    done(false, "could not start hyprctl")
  end
end

local function applyRules(rules, done)
  if useEval == true then
    return run(joinEval(rules), done)
  end

  run(joinKeyword(rules), function(ok, output)
    -- The Lua parser answers every keyword with this refusal instead of
    -- applying it, so the first switch doubles as the probe: nothing was
    -- changed, and re-running the same rules through eval is safe.
    if string.find(output, "non%-legacy") then
      useEval = true
      return run(joinEval(rules), done)
    end
    if useEval == nil then
      useEval = false
    end
    done(ok, output)
  end)
end

function M.read(done)
  if not noctalia.commandExists("hyprctl") then
    return done(nil)
  end
  noctalia.runAsync("hyprctl monitors all -j", function(result)
    if result.exitCode ~= 0 then
      noctalia.log("beamer: hyprctl monitors failed: " .. noctalia.string.trim(result.stderr or ""))
      return done(nil)
    end
    local monitors = noctalia.json.decode(result.stdout)
    if type(monitors) ~= "table" then
      return done(nil)
    end
    local info = classify(monitors)
    rememberInternal(info)
    done(info)
  end)
end

function M.nextMode(current)
  for index, mode in ipairs(M.MODES) do
    if mode == current then
      return M.MODES[(index % #M.MODES) + 1]
    end
  end
  return "extend"
end

-- `done(ok, reason)`. reason is "no-external" when the mode was refused
-- because there is nothing plugged in, so callers can say so in their own
-- words rather than failing silently.
function M.apply(mode, done)
  M.read(function(info)
    if info == nil or info.internal == nil then
      return done(false, "no-hyprland")
    end
    if mode ~= "internal" and #info.external == 0 then
      return done(false, "no-external")
    end

    -- Extend is the layout the user's own config already describes, so the
    -- honest way back to it is to re-apply that config rather than to guess
    -- positions and scales for screens this plugin has never seen.
    if mode == "extend" then
      return run("hyprctl reload", done)
    end

    applyRules(rulesFor(mode, info), done)
  end)
end

return M
