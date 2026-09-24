-- Häubchen's half of the player. Loaded into mpv with --script when
-- Häubchen opens a stream (see watch.luau). Runs inside mpv, not Noctalia.
--
-- Makes the player behave like a browser's picture-in-picture:
--
--   click              pause / play
--   drag               move the window
--   scroll             volume
--   double-click       in the corner: back to the stream's workspace
--                      at home: fullscreen, as mpv normally does
--
-- and swaps mpv's on-screen controller for its "box" layout while the window
-- is in the corner: one floating panel with a large play button that shows
-- on hover, instead of a thin bar that would be unreadable at 500 pixels wide.
--
-- Häubchen tells it where the window is through the property
-- user-data/haeubchen/pip, set over mpv's IPC socket.

local mp = require("mp")

local PLUGIN = "137-trimethylxanthin/haeubchen:watch"
local DRAG_THRESHOLD = 6

local inCorner = false

local CORNER_OSC = {
  "osc-layout=box",
  "osc-vidscale=no",
  "osc-scalewindowed=0.8",
  "osc-hidetimeout=1200",
  "osc-deadzonesize=0",
  "osc-boxalpha=60",
}
local HOME_OSC = {
  "osc-layout=bottombar",
  "osc-vidscale=yes",
  "osc-scalewindowed=1",
  "osc-hidetimeout=500",
  "osc-deadzonesize=0.5",
  "osc-boxalpha=80",
}

local function setOsc(options)
  for _, option in ipairs(options) do
    mp.commandv("change-list", "script-opts", "append", option)
  end
end

mp.observe_property("user-data/haeubchen/pip", "native", function(_, value)
  inCorner = value == true
  setOsc(inCorner and CORNER_OSC or HOME_OSC)
end)

-- A press that moves further than DRAG_THRESHOLD becomes a window drag; one
-- that does not is a click. mpv's own drag-anywhere is taken over by this
-- binding, so the drag is started by hand with begin-vo-dragging.
local press = nil

local function mousePos()
  local pos = mp.get_property_native("mouse-pos") or {}
  return pos.x or 0, pos.y or 0
end

mp.add_key_binding("MBTN_LEFT", "haeubchen-click", function(event)
  -- "press" is a down and up in one: a click that cannot have been a drag.
  if event.event == "press" then
    mp.commandv("cycle", "pause")
  elseif event.event == "down" then
    local x, y = mousePos()
    press = { x = x, y = y, dragged = false }
  elseif event.event == "up" then
    if press ~= nil and not press.dragged then
      mp.commandv("cycle", "pause")
    end
    press = nil
  end
end, { complex = true })

mp.observe_property("mouse-pos", "native", function(_, pos)
  if press == nil or press.dragged or pos == nil then
    return
  end
  if math.abs((pos.x or 0) - press.x) > DRAG_THRESHOLD or math.abs((pos.y or 0) - press.y) > DRAG_THRESHOLD then
    press.dragged = true
    mp.commandv("begin-vo-dragging")
  end
end)

mp.add_key_binding("MBTN_LEFT_DBL", "haeubchen-double", function()
  if inCorner then
    mp.command_native_async({
      name = "subprocess",
      args = { "noctalia", "msg", "plugin", PLUGIN, "all", "back" },
      playback_only = false,
    }, function() end)
  else
    mp.commandv("cycle", "fullscreen")
  end
end)

mp.add_key_binding("WHEEL_UP", "haeubchen-louder", function()
  mp.commandv("add", "volume", "5")
end)

mp.add_key_binding("WHEEL_DOWN", "haeubchen-quieter", function()
  mp.commandv("add", "volume", "-5")
end)
