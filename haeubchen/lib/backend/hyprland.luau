--!nonstrict
-- Hyprland. The backend Häubchen was built and tested on.
--
-- Hyprland has two config parsers and they take window commands differently:
--
--  * The Lua parser refuses `hyprctl dispatch <name> <args>` and wants Lua:
--      hyprctl eval "hl.dispatch(hl.dsp.window.pin({action='enable', window='address:0x…'}))"
--    Several dispatches go in one eval, so a whole step is one process.
--  * hyprlang (hyprland.conf) takes the classic dispatchers, batched with
--    `hyprctl --batch`. Its `pin` is a toggle, so the current pin state is
--    passed in and the toggle is only sent when it has to flip.
--
-- `hyprctl eval` answers "ok" on the Lua parser, which is probed once and
-- remembered in noctalia.state so a reloaded service does not ask again.
--
-- Pinned windows ride along to whatever workspace becomes active on their
-- monitor, which is exactly what the corner needs.

local stream = require("./stream.luau")

local M = { name = "hyprland", canPin = true, tools = { "hyprctl", "socat" } }

-- A window address as hyprctl prints it in JSON ("0x5591…"). socket2 events
-- leave the 0x off, so both spellings are accepted and one comes out. Nothing
-- that fails this reaches a command line.
function M.id(value)
  if type(value) ~= "string" then
    return nil
  end
  local hex = string.match(value, "^0x(%x+)$") or string.match(value, "^(%x+)$")
  if hex == nil then
    return nil
  end
  return "0x" .. string.lower(hex)
end

-- How a workspace is named to a dispatcher. Normal workspaces go by id; named
-- and special ones have negative ids that are not stable, so they go by name.
-- On the Lua parser the name travels inside a %q Lua string, so any name
-- works ("web 🌐", "1: chat"); hyprlang splits a batch on ";" and its
-- arguments on ",", so a name holding either, a quote or a control character
-- is refused there. nil when the name cannot be passed on safely.
function M.workspaceSpec(workspace, lua)
  if type(workspace) ~= "table" then
    return nil
  end
  local id, name = workspace.id, workspace.name
  if type(id) == "number" and id > 0 then
    return tostring(math.floor(id))
  end
  if type(name) ~= "string" or name == "" or string.find(name, "%c") then
    return nil
  end
  if not lua and string.find(name, "[,;'\"]") then
    return nil
  end
  if string.sub(name, 1, 8) == "special:" then
    return name
  end
  return "name:" .. name
end

-- The usable rectangle of a monitor in global logical pixels. `width`/`height`
-- in `monitors -j` are physical, so they are divided by the scale and swapped
-- for a portrait transform; `reserved` (left, top, right, bottom) is the bar
-- and other exclusive zones, already logical.
function M.area(monitor)
  local scale = (monitor.scale and monitor.scale > 0) and monitor.scale or 1
  local width, height = monitor.width / scale, monitor.height / scale
  local t = monitor.transform
  if t == 1 or t == 3 or t == 5 or t == 7 then
    width, height = height, width
  end
  local reserved = monitor.reserved or { 0, 0, 0, 0 }
  local left, top = reserved[1] or 0, reserved[2] or 0
  local right, bottom = reserved[3] or 0, reserved[4] or 0
  return {
    x = monitor.x + left,
    y = monitor.y + top,
    w = width - left - right,
    h = height - top - bottom,
  }
end

-- `monitors -j` as the neutral screen: every workspace on screen (the active
-- one of each monitor plus an open special workspace on top of it) and the
-- focused monitor's usable area.
function M.screen(monitors)
  local visible, focused = {}, nil
  for _, monitor in ipairs(monitors or {}) do
    if type(monitor.activeWorkspace) == "table" and monitor.activeWorkspace.id then
      visible[monitor.activeWorkspace.id] = true
    end
    local special = monitor.specialWorkspace
    if type(special) == "table" and special.id and special.id ~= 0 then
      visible[special.id] = true
    end
    if monitor.focused then
      focused = monitor
    end
  end
  focused = focused or (monitors or {})[1]
  return {
    visible = visible,
    area = focused and M.area(focused) or { x = 0, y = 0, w = 1280, h = 720 },
    workspace = focused and focused.activeWorkspace or nil,
  }
end

