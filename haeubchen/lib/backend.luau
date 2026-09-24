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
--
-- Hyprland is checked first: under a nested session the other variables can
-- leak through, and it is the tested one.

local BACKENDS = {
  require("./backend/hyprland.luau"),
  require("./backend/sway.luau"),
  require("./backend/niri.luau"),
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

return M
