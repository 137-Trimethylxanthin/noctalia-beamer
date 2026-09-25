--!nonstrict
-- MangoWC. Written against Mango 0.17.3's IPC (src/ipc/ipc.c, docs/ipc.md);
-- not yet tested on a real Mango session.
--
-- `mmsg` talks to the JSON socket at $MANGO_INSTANCE_SIGNATURE:
--
--   mmsg get all-clients      {"clients":[{id, title, appid, monitor, tags:[1,3],
--                                 is_floating, is_global, is_fullscreen, x, y,
--                                 width, height, is_focused, ...}]}
--   mmsg get all-monitors     {"monitors":[{name, active, x, y, width, height,
--                                 active_tags:[2], ...}]}
--   mmsg watch all-clients    the same snapshot again on every change, one per line
--   mmsg dispatch <func>,<args> client,<id>
--
-- Workspaces are tags, one set per monitor, so a workspace key here is
-- "<monitor>:<tag>". A "global" window shows on every tag of its monitor,
-- which is Mango's pin. Floating, global and fullscreen are toggles, so every
-- step reads the window first and only flips what needs flipping.
--
-- The monitor rectangle Mango reports is the whole output: the bar's space is
-- not subtracted, so raise the margin if the corner overlaps it.

local stream = require("./stream.luau")

local M = { name = "mango", canPin = true, tools = { "mmsg" } }

-- Mango client ids are positive integers. Only digits ever reach a command.
function M.id(value)
  if type(value) == "number" and value > 0 then
    return tostring(math.floor(value))
  end
  if type(value) == "string" and string.match(value, "^%d+$") and value ~= "0" then
    return value
  end
  return nil
end

-- Output names go into `tagcrossmon`; DRM connector names only.
local function safeMonitor(name)
  return type(name) == "string" and string.match(name, "^[%w%-_.]+$") ~= nil
end

-- The lowest real tag a client is on (tag 0 is Mango's special tag).
local function firstTag(tags)
  local best = nil
  for _, tag in ipairs(tags or {}) do
    if type(tag) == "number" and tag > 0 and (best == nil or tag < best) then
      best = tag
    end
  end
  return best
end

local function list(value, key)
  if type(value) ~= "table" then
    return {}
  end
  if type(value[key]) == "table" then
    return value[key]
  end
  return value
end

function M.window(client)
  if type(client) ~= "table" then
    return nil
  end
  local id = M.id(client.id)
  local tag = firstTag(client.tags)
  if id == nil or tag == nil or client.is_scratchpad == true or client.is_namedscratchpad == true then
    return nil
  end
  local monitor = client.monitor or ""
  return {
    id = id,
    title = client.title or "",
    class = client.appid or "",
    ws = monitor .. ":" .. tostring(tag),
    wsLabel = tostring(tag),
    monitor = monitor,
    tag = tag,
    floating = client.is_floating == true,
    sticky = client.is_global == true,
    fullscreen = client.is_fullscreen == true and 1 or 0,
    x = math.floor(client.x or 0),
    y = math.floor(client.y or 0),
    w = math.floor(client.width or 0),
    h = math.floor(client.height or 0),
  }
end

function M.windows(clients)
  local out = {}
  for _, client in ipairs(list(clients, "clients")) do
    local window = M.window(client)
    if window ~= nil then
      table.insert(out, window)
    end
  end
  return out
end

-- Every monitor's active tags are on screen; the area is the active
-- (focused) monitor, in global coordinates, which is what movewin takes.
function M.screen(monitors)
  local visible, focused = {}, nil
  local all = list(monitors, "monitors")
  for _, monitor in ipairs(all) do
    for _, tag in ipairs(monitor.active_tags or {}) do
      if type(tag) == "number" and tag > 0 then
        visible[(monitor.name or "") .. ":" .. tostring(tag)] = true
      end
    end
    if monitor.active then
      focused = monitor
    end
  end
  focused = focused or all[1]
  local area = { x = 0, y = 0, w = 1280, h = 720 }
  local workspace = nil
  if focused then
    area = { x = focused.x or 0, y = focused.y or 0, w = focused.width or 1280, h = focused.height or 720 }
    workspace = { monitor = focused.name, tag = firstTag(focused.active_tags) }
  end
  return { visible = visible, area = area, workspace = workspace }
end

-- The overview shows every tag at once and reports tag 0 as the active one;
-- nothing reads as on screen then, so the corner window is left alone until
-- it closes.
function M.inOverview(monitors)
  for _, monitor in ipairs(list(monitors, "monitors")) do
    local tags = monitor.active_tags
    if type(tags) == "table" and #tags == 1 and tags[1] == 0 then
      return true
    end
  end
  return false
end

-- A global window shows on every tag of its monitor, but Mango still reports
-- the tag it came from, which is hidden once another tag is viewed. Read as
-- it is, it would look carried off, and be carried back on each tag switch
-- (taking the focus each time). So a global window on a monitor that is
-- there counts as on that monitor's active tag.
function M.settleGlobal(monitors, windows)
  local active = {}
  for _, monitor in ipairs(list(monitors, "monitors")) do
    local tag = firstTag(monitor.active_tags)
    if monitor.name and tag then
      active[monitor.name] = tag
    end
  end
  for _, window in ipairs(windows) do
    local tag = window.sticky and active[window.monitor]
    if tag then
      window.ws = window.monitor .. ":" .. tostring(tag)
    end
  end
  return windows
end

function M.homeOf(window)
  return { ws = window.ws, monitor = window.monitor, tag = window.tag }
end

-- ── Commands ─────────────────────────────────────────────────────────────────
--
-- A step is a list of dispatches for one client, sent one `mmsg dispatch`
-- each by a small shell loop, so a whole step is one process and still
-- finishes after the service has gone (exitDetached).

local STEPS = [[
id=$1
shift
for d; do
  out=$(mmsg dispatch "$d" "client,$id" 2>&1)
  case $out in *error*) echo "$d: $out" ;; esac
done
]]