function M.window(client)
  local id = M.id(client.address)
  -- `hidden` is an inactive tab of a window group: not a window you can see.
  if id == nil or client.mapped == false or client.hidden == true then
    return nil
  end
  local workspace = client.workspace or {}
  return {
    id = id,
    title = client.title or "",
    class = client.class or "",
    ws = workspace.id,
    wsLabel = workspace.name,
    workspace = workspace,
    floating = client.floating == true,
    sticky = client.pinned == true,
    fullscreen = client.fullscreen or 0,
    fullscreenClient = client.fullscreenClient or 0,
    x = client.at and client.at[1] or 0,
    y = client.at and client.at[2] or 0,
    w = client.size and client.size[1] or 0,
    h = client.size and client.size[2] or 0,
  }
end

function M.windows(clients)
  local out = {}
  for _, client in ipairs(clients or {}) do
    local window = M.window(client)
    if window ~= nil then
      table.insert(out, window)
    end
  end
  return out
end

local function isLua()
  return noctalia.state.get("hypr_lua") ~= false
end

function M.homeOf(window)
  return { ws = window.ws, spec = M.workspaceSpec(window.workspace, isLua()) }
end

-- ── Commands ─────────────────────────────────────────────────────────────────
--
-- A step is a list of ops:
--   { op = "float", on = bool }        { op = "pin", on = bool }
--   { op = "size", w, h }              { op = "move", x, y }
--   { op = "workspace", spec }         { op = "fullscreen", internal, client }
--   { op = "aspect", on = bool }       lock 16:9 while resizing; off hands it
--                                      back to the user's window rules

local function luaOp(address, op)
  local target = string.format("window=%q", "address:" .. address)
  if op.op == "float" then
    return string.format("hl.dispatch(hl.dsp.window.float({action=%q, %s}))", op.on and "enable" or "disable", target)
  elseif op.op == "pin" then
    return string.format("hl.dispatch(hl.dsp.window.pin({action=%q, %s}))", op.on and "enable" or "disable", target)
  elseif op.op == "size" then
    return string.format("hl.dispatch(hl.dsp.window.resize({x=%d, y=%d, %s}))", op.w, op.h, target)
  elseif op.op == "move" then
    return string.format("hl.dispatch(hl.dsp.window.move({x=%d, y=%d, %s}))", op.x, op.y, target)
  elseif op.op == "workspace" then
    return string.format("hl.dispatch(hl.dsp.window.move({workspace=%q, follow=false, %s}))", op.spec, target)
  elseif op.op == "fullscreen" then
    return string.format("hl.dispatch(hl.dsp.window.fullscreen_state({internal=%d, client=%d, %s}))", op.internal, op.client, target)
  elseif op.op == "aspect" then
    return string.format("hl.dispatch(hl.dsp.window.set_prop({prop='keep_aspect_ratio', value=%q, %s}))", op.on and "1" or "unset", target)
  end
  return nil
end

local function legacyOp(address, op, pinned)
  local target = "address:" .. address
  if op.op == "float" then
    return (op.on and "dispatch setfloating " or "dispatch settiled ") .. target
  elseif op.op == "pin" then
    if pinned == op.on then
      return nil
    end
    return "dispatch pin " .. target
  elseif op.op == "size" then
    return string.format("dispatch resizewindowpixel exact %d %d,%s", op.w, op.h, target)
  elseif op.op == "move" then
    return string.format("dispatch movewindowpixel exact %d %d,%s", op.x, op.y, target)
  elseif op.op == "workspace" then
    return string.format("dispatch movetoworkspacesilent %s,%s", op.spec, target)
  elseif op.op == "aspect" then
    return string.format("dispatch setprop %s keepaspectratio %s", target, op.on and "1" or "unset")
  end
  -- hyprlang's fullscreenstate only acts on the focused window, so a
  -- fullscreen player is left alone there rather than a wrong window changed.
  return nil
end

-- The argv for one step. `pinned` is whether the window is pinned right now;
-- only hyprlang needs it, to know whether its pin toggle has to be sent.
function M.argv(address, ops, pinned)
  if isLua() then
    local parts = {}
    for _, op in ipairs(ops) do
      table.insert(parts, luaOp(address, op))
    end
    return { "hyprctl", "eval", table.concat(parts, " ") }
  end
  local parts = {}
  for _, op in ipairs(ops) do
    local line = legacyOp(address, op, pinned)
    if line ~= nil then
      table.insert(parts, line)
      if op.op == "pin" then
        pinned = op.on
      end
    end
  end
  return { "hyprctl", "--batch", table.concat(parts, " ; ") }
