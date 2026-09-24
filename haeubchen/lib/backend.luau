--!nonstrict
-- Picks the compositor backend for this session.
--
-- Every backend speaks the neutral model of lib/pip.luau and offers:
--
--   name, canPin, tools            what it is, whether it can pin, what it runs
--   available()                    is this that compositor's session
--   start(onEvent)                 follow compositor events; onEvent gets
--                                  { kind = "check" | "open" | "close", id?, class? }
--   read(done(screen, windows))    one consistent look at the screen
--   list(done(windows))            just the windows, for the launcher
--   active(done(window))           the focused window
--   homeOf(window)                 what to remember to put it back ({ ws, ... })
--   enter(window, rect, screen, done)
--   carry(window, rect, screen, done)
--   exit(t, done), exitDetached(t) t = { id, home, orig }
--   focusHome(home), close(id)
--   id(value)                      normalize and validate a window id
--   tick()                         called every few seconds; restarts an event
--                                  stream that ended
--
-- Every read and every command calls its `done` exactly once, also when the
-- command could not be started: the service's queue waits on it.
--
-- Hyprland is checked first: under a nested session the other variables can
-- leak through, and it is the tested one. Scroll sets SWAYSOCK too, so it
-- comes before sway.

local BACKENDS = {
  require("./backend/hyprland.luau"),
  require("./backend/scroll.luau"),
  require("./backend/sway.luau"),
  require("./backend/niri.luau"),
  require("./backend/mango.luau"),
}

local M = {}

-- The backend for this session and the tools it is missing, or nil.
function M.pick()
  for _, backend in ipairs(BACKENDS) do
    if backend.available() then
      local missing = {}
      for _, tool in ipairs(backend.tools) do
        if not noctalia.commandExists(tool) then
          table.insert(missing, tool)
        end
      end
      return backend, missing
    end
  end
  return nil, {}
end

-- What to call the compositor when no backend fits, checked the way Noctalia
-- itself detects it. These can move no window from outside: labwc, dwl and
-- Triad have no IPC for it, Umbriel moves only the focused window.
function M.compositorName()
  local env = noctalia.getenv
  if env("UMBRIEL_SOCKET") then
    return "Umbriel"
  elseif env("LABWC_PID") then
    return "labwc"
  elseif env("TRIAD_SOCKET") or string.find(string.lower(env("RIVER_WM") or ""), "triad", 1, true) then
    return "Triad"
  end
  local desktop = env("XDG_CURRENT_DESKTOP")
  if desktop ~= nil and string.match(desktop, "^[%w%-_:. ]+$") then
    return (string.gsub(desktop, ":.*$", ""))
  end
  return nil
end

return M
