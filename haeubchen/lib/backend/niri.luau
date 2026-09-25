--!nonstrict
-- niri. Written against niri-ipc (niri-ipc/src/lib.rs); not yet tested on a
-- real niri session.
--
-- niri has no pin: a floating window belongs to one workspace. So in the
-- corner, every workspace switch is answered with "carry": the window is moved
-- to the workspace you switched to and placed in the corner again. Expect it
-- to follow a beat behind the switch rather than stay perfectly still.
--
-- Actions are sent as JSON requests straight to $NIRI_SOCKET with socat,
-- because only the socket takes a workspace by its stable id (`niri msg
-- action` takes an index, which changes as workspaces move). Events come from
-- `niri msg --json event-stream`.
--
-- Two frames: niri reports a floating window's place in the workspace view
-- (the output), but MoveFloatingWindow's SetFixed is relative to the working
-- area, which starts past a bar on the top or left edge. The IPC does not say
-- how big the bar is, so the first placement on each output measures it:
-- the window is read back, the difference remembered, and the window put
-- right. Every later placement on that output is right at once. The corner
-- is computed on the whole output; with a bar on the corner's edge, raise
-- the margin.

local stream = require("./stream.luau")

local M = { name = "niri", canPin = false, tools = { "niri", "socat" } }

function M.id(value)
  if type(value) == "number" then
    return tostring(math.floor(value))
  end
  if type(value) == "string" and string.match(value, "^%d+$") then
    return value
  end
  return nil
end

local function socket()
  local path = noctalia.getenv("NIRI_SOCKET")
  if path == nil or not string.match(path, "^[%w/_%-.]+$") then
    return nil
  end
  return path
end

function M.window(raw, workspaces)
  local id = M.id(raw.id)
  if id == nil then
    return nil
  end
  local layout = raw.layout or {}
  local pos = layout.tile_pos_in_workspace_view or { 0, 0 }
  local size = layout.window_size or layout.tile_size or { 0, 0 }
  local workspace = workspaces and workspaces[raw.workspace_id] or nil
  return {
    id = id,
    output = workspace and workspace.output or nil,
    title = raw.title or "",
    class = raw.app_id or "",
    ws = raw.workspace_id,
    wsLabel = workspace and (workspace.name or tostring(workspace.idx)) or "?",
    floating = raw.is_floating == true,
    sticky = false,
    fullscreen = 0,
    x = math.floor(pos[1] or 0),
    y = math.floor(pos[2] or 0),
    w = math.floor(size[1] or 0),
    h = math.floor(size[2] or 0),
  }
end

local function byId(workspaces)
  local map = {}
  for _, workspace in ipairs(workspaces or {}) do
    map[workspace.id] = workspace
  end
  return map
end

function M.windows(raw, workspaces)
  local map = byId(workspaces)
  local out = {}
  for _, entry in ipairs(raw or {}) do
    local window = M.window(entry, map)
    if window ~= nil and window.ws ~= nil then
      table.insert(out, window)
    end
  end
  return out
end

-- `area` is in working-area coordinates (origin 0,0), because that is what
-- MoveFloatingWindow takes.
function M.screen(workspaces, outputs)
  local visible, focused = {}, nil
  for _, workspace in ipairs(workspaces or {}) do
    if workspace.is_active then
      visible[workspace.id] = true
    end
    if workspace.is_focused then
      focused = workspace
    end
  end
  local logical = nil
  if focused and focused.output and type(outputs) == "table" and outputs[focused.output] then
    logical = outputs[focused.output].logical
  end
  if logical == nil then
    return nil -- no size to place by; better no move than a wrong one
  end
  return {
    visible = visible,
    area = { x = 0, y = 0, w = logical.width or 1280, h = logical.height or 720 },
    workspace = focused and focused.id or nil,
    output = focused and focused.output or nil,
  }
end

function M.homeOf(window)
  return { ws = window.ws, output = window.output }
end

-- ── Commands ─────────────────────────────────────────────────────────────────

-- Each action is one JSON request; they are chained with && in one shell, so
-- a failed one stops the rest. Only numbers are ever interpolated.
local function send(actions, done)
  local path = socket()
  if path == nil then
    if done then
      done()
    end
    return
  end
  local parts = {}
  for _, action in ipairs(actions) do
    table.insert(parts, string.format("printf '%%s\\n' '%s' | socat - UNIX-CONNECT:'%s'", action, path))
  end
  local accepted = noctalia.runAsync(table.concat(parts, " && "), function(result)
    local output = (result.stdout or "") .. (result.stderr or "")
    if result.exitCode ~= 0 or string.find(output, '"Err"', 1, true) then
      noctalia.log("haeubchen: niri said: " .. noctalia.string.trim(output))
    end
    if done then
      done()
    end
  end)
  if not accepted and done then
    done()
  end
end

local function floating(id)
  return string.format('{"Action":{"MoveWindowToFloating":{"id":%s}}}', id)
end

local function tiling(id)
  return string.format('{"Action":{"MoveWindowToTiling":{"id":%s}}}', id)
end

local function size(id, w, h)
  return string.format('{"Action":{"SetWindowWidth":{"id":%s,"change":{"SetFixed":%d}}}}', id, w),
    string.format('{"Action":{"SetWindowHeight":{"id":%s,"change":{"SetFixed":%d}}}}', id, h)
end

-- [output] = { x, y }: how far the working area starts from the output's
-- corner, as measured (see the top of this file).
local offsets = {}

function M.offsetOf(output)
  return offsets[output or ""] or { x = 0, y = 0 }
end

