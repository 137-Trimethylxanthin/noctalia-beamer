--!nonstrict
-- Hyprland, through hyprctl. The one backend with real mirroring: every
-- other compositor has no "show the same picture" for outputs.
--
-- Hyprland can be configured with hyprlang (hyprland.conf) or with the Lua
-- parser. `hyprctl keyword` is refused on the Lua one, so rules go through
-- `hyprctl eval` and hl.monitor{} there. Which one is running is asked once
-- (`hyprctl eval 'return 1'` answers "ok" on Lua) and remembered for the
-- session; an answer that says neither is asked again next time.

local core = require("./core.luau")

local M = { name = "hyprland", caps = { mirror = true } }

function M.available()
  return noctalia.getenv("HYPRLAND_INSTANCE_SIGNATURE") ~= nil and noctalia.commandExists("hyprctl")
end

local function parseModes(list)
  local modes = {}
  for _, text in ipairs(list or {}) do
    local w, h, r = string.match(tostring(text), "^(%d+)x(%d+)@([%d%.]+)")
    if w then
      table.insert(modes, { width = tonumber(w), height = tonumber(h), refresh = math.floor(tonumber(r) * 1000 + 0.5) })
    end
  end
  return modes
end

-- `hyprctl monitors all -j` as heads. "all" matters: a screen that is
-- plugged in but disabled has to count as attached.
function M.heads(monitors)
  local heads = {}
  for _, m in ipairs(monitors or {}) do
    if type(m) == "table" and type(m.name) == "string" then
      table.insert(heads, {
        name = m.name,
        description = m.description or "",
        make = m.make or "",
        serial = m.serial or "",
        enabled = m.disabled ~= true and (m.width or 0) > 0,
        x = m.x or 0,
        y = m.y or 0,
        scale = m.scale or 1,
        transform = m.transform or 0,
        width = m.width or 0,
        height = m.height or 0,
        refresh = math.floor((m.refreshRate or 0) * 1000 + 0.5),
        mirrorOf = m.mirrorOf,
        modes = parseModes(m.availableModes),
      })
    end
  end
  return heads
end

function M.list(done)
  local accepted = noctalia.runAsync({ "hyprctl", "monitors", "all", "-j" }, function(result)
    if result.exitCode ~= 0 then
      noctalia.log("vitrine: hyprctl monitors failed: " .. noctalia.string.trim(result.stderr or ""))
      return done(nil)
    end
    local monitors = noctalia.json.decode(result.stdout or "")
    done(type(monitors) == "table" and M.heads(monitors) or nil)
  end)
  if not accepted then
    done(nil)
  end
end

local function modeText(mode)
  if mode == nil or mode == "preferred" then
    return "preferred"
  end
  return string.format("%dx%d@%.3f", mode.width, mode.height, (mode.refresh or 0) / 1000)
end

local function scaleText(scale)
  if scale == nil then
    return "auto"
  end
  return string.format("%.6g", scale)
end

local function positionText(cfg)
  if cfg.x == nil then
    return "auto"
  end
  return string.format("%dx%d", math.floor(cfg.x), math.floor(cfg.y or 0))
end

-- One config in hyprlang's `monitor=` syntax (the argument of `keyword monitor`).
function M.keywordRule(cfg)
  if not cfg.enabled then
    return cfg.name .. ",disable"
  end
  local rule = string.format("%s,%s,%s,%s", cfg.name, modeText(cfg.mode), positionText(cfg), scaleText(cfg.scale))
  if cfg.transform ~= nil then
    rule = rule .. ",transform," .. math.floor(cfg.transform)
  end
  if cfg.mirror ~= nil and cfg.mirror ~= "" then
    rule = rule .. ",mirror," .. cfg.mirror
  end
  return rule
end

-- The same for the Lua parser. An empty `mirror` is what clears one.
function M.evalRule(cfg)
  if not cfg.enabled then
    return string.format("hl.monitor({output=%q, disabled=true})", cfg.name)
  end
  local fields = {
    string.format("output=%q", cfg.name),
    string.format("mode=%q", modeText(cfg.mode)),
    string.format("position=%q", positionText(cfg)),
    string.format("scale=%q", scaleText(cfg.scale)),
    "disabled=false",
  }
  if cfg.transform ~= nil then
    table.insert(fields, "transform=" .. math.floor(cfg.transform))
  end
  if cfg.mirror ~= nil then
    table.insert(fields, string.format("mirror=%q", cfg.mirror))
  end
  return "hl.monitor({" .. table.concat(fields, ", ") .. "})"
end

local function probe(done)
  local known = noctalia.state.get("vitrine_hypr_lua")
  if known ~= nil then
    return done(known)
  end
  local accepted = noctalia.runAsync({ "hyprctl", "eval", "return 1" }, function(result)
    local out = noctalia.string.trim((result.stdout or "") .. (result.stderr or ""))
    local lua = nil
    if out == "ok" then
      lua = true
    elseif string.find(string.lower(out), "unknown", 1, true) or string.find(string.lower(out), "invalid", 1, true) then
      lua = false
    end
    if lua ~= nil then
      noctalia.state.set("vitrine_hypr_lua", lua)
    end
    done(lua == true)
  end)
  if not accepted then
    done(false)
  end
end

local function failed(result)
  local out = (result.stdout or "") .. (result.stderr or "")
  return result.exitCode ~= 0 or string.find(string.lower(out), "error", 1, true) ~= nil
    or string.find(out, "non%-legacy") ~= nil or string.find(string.lower(out), "invalid", 1, true) ~= nil
end

-- Applies one step; `done(ok, output)`.
function M.apply(configs, done)
  for _, cfg in ipairs(configs) do
    if not string.match(cfg.name, core.SAFE_NAME) or (cfg.mirror and cfg.mirror ~= "" and not string.match(cfg.mirror, core.SAFE_NAME)) then
      return done(false, "unsafe output name")
    end
  end
  probe(function(lua)
    if lua then
      local parts = {}
      for _, cfg in ipairs(configs) do
        table.insert(parts, M.evalRule(cfg))
      end
      local accepted = noctalia.runAsync({ "hyprctl", "eval", table.concat(parts, "\n") }, function(result)
        done(not failed(result), (result.stdout or "") .. (result.stderr or ""))
      end)
      if not accepted then
        done(false, "could not start hyprctl")
      end
      return
    end
    -- hyprlang: one keyword per output, in order, stopping at the first refusal.
    local i = 0
    local function nextRule()
      i += 1
      local cfg = configs[i]
      if cfg == nil then
        return done(true, "")
      end
      local accepted = noctalia.runAsync({ "hyprctl", "keyword", "monitor", M.keywordRule(cfg) }, function(result)
        if failed(result) then
          return done(false, (result.stdout or "") .. (result.stderr or ""))
        end
        nextRule()
      end)
      if not accepted then
        done(false, "could not start hyprctl")
      end
    end
    nextRule()
  end)
end

-- Extend with nothing remembered: the user's own config describes it.
function M.restoreConfig(done)
  local accepted = noctalia.runAsync({ "hyprctl", "reload" }, function(result)
    done(result.exitCode == 0, result.stdout or "")
  end)
  if not accepted then
    done(false, "could not start hyprctl")
  end
end

return M
