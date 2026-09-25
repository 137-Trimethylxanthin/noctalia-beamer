--!nonstrict
-- [[shortcut]]: a control-center tile for the glow. Lit while it is on, and
-- while uv is still fetching pywayland on a first run. Click toggles it;
-- right-click flashes, to try the flash look. Add it under Settings ->
-- Control Center shortcuts.

local function render(status)
  status = status or {}
  shortcut.setLabel(noctalia.tr("title"))
  shortcut.setIcon("bulb", "bulb-off")
  shortcut.setActive(status.mode == "on" or status.mode == "starting")
  shortcut.setEnabled(status.available ~= false)
end

noctalia.state.watch("status", render)
render(noctalia.state.get("status"))

function onClick()
  noctalia.state.set("request", { op = "toggle", n = noctalia.nowMs() })
end

function onRightClick()
  noctalia.state.set("request", { op = "flash", n = noctalia.nowMs() })
end
