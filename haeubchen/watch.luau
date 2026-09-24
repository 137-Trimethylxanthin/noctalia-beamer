--!nonstrict
-- [[service]]: follows one window and moves it into the corner whenever its
-- workspace leaves the screen.
--
-- The compositor is behind lib/backend (Hyprland, sway, niri); this file only
-- decides. On anything that can change what is on screen it takes one look
-- through the backend and asks lib/pip what to do.
--
-- Every change to the window is a job on one queue, run strictly one after
-- another: a check, a hide, a stop. Without that, a hide could land between a
-- check reading "pinned in the corner" and acting on it. A check that is
-- already waiting in the queue is not queued twice, which is all the
-- debouncing a workspace switch (several events) needs.
--
-- The launcher and the tile talk to it through noctalia.state "request"; a
-- keybind talks to it through IPC:
--
--   noctalia msg plugin 137-trimethylxanthin/haeubchen:watch all window   # PiP on/off for the focused window
--   noctalia msg plugin 137-trimethylxanthin/haeubchen:watch all toggle   # hide / show
--   noctalia msg plugin 137-trimethylxanthin/haeubchen:watch all stop

local pip = require("./lib/pip.luau")
local backend, missing = require("./lib/backend.luau").pick()

-- { id, mode, home, orig, title, class, spawned, auto }
-- Kept in noctalia.state as well, so a hot reload picks up where it left off.
local target = noctalia.state.get("target")
-- Windows the user stopped following; auto-follow leaves them alone.
local declined = noctalia.state.get("declined") or {}
-- A player launched from /pip that has not mapped a window yet.
local awaiting = nil

-- ── The corner window's own size and place ───────────────────────────────────
--
-- Drag or resize the corner window and it comes back that way, relative to
-- the screen (lib/pip toRelative). Kept on disk across restarts; cleared by
-- "reset" or by changing the corner, size or margin setting.

local function geometryPath()
  local dir = noctalia.pluginDataDir()
  return dir and (dir .. "/geometry.json") or nil
end

local function loadGeometry()
  local path = geometryPath()
  local raw = path and noctalia.readFile(path)
  local value = raw and noctalia.json.decode(raw)
  if type(value) == "table" and value.w and value.h and value.x and value.y then
    return value
  end
  return nil
end

local custom = loadGeometry()

local function saveGeometry()
  local path = geometryPath()
  if path == nil then
    return
  end
  if custom == nil then
    if noctalia.fileExists(path) then
      noctalia.removeFile(path)
    end
  else
    noctalia.writeFile(path, noctalia.json.encode(custom))
  end
end

local function layoutKey()
  return tostring(noctalia.getConfig("corner")) .. "|" .. tostring(noctalia.getConfig("size")) .. "|" .. tostring(noctalia.getConfig("margin"))
end
local lastLayout = layoutKey()

-- ── Talking to the player ────────────────────────────────────────────────────
--
-- Häubchen's own mpv gets mpv/haeubchen.lua (click to pause, big controls in
-- the corner) and an IPC socket, through which it is told whether it is in
-- the corner right now.

local function playerSocket()
  local runtime = noctalia.getenv("XDG_RUNTIME_DIR")
  if runtime == nil or not string.match(runtime, "^[%w/_%-.]+$") then
    return nil
  end
  return runtime .. "/haeubchen-mpv.sock"
end

local function tellPlayer(inCorner)
  if target == nil or not target.spawned then
    return
  end
  local socket = playerSocket()
  if socket == nil or not noctalia.fileExists(socket) or not noctalia.commandExists("socat") then
    return
  end
  local message = string.format('{"command":["set_property","user-data/haeubchen/pip",%s]}', inCorner and "true" or "false")
  noctalia.runAsync(string.format("printf '%%s\\n' '%s' | socat - UNIX-CONNECT:'%s'", message, socket))
end

