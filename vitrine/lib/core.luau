--!nonstrict
-- Vitrine's decisions, with no compositor in them: which output is the
-- built-in panel, which layout is on, and what to change to reach another.
-- Pure, so the tests run it under plain Lua.
--
-- A head is one output as a backend reports it:
--   { name, description, make, serial, enabled, x, y, scale, transform,
--     width, height, refresh, mirrorOf? }
-- width/height/refresh are the current mode in pixels and mHz.
--
-- A plan is a list of steps; each step is a list of output configs applied
-- together:
--   { name, enabled, mode = "preferred" | { width, height, refresh } | nil,
--     x, y, scale, transform, mirror? }
-- A field left out keeps what the output has. When a step switches something
-- off, the step before it switched something else on, and the backend checks
-- that it really came up before going on: the screen you can see is never
-- the one turned off first.

local M = {}

M.MODES = { "extend", "mirror", "external", "internal" }

-- Built-in panels. Everything else counts as an external screen.
local INTERNAL_PREFIXES = { "eDP", "LVDS", "DSI" }
-- Outputs nobody can look at: headless ones for streaming or screen sharing,
-- nested sessions, placeholders.
local VIRTUAL_PREFIXES = { "HEADLESS", "WL-", "X11-", "NOOP", "FALLBACK", "Virtual" }

-- Output names reach command lines (hyprlang rules), so only plain ones pass.
M.SAFE_NAME = "^[%w%-%._]+$"

