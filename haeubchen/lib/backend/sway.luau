--!nonstrict
-- sway, and Scroll, which speaks the same IPC through `scrollmsg`. Written
-- against sway's IPC (sway-ipc(7), sway(5)); not yet tested on a real sway or
-- Scroll session.
--
-- Commands go through `swaymsg` with `[con_id=N]` criteria, several chained
-- with commas so a whole step is one process. A floating window marked
-- `sticky` stays on screen across workspace switches on its output, which is
-- sway's version of a pin (Scroll's own `pin` is something else: it pins a
-- column to a screen edge). Events come from `swaymsg -t subscribe -m`, one
-- raw JSON object per line.
--
-- make() builds one backend per program: this file returns the sway one, with
-- `make` on it for lib/backend/scroll.luau.

local stream = require("./stream.luau")

local function make(program, name, socketVar)
  local M = { name = name, canPin = true, tools = { program } }

  -- sway container ids are integers. Only digits ever reach a command.
  function M.id(value)
    if type(value) == "number" then
      return tostring(math.floor(value))
    end
    if type(value) == "string" and string.match(value, "^%d+$") then
      return value
    end
    return nil
  end

  -- Workspace names go into commands inside double quotes, so a name that
  -- could close the quote is never used.
  local function quoted(name)
    if type(name) ~= "string" or name == "" or string.find(name, '["\\]') then
      return nil
    end
    return '"' .. name .. '"'
  end

  local function isWindow(node)
    local leaf = (node.nodes == nil or #node.nodes == 0) and (node.floating_nodes == nil or #node.floating_nodes == 0)
    return leaf and (node.type == "con" or node.type == "floating_con") and (node.pid ~= nil or node.app_id ~= nil or node.window_properties ~= nil)
  end

  local function collect(node, workspace, out)
    if node.type == "workspace" then
      workspace = node
    end
    if isWindow(node) and workspace ~= nil then
      local rect = node.rect or {}
      local id = M.id(node.id)
      if id ~= nil then
        table.insert(out, {
          id = id,
          title = node.name or "",
          class = node.app_id or (node.window_properties and node.window_properties.class) or "",
          ws = workspace.name,
          wsLabel = workspace.name,
          floating = node.type == "floating_con",
          sticky = node.sticky == true,
          fullscreen = node.fullscreen_mode or 0,
          x = rect.x or 0,
          y = rect.y or 0,
          w = rect.width or 0,
          h = rect.height or 0,
        })
      end
    end
    for _, child in ipairs(node.nodes or {}) do
      collect(child, workspace, out)
    end
    for _, child in ipairs(node.floating_nodes or {}) do
      collect(child, workspace, out)
    end
  end

  function M.windows(tree)
    local out = {}
    if type(tree) == "table" then
      collect(tree, nil, out)
    end
    -- The scratchpad is a workspace too, but nothing there is a stream you are
    -- watching; it is never on screen, so leave it out of the list.
    local kept = {}
    for _, window in ipairs(out) do
      if window.ws ~= "__i3_scratch" then
        table.insert(kept, window)
      end
    end
    return kept
  end

  -- A workspace's rect is its output minus bars and other exclusive zones.
  function M.screen(workspaces)
    local visible, focused = {}, nil
    for _, workspace in ipairs(workspaces or {}) do
      if workspace.visible then
        visible[workspace.name] = true
      end
      if workspace.focused then
        focused = workspace
      end
    end
    local rect = focused and focused.rect or { x = 0, y = 0, width = 1280, height = 720 }
    return {
      visible = visible,
      area = { x = rect.x, y = rect.y, w = rect.width, h = rect.height },
      workspace = focused and focused.name or nil,
    }
  end

  function M.homeOf(window)
    return { ws = window.ws }
  end

  -- ── Commands ─────────────────────────────────────────────────────────────────

  local function run(id, commands, done)
    local command = "[con_id=" .. id .. "] " .. table.concat(commands, ", ")
    local accepted = noctalia.runAsync({ program, command }, function(result)
      local output = (result.stdout or "") .. (result.stderr or "")
      if result.exitCode ~= 0 or string.find(output, '"success": *false') then
        noctalia.log("haeubchen: " .. program .. " said: " .. noctalia.string.trim(output))
      end
      if done then
        done()
      end
    end)
    if not accepted and done then
      done()
    end
  end

  local function placeCommands(rect)
    return {
      string.format("resize set width %d px height %d px", rect.w, rect.h),
      string.format("move absolute position %d %d", rect.x, rect.y),
    }
  end

  function M.enter(window, rect, _screen, done)
    local commands = {}
    if (window.fullscreen or 0) ~= 0 then
      table.insert(commands, "fullscreen disable")
    end
    table.insert(commands, "floating enable")
    for _, c in ipairs(placeCommands(rect)) do
      table.insert(commands, c)
    end
    table.insert(commands, "sticky enable")
    run(window.id, commands, done)
  end

  -- Sticky only holds within one output; when focus moves to another, the
  -- window is moved to that output's workspace.
  function M.carry(window, rect, screen, done)
    local target = quoted(screen.workspace)
    if target == nil then
      return done()
    end
    local commands = { "move container to workspace " .. target }
    for _, c in ipairs(placeCommands(rect)) do
      table.insert(commands, c)
    end
    table.insert(commands, "sticky enable")
    run(window.id, commands, done)
  end

  local function exitCommands(t)
    local commands = { "sticky disable" }
    local home = quoted(t.home and t.home.ws)
    if home ~= nil then
      table.insert(commands, "move container to workspace " .. home)
    end
    local orig = t.orig or {}
    if orig.floating then
      for _, c in ipairs(placeCommands(orig)) do
        table.insert(commands, c)
      end
    else
      table.insert(commands, "floating disable")
    end
    -- fullscreen_mode 2 is fullscreen across every output.
    if (orig.fullscreen or 0) == 2 then
      table.insert(commands, "fullscreen enable global")
    elseif (orig.fullscreen or 0) ~= 0 then
      table.insert(commands, "fullscreen enable")
    end
    return commands
  end

  function M.exit(t, done)
    run(t.id, exitCommands(t), done)
  end

  function M.exitDetached(t)
    noctalia.runAsync({ program, "[con_id=" .. t.id .. "] " .. table.concat(exitCommands(t), ", ") })
  end

  function M.focusHome(home)
    local ws = quoted(home and home.ws)
    if ws ~= nil then
      noctalia.runAsync({ program, "workspace " .. ws })
    end
  end

  function M.close(id)
    noctalia.runAsync({ program, "[con_id=" .. id .. "] kill" })
  end

  -- ── Reading ──────────────────────────────────────────────────────────────────

  -- Always calls `done` exactly once, nil on any failure, including a refused
  -- runAsync: the service's queue waits on it.
  local function readJson(kind, done)
    local accepted = noctalia.runAsync({ program, "-r", "-t", kind }, function(result)
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
    readJson("get_workspaces", function(workspaces)
      if workspaces == nil then
        return done(nil, nil)
      end
      readJson("get_tree", function(tree)
        if tree == nil then
          return done(nil, nil)
        end
        done(M.screen(workspaces), M.windows(tree))
      end)
    end)
  end

  function M.list(done)
    readJson("get_tree", function(tree)
      done(M.windows(tree))
    end)
  end

  function M.active(done)
    readJson("get_tree", function(tree)
      local focused = nil
      local function find(node)
        if node.focused and isWindow(node) then
          focused = M.id(node.id)
        end
        for _, child in ipairs(node.nodes or {}) do
          find(child)
        end
        for _, child in ipairs(node.floating_nodes or {}) do
          find(child)
        end
      end
      if tree ~= nil then
        find(tree)
      end
      for _, window in ipairs(M.windows(tree)) do
        if window.id == focused then
          return done(window)
        end
      end
      done(nil)
    end)
  end

  -- ── Events ───────────────────────────────────────────────────────────────────

  function M.parseEvent(line)
    local event = noctalia.json.decode(line)
    if type(event) ~= "table" then
      return nil
    end
    local container = event.container
    if type(container) == "table" then
      if event.change == "new" then
        return { kind = "open", id = M.id(container.id), class = container.app_id or (container.window_properties and container.window_properties.class) }
      elseif event.change == "close" then
        return { kind = "close", id = M.id(container.id) }
      end
    end
    return { kind = "check" }
  end

  function M.available()
    local path = noctalia.getenv(socketVar)
    return path ~= nil and path ~= "" and noctalia.fileExists(path)
  end

  local events = nil

  function M.start(onEvent)
    events = stream.follow(program .. [[ -r -m -t subscribe '["workspace","window","output"]']], M.parseEvent, onEvent)
    return events.listen()
  end

  function M.tick()
    if events ~= nil then
      events.tick()
    end
  end

  return M
end

-- sway, but not Scroll: Scroll sets SWAYSOCK too, for compatibility, and is
-- picked before this by its own SCROLLSOCK.
local M = make("swaymsg", "sway", "SWAYSOCK")
local swayAvailable = M.available
function M.available()
  return swayAvailable() and noctalia.getenv("SCROLLSOCK") == nil
end
M.make = make
return M
