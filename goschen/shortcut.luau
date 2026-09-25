--!nonstrict
-- [[shortcut]]: a control-center tile for Do Not Disturb, the quiet kind. Lit
-- while it is on. Click toggles it; the service mutes and unmutes the apps.
-- Right-click opens the notifications, like the built-in Do Not Disturb tile
-- it can stand in for. Add it under Settings -> Control Center shortcuts.

local function render(status)
  status = status or {}
  shortcut.setLabel(noctalia.tr("title"))
  shortcut.setIcon("bell-off", "bell")
  shortcut.setActive(status.dnd == true)
  -- Always usable: switching Do Not Disturb needs nothing but Noctalia, even
  -- where pactl is missing and no app can be muted.
  shortcut.setEnabled(true)
end

noctalia.state.watch("status", render)
render(noctalia.state.get("status"))

function onClick()
  noctalia.state.set("request", { op = "toggle", n = noctalia.nowMs() })
end

function onRightClick()
  noctalia.runAsync({ "noctalia", "msg", "panel-toggle", "control-center", "notifications" })
end