-- The extra mpv arguments, when the player command is mpv.
local function mpvExtras(argv)
  local program = string.match(argv[1], "([^/]+)$")
  if program ~= "mpv" then
    return
  end
  local socket = playerSocket()
  if socket ~= nil then
    table.insert(argv, 2, "--input-ipc-server=" .. socket)
  end
  local dir = noctalia.pluginDir()
  local script = dir and (dir .. "/mpv/haeubchen.lua")
  if script ~= nil and noctalia.fileExists(script) then
    table.insert(argv, 2, "--script=" .. script)
  end
end

local function publish()
  noctalia.state.set("target", target)
  noctalia.state.set("declined", declined)
  if target == nil then
    noctalia.state.set("status", { mode = "idle", backend = backend and backend.name, custom = custom ~= nil })
  else
    noctalia.state.set("status", {
      mode = target.mode,
      id = target.id,
      title = target.title,
      class = target.class,
      auto = target.auto,
      backend = backend and backend.name,
      custom = custom ~= nil,
    })
  end
end

local function say(key, subst)
  noctalia.notify(noctalia.tr("title"), noctalia.tr(key, subst))
end

local function autoOn()
  return noctalia.getConfig("auto_follow") == true
end

-- ── The queue ────────────────────────────────────────────────────────────────

local queue, running, checkQueued = {}, false, false

local function pump()
  if running or #queue == 0 then
    return
  end
  running = true
  local job = table.remove(queue, 1)
  job(function()
    running = false
    pump()
  end)
end

local function enqueue(job)
  table.insert(queue, job)
  pump()
end

local function cornerRect(screen)
  if custom ~= nil then
    return pip.fromRelative(custom, screen.area)
  end
  return pip.corner(screen.area, noctalia.getConfig("corner"), noctalia.getConfig("size"), noctalia.getConfig("margin"))
end

-- If the user dragged or resized the corner window since Häubchen placed it,
-- remember where it is now.
local function capture(window, screen)
  if target == nil or target.mode ~= "pip" or window == nil or screen == nil then
    return
  end
  local stillInCorner = if backend.canPin then window.sticky else window.floating
  if not stillInCorner or not pip.moved(window, target.placed) then
    return
  end
  local rect = { x = window.x, y = window.y, w = window.w, h = window.h }
  custom = pip.toRelative(rect, screen.area)
  target.placed = rect
  saveGeometry()
end

-- Runs `fn` after one fresh look, so a drag made since the last check is not
-- lost when the window is about to be put home.
local function withCapture(fn)
  backend.read(function(screen, windows)
    if screen ~= nil and target ~= nil then
      capture(pip.findWindow(windows, target.id), screen)
    end
    fn()
  end)
end

local function begin(window, how)
  target = {
    id = window.id,
    mode = "home",
    spawned = how == "spawned",
    auto = how == "auto",
    title = window.title,
    class = window.class,
  }
  declined[window.id] = nil
  publish()
  say(if how == "auto" then "following-auto" else "following", { title = if window.title ~= "" then window.title else window.class })
end

-- ── The check ────────────────────────────────────────────────────────────────