local function hasPrefix(name, prefixes)
  for _, prefix in ipairs(prefixes) do
    if string.sub(name, 1, #prefix) == prefix then
      return true
    end
  end
  return false
end

function M.isInternal(name)
  return hasPrefix(name, INTERNAL_PREFIXES)
end

function M.isVirtual(name)
  return hasPrefix(name, VIRTUAL_PREFIXES)
end

-- The logical size of a head: pixels divided by scale, swapped when rotated.
function M.logicalSize(head)
  local scale = (head.scale and head.scale > 0) and head.scale or 1
  local w, h = (head.width or 0) / scale, (head.height or 0) / scale
  local t = head.transform or 0
  if t == 1 or t == 3 or t == 5 or t == 7 then
    w, h = h, w
  end
  return math.floor(w + 0.5), math.floor(h + 0.5)
end

-- "open" | "closed" | nil, from /proc/acpi/button/lid/*/state contents.
function M.parseLid(text)
  if type(text) ~= "string" then
    return nil
  end
  local state = string.match(text, "state:%s*(%a+)")
  if state == "open" or state == "closed" then
    return state
  end
  return nil
end

-- "b true" / "b false" from `busctl get-property ... LidClosed`: true,
-- false, or nil when there is no answer.
function M.parseLogindLid(text)
  if type(text) ~= "string" then
    return nil
  end
  local value = string.match(text, "^%s*b%s+(%a+)")
  if value == "true" then
    return true
  elseif value == "false" then
    return false
  end
  return nil
end

-- Whether a remembered record is whole enough to switch to.
function M.validRecord(rec)
  return type(rec) == "table" and type(rec.name) == "string" and string.match(rec.name, M.SAFE_NAME) ~= nil
    and type(rec.mode) == "table" and type(rec.mode.width) == "number" and rec.mode.width > 0
    and type(rec.mode.height) == "number" and rec.mode.height > 0
end

-- Splits the heads into the built-in panel and the external screens, and
-- works out which layout is on.
function M.classify(heads)
  local info = { internal = nil, external = {}, mode = "internal" }
  local others = {}
  for _, head in ipairs(heads or {}) do
    local name = head.name
    if type(name) == "string" and string.match(name, M.SAFE_NAME) and not M.isVirtual(name) then
      if info.internal == nil and M.isInternal(name) then
        info.internal = head
      else
        table.insert(others, head)
      end
    end
  end
  table.sort(others, function(a, b)
    return a.name < b.name
  end)
  info.external = others

  -- No eDP/LVDS/DSI at all (a desktop): the first output by name is the one
  -- that must never be switched off, the same one every time.
  if info.internal == nil and #info.external > 0 then
    info.internal = table.remove(info.external, 1)
  end
  if info.internal == nil then
    return info
  end

  local internalOn = info.internal.enabled == true
  local externalOn, mirroring = 0, 0
  for _, head in ipairs(info.external) do
    if head.enabled == true then
      externalOn += 1
      if head.mirrorOf ~= nil and head.mirrorOf ~= "" and head.mirrorOf ~= "none" then
        mirroring += 1
      end
    end
  end
  local im = info.internal.mirrorOf
  if internalOn and im ~= nil and im ~= "" and im ~= "none" then
    mirroring += 1
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

-- What to remember about a head that is on, to bring it back the same way.
function M.record(head)
  if head == nil or head.enabled ~= true or not head.width or head.width <= 0 then
    return nil
  end
  return {
    name = head.name,
    -- Which screen it was, not only which connector: another projector on
    -- the same port must not get this one's mode.
    description = head.description,
    mode = { width = head.width, height = head.height, refresh = head.refresh or 0 },
    x = head.x or 0,
    y = head.y or 0,
    scale = head.scale or 1,
    transform = head.transform or 0,
  }
end

-- Whether a record is of this head: the same connector, and the same screen
-- on it when both say which.
function M.sameScreen(rec, head)
  if rec == nil or head == nil or rec.name ~= head.name then
    return false
  end
  local a, b = rec.description, head.description
  return a == nil or a == "" or b == nil or b == "" or a == b
end

-- The logical width a record takes up.
local function recordWidth(rec)
  local mode = type(rec.mode) == "table" and rec.mode or {}
  local w = M.logicalSize({ width = mode.width, height = mode.height, scale = rec.scale, transform = rec.transform })
  return w
end

-- The size a screen switched on at its preferred mode will have: the mode
-- the output marks preferred, or else the first it lists, or else a guess.
function M.preferredSize(head)
  local modes = type(head.modes) == "table" and head.modes or {}
  local pick = nil
  for _, mode in ipairs(modes) do
    if mode.preferred then
      pick = mode
      break
    end
  end
  pick = pick or modes[1]
  if pick and (pick.width or 0) > 0 then
    return pick.width, pick.height or 0
  end
  return 1920, 1080
end

-- The layout to go back to for Extend: every screen that is on, as it is,
-- while extend is what is on.
function M.snapshot(info)
  if info.mode ~= "extend" then
    return nil
  end
  local outputs = {}
  for _, head in ipairs({ info.internal, table.unpack(info.external) }) do
    local rec = M.record(head)
    if rec then
      table.insert(outputs, rec)
    end
  end
  return { outputs = outputs }
end

local function copy(rec, extra)
  local out = {}
  for k, v in pairs(rec) do
    out[k] = v
  end
  for k, v in pairs(extra or {}) do
    out[k] = v
  end
  return out
end

-- The next layout for the display key: skips the ones that are not possible
-- right now, so with the lid closed it never lands on the panel under it.
function M.nextMode(current, caps)
  caps = caps or {}
  local index = 0
  for i, mode in ipairs(M.MODES) do
    if mode == current then
      index = i
    end
  end
  for step = 1, #M.MODES do
    local mode = M.MODES[((index + step - 1) % #M.MODES) + 1]
    if M.allowed(mode, caps) then
      return mode
    end
  end
  return "extend"
end

-- caps: { mirror = bool, lidClosed = bool, external = count }
function M.allowed(mode, caps)
  caps = caps or {}
  if mode == "mirror" and caps.mirror ~= true then
    return false, "no-mirror"
  end
  -- With the lid closed the panel stays off: Extend and Duplicate would
  -- light it under the lid, Laptop only would leave nothing to look at.
  if (mode == "internal" or mode == "mirror" or mode == "extend") and caps.lidClosed then
    return false, "lid-closed"
  end
  if mode ~= "internal" and (caps.external or 0) == 0 then
    return false, "no-external"
  end
  return true
end

-- The steps from what is on (`info`) to `mode`.
--   remembered  { internal = record?, extend = snapshot? }, from earlier looks
-- Returns the steps, or nil and a reason. A step that turns something off
-- carries `requires = { names }`: those must be on (checked after the step
-- before) or the plan stops there.
function M.plan(mode, info, remembered, caps)
  remembered = remembered or {}
  local ok, reason = M.allowed(mode, caps)
  if not ok then
    return nil, reason
  end
  if info.internal == nil then
    return nil, "no-outputs"
  end
  local internal = info.internal
  local panel = remembered.internal
  if panel == nil or panel.name ~= internal.name then
    panel = M.record(internal)
  end
  local function panelOn(extra)
    if panel then
      return copy(panel, copy({ enabled = true }, extra))
    end
    return copy({ name = internal.name, enabled = true, mode = "preferred" }, extra)
  end

  local externals = {}
  for _, head in ipairs(info.external) do
    table.insert(externals, head.name)
  end

  -- A screen that is already on stays as it is: its mode, place, scale and
  -- rotation all go into the config, since not every backend keeps a field
  -- that is left out (Hyprland's rules do not).
  local function keep(head, extra)
    local rec = M.record(head) or { name = head.name }
    return copy(rec, copy({ enabled = true, mirror = "" }, extra))
  end
  -- A screen switched on from off: its preferred mode at scale 1, at `x`.
  -- Returns the config and the x after it.
  local function switchOn(head, x, y)
    local w = M.preferredSize(head)
    return { name = head.name, enabled = true, mode = "preferred", scale = 1, x = x, y = y or 0, mirror = "" }, x + w
  end

  if mode == "internal" then
    local off = {}
    for _, head in ipairs(info.external) do
      table.insert(off, { name = head.name, enabled = false })
    end
    return { { panelOn() }, { requires = { internal.name }, table.unpack(off) } }
  end

  if mode == "external" then
    -- Screens switched on go in a row to the right of everything that is
    -- on now, the panel included, so nothing overlaps while it still is.
    local right = 0
    for _, head in ipairs({ internal, table.unpack(info.external) }) do
      if head.enabled then
        right = math.max(right, (head.x or 0) + M.logicalSize(head))
      end
    end
    local on, x = {}, right
    for _, head in ipairs(info.external) do
      if head.enabled then
        table.insert(on, keep(head))
      else
        local cfg
        cfg, x = switchOn(head, x)
        table.insert(on, cfg)
      end
    end
    return { on, { requires = externals, { name = internal.name, enabled = false } } }
  end

  if mode == "mirror" then
    local steps = { panelOn({ mirror = "" }) }
    for _, head in ipairs(info.external) do
      -- Scale 1 keeps the projector at its native resolution.
      table.insert(steps, { name = head.name, enabled = true, mode = "preferred", scale = 1, mirror = internal.name })
    end
    return { steps }
  end

  -- Extend: the layout that was on the last time extend was, if it covers
  -- these screens; otherwise the panel where it was and every external
  -- screen to its right, in a row.
  -- Screens in the remembered layout that are not attached any more are
  -- left out (the compositor would refuse the whole change over them), and
  -- attached ones it does not know go to its right.
  local snap = remembered.extend
  if snap and type(snap.outputs) == "table" then
    local byName = {}
    for _, rec in ipairs(snap.outputs) do
      if type(rec) == "table" and type(rec.name) == "string" and type(rec.mode) == "table" then
        byName[rec.name] = rec
      end
    end
    local covers = M.sameScreen(byName[internal.name], internal)
    local known = {}
    for _, head in ipairs(info.external) do
      if M.sameScreen(byName[head.name], head) then
        known[head.name] = true
      end
    end
    if covers and next(known) ~= nil then
      local configs = { copy(byName[internal.name], { enabled = true, mirror = "" }) }
      local right = byName[internal.name].x + recordWidth(byName[internal.name])
      for _, head in ipairs(info.external) do
        local rec = byName[head.name]
        if known[head.name] then
          table.insert(configs, copy(rec, { enabled = true, mirror = "" }))
          right = math.max(right, (rec.x or 0) + recordWidth(rec))
        end
      end
      for _, head in ipairs(info.external) do
        if not known[head.name] then
          if head.enabled then
            table.insert(configs, keep(head, { x = right, y = 0 }))
            right += M.logicalSize(head)
          else
            local cfg
            cfg, right = switchOn(head, right)
            table.insert(configs, cfg)
          end
        end
      end
      return { configs }
    end
  end
  local configs = { panelOn({ mirror = "" }) }
  local px = panel and panel.x or 0
  local py = panel and panel.y or 0
  local pw = M.logicalSize(panel and {
    width = panel.mode.width, height = panel.mode.height, scale = panel.scale, transform = panel.transform,
  } or internal)
  local x = px + pw
  for _, head in ipairs(info.external) do
    if head.enabled then
      table.insert(configs, keep(head, { x = x, y = py }))
      x += M.logicalSize(head)
    else
      local cfg
      cfg, x = switchOn(head, x, py)
      table.insert(configs, cfg)
    end
  end
  return { configs, fallback = true }
end

return M