local function place(id, x, y, output)
  local off = M.offsetOf(output)
  return string.format('{"Action":{"MoveFloatingWindow":{"id":%s,"x":{"SetFixed":%d},"y":{"SetFixed":%d}}}}',
    id, math.floor(x - off.x), math.floor(y - off.y))
end

-- What a read-back after a placement teaches: the offset to remember, or
-- nil when the window is where it was asked to be (or so far off that
-- something else moved it, niri's clamp at a screen edge for one).
function M.learnOffset(requested, reported, known)
  known = known or { x = 0, y = 0 }
  local dx, dy = reported.x - requested.x, reported.y - requested.y
  if dx == 0 and dy == 0 then
    return nil
  end
  if math.abs(dx) > 400 or math.abs(dy) > 400 then
    return nil
  end
  return { x = known.x + dx, y = known.y + dy }
end

local function toWorkspace(id, ws)
  return string.format('{"Action":{"MoveWindowToWorkspace":{"window_id":%s,"reference":{"Id":%d},"focus":false}}}', id, ws)
end

-- The window is on its home workspace, which has just left the screen, so it
-- is brought over to the one on screen in the same step.
local readJson -- below

-- Reads the window back after a placement; if it landed off by the bar,
-- remembers that for `output` and puts it right. Then `done`.
local function verify(id, x, y, output, done)
  readJson("windows", function(raw)
    local now = nil
    for _, entry in ipairs(raw or {}) do
      if M.id(entry.id) == id then
        now = M.window(entry, nil)
      end
    end
    local learned = now and output and M.learnOffset({ x = x, y = y }, now, offsets[output])
    if learned == nil then
      if done then done() end
      return
    end
    offsets[output] = learned
    send({ place(id, x, y, output) }, done)
  end)
end

function M.enter(window, rect, screen, done)
  local w, h = size(window.id, rect.w, rect.h)
  local actions = { floating(window.id), w, h }
  if type(screen.workspace) == "number" then
    table.insert(actions, toWorkspace(window.id, screen.workspace))
  end
  table.insert(actions, place(window.id, rect.x, rect.y, screen.output))
  send(actions, function()
    verify(window.id, rect.x, rect.y, screen.output, done)
  end)
end

function M.carry(window, rect, screen, done)
  if type(screen.workspace) ~= "number" then
    return done()
  end
  send({ toWorkspace(window.id, screen.workspace), place(window.id, rect.x, rect.y, screen.output) }, function()
    verify(window.id, rect.x, rect.y, screen.output, done)
  end)
end

local function exitActions(t)
  local actions = {}
  if t.home and type(t.home.ws) == "number" then
    table.insert(actions, toWorkspace(t.id, t.home.ws))
  end
  local orig = t.orig or {}
  if orig.floating then
    local w, h = size(t.id, orig.w, orig.h)
    table.insert(actions, w)
    table.insert(actions, h)
    -- orig was read in the view frame, like every reported position.
    table.insert(actions, place(t.id, orig.x, orig.y, t.home and t.home.output))
  else
    table.insert(actions, tiling(t.id))
  end
  return actions
end

function M.exit(t, done)
  send(exitActions(t), done)
end

function M.exitDetached(t)
  send(exitActions(t), nil)
end

function M.focusHome(home)
  if home and type(home.ws) == "number" then
    send({ string.format('{"Action":{"FocusWorkspace":{"reference":{"Id":%d}}}}', home.ws) }, nil)
  end
end

function M.close(id)
  send({ string.format('{"Action":{"CloseWindow":{"id":%s}}}', id) }, nil)
end

-- ── Reading ──────────────────────────────────────────────────────────────────

-- Always calls `done` exactly once, nil on any failure, including a refused
-- runAsync: the service's queue waits on it.
function readJson(what, done)
  local accepted = noctalia.runAsync({ "niri", "msg", "--json", what }, function(result)
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

function M.read(done)
  readJson("workspaces", function(workspaces)
    if workspaces == nil then
      return done(nil, nil)
    end
    readJson("windows", function(windows)
      if windows == nil then
        return done(nil, nil)
      end
      readJson("outputs", function(outputs)
        if outputs == nil then
          return done(nil, nil)
        end
        local screen = M.screen(workspaces, outputs)
        if screen == nil then
          return done(nil, nil)
        end
        done(screen, M.windows(windows, workspaces))
      end)
    end)
  end)
end

function M.list(done)
  readJson("workspaces", function(workspaces)
    readJson("windows", function(windows)
      done(M.windows(windows, workspaces))
    end)
  end)
end

function M.active(done)
  readJson("focused-window", function(raw)
    if raw == nil or raw.id == nil then
      return done(nil)
    end
    done(M.window(raw, nil))
  end)
end

-- ── Events ───────────────────────────────────────────────────────────────────

local CHECK = {
  WorkspacesChanged = true,
  WorkspaceActivated = true,
  WindowsChanged = true,
}

function M.parseEvent(line)
  local event = noctalia.json.decode(line)
  if type(event) ~= "table" then
    return nil
  end
  if event.WindowOpenedOrChanged and event.WindowOpenedOrChanged.window then
    local window = event.WindowOpenedOrChanged.window
    return { kind = "open", id = M.id(window.id), class = window.app_id }
  end
  if event.WindowClosed then
    return { kind = "close", id = M.id(event.WindowClosed.id) }
  end
  for name in pairs(event) do
    if CHECK[name] then
      return { kind = "check" }
    end
  end
  return nil
end

function M.available()
  local path = socket()
  return path ~= nil and noctalia.fileExists(path)
end

local events = nil

function M.start(onEvent)
  events = stream.follow("niri msg --json event-stream", M.parseEvent, onEvent)
  return events.listen()
end

function M.tick()
  if events ~= nil then
    events.tick()
  end
end

return M