end

local function apply(address, ops, pinned, done)
  local accepted = noctalia.runAsync(M.argv(address, ops, pinned), function(result)
    local output = (result.stdout or "") .. (result.stderr or "")
    -- Both parsers exit 0 with an error line for a dispatch they rejected.
    if result.exitCode ~= 0 or string.find(output, "error", 1, true) then
      noctalia.log("haeubchen: hyprctl said: " .. noctalia.string.trim(output))
    end
    if done then
      done()
    end
  end)
  if not accepted and done then
    done()
  end
end

local function enterOps(window, rect)
  local ops = {}
  if (window.fullscreen or 0) ~= 0 then
    table.insert(ops, { op = "fullscreen", internal = 0, client = 0 })
  end
  table.insert(ops, { op = "float", on = true })
  table.insert(ops, { op = "size", w = rect.w, h = rect.h })
  table.insert(ops, { op = "move", x = rect.x, y = rect.y })
  table.insert(ops, { op = "pin", on = true })
  table.insert(ops, { op = "aspect", on = true })
  return ops
end

-- Back to where it was. Pinned windows ride along to whatever workspace is
-- active, so the move home is explicit and comes before retiling -- otherwise
-- it would tile into the workspace the user just switched to.
local function exitOps(t)
  local ops = { { op = "pin", on = false }, { op = "aspect", on = false } }
  if t.home and t.home.spec then
    table.insert(ops, { op = "workspace", spec = t.home.spec })
  end
  local orig = t.orig or {}
  if orig.floating then
    table.insert(ops, { op = "size", w = orig.w, h = orig.h })
    table.insert(ops, { op = "move", x = orig.x, y = orig.y })
  else
    table.insert(ops, { op = "float", on = false })
  end
  if (orig.fullscreen or 0) ~= 0 then
    table.insert(ops, { op = "fullscreen", internal = orig.fullscreen, client = orig.fullscreenClient or 0 })
  end
  return ops
end

function M.enter(window, rect, _screen, done)
  apply(window.id, enterOps(window, rect), window.sticky, done)
end

-- A pinned window rides along with its own monitor's active workspace, so
-- this is only reached when that monitor went away: it is moved to the
-- focused monitor's workspace and pinned again there.
function M.carry(window, rect, screen, done)
  local spec = M.workspaceSpec(screen.workspace, isLua())
  if spec == nil then
    return done()
  end
  apply(window.id, {
    { op = "pin", on = false },
    { op = "workspace", spec = spec },
    { op = "size", w = rect.w, h = rect.h },
    { op = "move", x = rect.x, y = rect.y },
    { op = "pin", on = true },
  }, window.sticky, done)
end

-- `t.sticky` is whether the window was pinned at the last look; hyprlang's pin
-- is a toggle, so it must not be sent to a window the user already unpinned.
function M.exit(t, done)
  apply(t.id, exitOps(t), t.sticky ~= false, done)
end

-- Fire and forget, for onExit: the entry is gone before hyprctl answers.
function M.exitDetached(t)
  noctalia.runAsync(M.argv(t.id, exitOps(t), t.sticky ~= false))
end

function M.focusHome(home)
  if home == nil or home.spec == nil then
    return
  end
  if isLua() then
    noctalia.runAsync({ "hyprctl", "eval", string.format("hl.dispatch(hl.dsp.focus({workspace=%q}))", home.spec) })
  else
    noctalia.runAsync({ "hyprctl", "dispatch", "workspace", home.spec })
  end
end

function M.close(id)
  if isLua() then
    noctalia.runAsync({ "hyprctl", "eval", string.format("hl.dispatch(hl.dsp.window.close({window=%q}))", "address:" .. id) })
  else
    noctalia.runAsync({ "hyprctl", "dispatch", "closewindow", "address:" .. id })
  end
end

-- ── Reading ──────────────────────────────────────────────────────────────────

-- Always calls `done` exactly once, nil on any failure, including a refused
-- runAsync: the service's queue waits on it.
local function readJson(what, done)
  local accepted = noctalia.runAsync({ "hyprctl", "-j", what }, function(result)
    if result.exitCode ~= 0 then
      return done(nil)
    end
    local value = noctalia.json.decode(result.stdout or "")
    if type(value) ~= "table" then
      value = nil
    end
    done(value)
  end)
  if not accepted then
    done(nil)
  end
end

