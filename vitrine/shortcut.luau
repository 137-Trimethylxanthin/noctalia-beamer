--!nonstrict
-- [[shortcut]]: a control-center tile that steps to the next layout, for
-- when the laptop is already on the desk and the launcher is one keystroke
-- too many. It shows what the control service last read, so it follows
-- switches made anywhere. Add it under Settings -> Control Center shortcuts.

local function render(status)
  local on = status ~= nil and status.available and status.mode ~= nil
  shortcut.setLabel(if on then noctalia.tr("mode." .. status.mode .. ".title") else noctalia.tr("title"))
  shortcut.setIcon("devices")
  shortcut.setActive(on and status.mode ~= "internal")
  shortcut.setEnabled(on)
end

noctalia.state.watch("status", render)
render(noctalia.state.get("status"))

function onClick()
  noctalia.state.set("request", { op = "cycle", n = noctalia.nowMs() })
end

function onRightClick()
  noctalia.state.set("request", { op = "refresh", n = noctalia.nowMs() })
end