local function checkJob(done)
  checkQueued = false
  if target == nil and not autoOn() then
    return done()
  end

  backend.read(function(screen, windows)
    if screen == nil then
      return done()
    end

    if target == nil then
      local candidate = pip.autoCandidate(windows, declined, noctalia.getConfig("player_class"))
      if candidate == nil or not autoOn() then
        return done()
      end
      begin(candidate, "auto")
    end

    local window = pip.findWindow(windows, target.id)
    capture(window, screen)
    local homeWs = target.home and target.home.ws
    local action = pip.decide(target.mode, homeWs, window, screen.visible, backend.canPin)

    if window ~= nil then
      target.title = window.title
      target.class = window.class
    end

    if action == "gone" then
      target = nil
      publish()
      return done()
    end

    -- An auto-followed browser whose tab moved off the stream is not a stream
    -- any more: let go of it (back home first if it is in the corner).
    if target.auto and pip.streamScore(window) < 2 and window.class ~= noctalia.getConfig("player_class") then
      local old = target
      target = nil
      publish()
      if old.mode == "pip" then
        return backend.exit(old, done)
      end
      return done()
    end

    if action == "enter" then
      -- The workspace it is on now is home, even if the user moved it there.
      target.home = backend.homeOf(window)
      target.orig = pip.snapshot(window)
      target.mode = "pip"
      target.placed = cornerRect(screen)
      publish()
      tellPlayer(true)
      return backend.enter(window, target.placed, screen, done)
    end

    if action == "carry" then
      target.placed = cornerRect(screen)
      publish()
      return backend.carry(window, target.placed, screen, done)
    end

    if action == "exit" then
      target.mode = "home"
      publish()
      tellPlayer(false)
      return backend.exit(target, done)
    end

    if action == "adopt" or action == "unhide" then
      target.mode = "home"
    end
    publish()
    done()
  end)
end

local function check()
  if backend == nil or checkQueued then
    return
  end
  if target == nil and not autoOn() then
    return
  end
  checkQueued = true
  enqueue(checkJob)
end

-- ── Commands ─────────────────────────────────────────────────────────────────

-- Lets go of the current window, putting it home if it is in the corner.
-- `remember` keeps auto-follow from grabbing it straight back.
local function release(remember, done)
  local old = target
  target = nil
  if old ~= nil and remember then
    declined[old.id] = true
  end
  publish()
  if old ~= nil and old.mode == "pip" then
    return backend.exit(old, done)
  end
  done()
end

local function follow(id, how)
  id = backend.id(id)
  if id == nil then
    return
  end
  enqueue(function(done)
    -- Already following it. Starting over would mark a window that is in the
    -- corner as home, and remember the corner size as its real one. A manual
    -- pick of an auto-followed window only makes it stick.
    if target ~= nil and target.id == id then
      if how ~= "auto" then
        target.auto = false
      end
      publish()
      return done()
    end
    release(false, function()
      backend.list(function(windows)
        local window = pip.findWindow(windows, id)
        if window ~= nil then
          begin(window, how)
        end
        done()
        check()
      end)
    end)
  end)
end

local function stop()
  enqueue(function(done)
    if target == nil then
      return done()
    end
    if target.spawned then
      local id = target.id
      target = nil
      publish()
      backend.close(id)
      return done()
    end
    if target.mode ~= "pip" then
      return release(true, done)
    end
    withCapture(function()
      release(true, done)
    end)
  end)
end

-- The keybind: PiP on for the focused window, or off if it is the one being
-- followed. Works for any window, stream or not.
local function windowToggle()
  backend.active(function(window)
    if window == nil then
      return
    end
    if target ~= nil and target.id == window.id then
      return stop()
    end
    follow(window.id, "manual")
  end)
end

-- Hide: put it home and keep it out of the corner until it is seen again or
-- shown. Show: straight back into the corner if its workspace is off screen.
local function toggle()
  enqueue(function(done)
    if target == nil then
      say("nothing")
      return done()
    end
    if target.mode == "hidden" then
      target.mode = "home"
      publish()
      done()
      return check()
    end
    if target.mode ~= "pip" then
      target.mode = "hidden"
      publish()
      return done()
    end
    withCapture(function()
      if target == nil then
        return done()
      end
      target.mode = "hidden"
      publish()
      tellPlayer(false)
      backend.exit(target, done)
    end)
  end)
end

-- A new corner or size applies right away if it is in the corner now.
local function reflow(resetGeometry)
  enqueue(function(done)
    if resetGeometry then
      custom = nil
      saveGeometry()
      publish()
    end
    if target == nil or target.mode ~= "pip" then
      done()
      return check()
    end
    target.mode = "home"
    backend.exit(target, function()
      done()
      check()
    end)
  end)