-- `done(screen, windows)`, both nil when hyprctl is not answering.
function M.read(done)
  readJson("monitors", function(monitors)
    if monitors == nil then
      return done(nil, nil)
    end
    readJson("clients", function(clients)
      if clients == nil then
        return done(nil, nil)
      end
      done(M.screen(monitors), M.windows(clients))
    end)
  end)
end

function M.list(done)
  readJson("clients", function(clients)
    done(M.windows(clients))
  end)
end

function M.active(done)
  readJson("activewindow", function(client)
    if client == nil or client.address == nil then
      return done(nil)
    end
    done(M.window(client))
  end)
end

-- ── Events ───────────────────────────────────────────────────────────────────

local ONSCREEN = {
  workspacev2 = true,
  focusedmonv2 = true,
  activespecialv2 = true,
  monitoraddedv2 = true,
  monitorremovedv2 = true,
  movewindowv2 = true,
  changefloatingmode = true,
  pin = true,
  windowtitlev2 = true,
}

-- One socket2 line ("workspacev2>>2,2") as a neutral event, or nil.
function M.parseEvent(line)
  local name, data = string.match(line, "^([%w]+)>>(.*)$")
  if name == nil then
    return nil
  end
  if name == "openwindow" then
    local address, _, class = string.match(data, "^(%x+),([^,]*),([^,]*),")
    return { kind = "open", id = M.id(address), class = class }
  end
  if name == "closewindow" then
    return { kind = "close", id = M.id(data) }
  end
  if ONSCREEN[name] then
    return { kind = "check" }
  end
  return nil
end

local function paths()
  local runtime = noctalia.getenv("XDG_RUNTIME_DIR")
  local signature = noctalia.getenv("HYPRLAND_INSTANCE_SIGNATURE")
  if runtime == nil or signature == nil
    or not string.match(signature, "^[%w_]+$") or not string.match(runtime, "^[%w/_%-.]+$") then
    return nil
  end
  local dir = runtime .. "/hypr/" .. signature
  return dir .. "/.socket.sock", dir .. "/.socket2.sock"
end

-- The variable alone is not enough: one left behind in the systemd user
-- environment after logging out of Hyprland would pick it on another
-- compositor.
function M.available()
  local control = paths()
  return control ~= nil and noctalia.fileExists(control)
end

-- What `hyprctl eval 'return 1'` says about the config parser: true for Lua
-- ("ok"), false for a definite refusal from a hyprlang Hyprland, nil when it
-- could not tell (Hyprland not answering yet), which is probed again later.
function M.parseProbe(exitCode, output)
  output = output or ""
  if exitCode == 0 and string.match(output, "^%s*ok%s*$") then
    return true
  end
  local lower = string.lower(output)
  if output == "" or string.find(lower, "connect", 1, true) or string.find(lower, "no such file", 1, true)
    or string.find(lower, "timed out", 1, true) or string.find(lower, "refused", 1, true) then
    return nil
  end
  return false
end

local events = nil
local probing = false

local function probe(done)
  if probing then
    return
  end
  probing = true
  local accepted = noctalia.runAsync({ "hyprctl", "eval", "return 1" }, function(result)
    probing = false
    local lua = M.parseProbe(result.exitCode, noctalia.string.trim((result.stdout or "") .. (result.stderr or "")))
    if lua ~= nil then
      noctalia.state.set("hypr_lua", lua)
      if not lua then
        noctalia.log("haeubchen: hyprlang config detected; using classic dispatchers")
      end
    end
    done(lua)
  end)
  if not accepted then
    probing = false
    done(nil)
  end
end

-- Probes the parser, then follows socket2. `onEvent` gets neutral events.
-- Events only start once the parser is known, so no command goes out in the
-- wrong dialect; until then every tick probes again.
function M.start(onEvent)
  local _, socket2 = paths()
  if socket2 == nil then
    return false
  end
  local command = string.format("socat -U - UNIX-CONNECT:'%s'", socket2)
  events = stream.follow(command, M.parseEvent, onEvent)
  if noctalia.state.get("hypr_lua") ~= nil then
    return events.listen()
  end
  probe(function(lua)
    if lua ~= nil then
      events.listen()
    end
  end)
  return true
end

function M.tick()
  if events == nil then
    return
  end
  if noctalia.state.get("hypr_lua") == nil then
    probe(function(lua)
      if lua ~= nil then
        events.listen()
      end
    end)
    return
  end
  events.tick()
end

return M