local function run(id, dispatches, done)
  if #dispatches == 0 then
    if done then
      done()
    end
    return
  end
  local argv = { "sh", "-c", STEPS, "sh", id }
  for _, d in ipairs(dispatches) do
    table.insert(argv, d)
  end
  local accepted = noctalia.runAsync(argv, function(result)
    local output = noctalia.string.trim((result.stdout or "") .. (result.stderr or ""))
    if result.exitCode ~= 0 or output ~= "" then
      noctalia.log("haeubchen: mmsg said: " .. output)
    end
    if done then
      done()
    end
  end)
  if not accepted and done then
    done()
  end
end

-- movewin takes a plain number as absolute and a leading +/- as relative, so
-- a negative target (a monitor left of the origin) is sent as a delta from
-- where the window is.
local function axis(target, current)
  target = math.floor(target)
  if target >= 0 then
    return tostring(target)
  end
  local delta = target - math.floor(current or 0)
  if delta >= 0 then
    return "+" .. tostring(delta)
  end
  return "-" .. tostring(-delta)
end

function M.placeDispatches(window, rect)
  return {
    string.format("movewin,%s,%s", axis(rect.x, window.x), axis(rect.y, window.y)),
    string.format("resizewin,%d,%d", math.max(1, math.floor(rect.w)), math.max(1, math.floor(rect.h))),
  }
end

function M.enterDispatches(window, rect)
  local out = {}
  if (window.fullscreen or 0) ~= 0 then
    table.insert(out, "togglefullscreen")
  end
  -- movewin floats a tiled window by itself.
  for _, d in ipairs(M.placeDispatches(window, rect)) do
    table.insert(out, d)
  end
  if not window.sticky then
    table.insert(out, "toggleglobal")
  end
  return out
end

-- `now` is the window as it is at this moment, nil if it could not be read.
function M.exitDispatches(t, now)
  local out = {}
  now = now or { sticky = true, floating = true, fullscreen = 0, x = 0, y = 0 }
  if now.sticky then
    table.insert(out, "toggleglobal")
  end
  local home = t.home or {}
  if type(home.tag) == "number" and home.tag > 0 and home.tag ~= now.tag then
    table.insert(out, "tagsilent," .. tostring(math.floor(home.tag)))
  end
  local orig = t.orig or {}
  if orig.floating then
    for _, d in ipairs(M.placeDispatches(now, orig)) do
      table.insert(out, d)
    end
  elseif now.floating then
    table.insert(out, "togglefloating")
  end
  if (orig.fullscreen or 0) ~= 0 and (now.fullscreen or 0) == 0 then
    table.insert(out, "togglefullscreen")
  end
  return out
end

-- ── Reading ──────────────────────────────────────────────────────────────────

-- Always calls `done` exactly once, nil on any failure, including a refused
-- runAsync: the service's queue waits on it.
local function readJson(args, done)
  local argv = { "mmsg" }
  for _, a in ipairs(args) do
    table.insert(argv, a)
  end
  local accepted = noctalia.runAsync(argv, function(result)
    if result.exitCode ~= 0 then
      return done(nil)
    end
    local value = noctalia.json.decode(result.stdout or "")
    if type(value) ~= "table" or value.error ~= nil then
      value = nil
    end
    done(value)
  end)
  if not accepted then
    done(nil)
  end
end

local function readClient(id, done)
  readJson({ "get", "client", id }, function(value)
    done(value and M.window(value) or nil)
  end)