end

local function back()
  if target ~= nil then
    backend.focusHome(target.home)
  end
end

local function play(url)
  local argv = pip.playerArgv(noctalia.getConfig("player_command"), url)
  if argv == nil or not noctalia.commandExists(argv[1]) then
    return noctalia.notifyError(noctalia.tr("title"), noctalia.tr("no-player", { player = argv and argv[1] or "" }))
  end
  awaiting = { class = noctalia.getConfig("player_class"), since = os.time() }
  mpvExtras(argv)
  noctalia.runAsync(argv)
  say("opening", { url = url })
end

local function handle(request)
  if type(request) ~= "table" or backend == nil then
    return
  end
  local op = request.op
  if op == "follow" then
    if request.id == "active" then
      backend.active(function(window)
        if window then
          follow(window.id, "manual")
        end
      end)
    else
      follow(request.id, "manual")
    end
  elseif op == "window" then
    windowToggle()
  elseif op == "stop" then
    stop()
  elseif op == "toggle" then
    toggle()
  elseif op == "back" then
    back()
  elseif op == "reset" then
    reflow(true)
  elseif op == "play" and type(request.url) == "string" then
    play(request.url)
  end
end

-- ── Events ───────────────────────────────────────────────────────────────────

local function onEvent(event)
  if event.kind == "open" then
    if awaiting ~= nil and event.id ~= nil then
      if event.class == awaiting.class then
        awaiting = nil
        return follow(event.id, "spawned")
      end
      if os.time() - awaiting.since > 60 then
        awaiting = nil
      end
    end
    -- A new window, or one whose title changed: auto-follow wants to see it.
    return check()
  end
  if event.kind == "close" then
    if target ~= nil and event.id == target.id then
      target = nil
      publish()
    end
    if event.id ~= nil then
      declined[event.id] = nil
    end
    return check()
  end
  check()
end

if backend == nil then
  noctalia.log("haeubchen: no supported compositor (Hyprland, sway, niri); staying idle")
elseif #missing > 0 then
  noctalia.log("haeubchen: " .. backend.name .. " needs " .. table.concat(missing, ", ") .. "; staying idle")
  noctalia.notifyError(noctalia.tr("title"), noctalia.tr("missing", { tools = table.concat(missing, ", ") }))
  backend = nil
else
  backend.start(onEvent)
end

-- A slow safety net for anything the events miss. Two or three reads per
-- tick, and only while following something or watching for streams.
noctalia.setUpdateInterval(5000)
function update()
  if target == nil or target.mode ~= "hidden" then
    check()
  end
end

noctalia.state.watch("request", handle)

function onIpc(event, payload)
  if event == "follow" then
    handle({ op = "follow", id = if type(payload) == "string" and payload ~= "" then payload else "active" })
  elseif event == "play" and type(payload) == "string" then
    local url = pip.parsePlayable(payload)
    if url then
      play(url)
    end
  else
    handle({ op = event })
  end
end

-- A new corner, size or margin is an explicit choice, so it replaces a
-- dragged-to spot; other settings leave it alone.
function onConfigChanged()
  if backend == nil then
    return
  end
  local layout = layoutKey()
  local changed = layout ~= lastLayout
  lastLayout = layout
  reflow(changed)
end

-- Never leave a window pinned in the corner with nothing looking after it.
-- The entry is destroyed before the compositor answers, so this is
-- fire-and-forget, and the target stays in state as "home" for a reloaded
-- service to pick up.
function onExit(_signal, reason)
  if target == nil or backend == nil then
    return
  end
  if target.mode == "pip" then
    backend.exitDetached(target)
    target.mode = "home"
  end
  if reason == "reload" then
    noctalia.state.set("target", target)
  else
    noctalia.state.set("target", nil)
    noctalia.state.set("status", { mode = "idle" })
  end
end

publish()
