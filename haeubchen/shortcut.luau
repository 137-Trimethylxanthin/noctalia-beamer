--!nonstrict
-- [[shortcut]]: a control-center tile that hides and shows the corner player.
-- Lit while it is following something and not hidden. Add it under
-- Settings -> Control Center shortcuts.

local function render(status)
  status = status or { mode = "idle" }
  local following = status.mode ~= "idle"
  shortcut.setLabel(if following then (status.class or noctalia.tr("title")) else noctalia.tr("title"))
  shortcut.setIcon("picture-in-picture-on", "picture-in-picture-off")
  shortcut.setActive(following and status.mode ~= "hidden")
  shortcut.setEnabled(following)
end

noctalia.state.watch("status", render)
render(noctalia.state.get("status"))

function onClick()
  noctalia.state.set("request", { op = "toggle", n = noctalia.nowMs() })
end

function onRightClick()
  noctalia.state.set("request", { op = "back", n = noctalia.nowMs() })
end