end

function M.read(done)
  readJson({ "get", "all-monitors" }, function(monitors)
    if monitors == nil then
      return done(nil, nil)
    end
    readJson({ "get", "all-clients" }, function(clients)
      if clients == nil or M.inOverview(monitors) then
        return done(nil, nil)
      end
      done(M.screen(monitors), M.settleGlobal(monitors, M.windows(clients)))
    end)
  end)
end

function M.list(done)
  readJson({ "get", "all-clients" }, function(clients)
    done(M.windows(clients))
  end)
end

function M.active(done)
  readJson({ "get", "focusing-client" }, function(client)
    done(client and M.window(client) or nil)
  end)
end

function M.enter(window, rect, _screen, done)
  run(window.id, M.enterDispatches(window, rect), done)
end

-- A global window stays on its own monitor; this is only reached when that
-- monitor went away, so the window is sent to the focused monitor's tag.
function M.carry(window, rect, screen, done)
  local target = screen.workspace
  if type(target) ~= "table" or not safeMonitor(target.monitor) or type(target.tag) ~= "number" then
    return done()
  end
  local dispatches = { string.format("tagcrossmon,%d,%s", target.tag, target.monitor) }
  for _, d in ipairs(M.placeDispatches(window, rect)) do
    table.insert(dispatches, d)
  end
  run(window.id, dispatches, done)
end

function M.exit(t, done)
  readClient(t.id, function(now)
    run(t.id, M.exitDispatches(t, now), done)
  end)
end

-- Fire and forget, for onExit: no read first, so the state is assumed to be
-- what Häubchen left it in (global and floating, in the corner it placed it
-- in, which the relative moves back home start from).
function M.exitDetached(t)
  local placed = t.placed or {}
  local now = { sticky = true, floating = true, fullscreen = 0, x = placed.x or 0, y = placed.y or 0 }
  run(t.id, M.exitDispatches(t, now), nil)
end

-- Shows the home tag on the home monitor; plain `view` would switch the
-- tag on whichever monitor has the focus.
function M.focusHome(home)
  if home and type(home.tag) == "number" and home.tag > 0 then
    local tag = tostring(math.floor(home.tag))
    if safeMonitor(home.monitor) then
      noctalia.runAsync({ "mmsg", "dispatch", "viewcrossmon," .. tag .. "," .. home.monitor })
    else
      noctalia.runAsync({ "mmsg", "dispatch", "view," .. tag })
    end
  end
end

function M.close(id)
  noctalia.runAsync({ "mmsg", "dispatch", "killclient", "client," .. id })
end

-- ── Events ───────────────────────────────────────────────────────────────────
--
-- `watch all-clients` sends the whole client list on every change, so opens
-- and closes are found by comparing it with the one before.

-- `known` is { [id] = true } from the previous snapshot, nil before the
-- first. Returns the events and the new set.
function M.diffClients(known, value)
  local now, events = {}, {}
  for _, window in ipairs(M.windows(value)) do
    now[window.id] = true
    if known ~= nil and not known[window.id] then
      table.insert(events, { kind = "open", id = window.id, class = window.class })
    end
  end
  -- A window sent to the scratchpad is still there, only out of sight: it
  -- must not read as closed, or following it would end.
  for _, client in ipairs(list(value, "clients")) do
    local id = type(client) == "table" and M.id(client.id)
    if id and (client.is_scratchpad == true or client.is_namedscratchpad == true) then
      now[id] = true
    end
  end
  if known ~= nil then
    for id in pairs(known) do
      if not now[id] then
        table.insert(events, { kind = "close", id = id })
      end
    end
  end
  table.insert(events, { kind = "check" })
  return events, now
end

function M.available()
  local path = noctalia.getenv("MANGO_INSTANCE_SIGNATURE")
  return path ~= nil and path ~= "" and noctalia.fileExists(path)
end

local clientEvents, monitorEvents = nil, nil
local known = nil

function M.start(onEvent)
  local function parseClients(line)
    local value = noctalia.json.decode(line)
    if type(value) ~= "table" then
      return nil
    end
    local events
    events, known = M.diffClients(known, value)
    return events
  end
  local function parseMonitors(line)
    if noctalia.json.decode(line) == nil then
      return nil
    end
    return { kind = "check" }
  end
  clientEvents = stream.follow("mmsg watch all-clients", parseClients, onEvent)
  monitorEvents = stream.follow("mmsg watch all-monitors", parseMonitors, onEvent)
  local ok = clientEvents.listen()
  return monitorEvents.listen() and ok
end

function M.tick()
  if clientEvents ~= nil then
    clientEvents.tick()
    monitorEvents.tick()
  end
end

return M
