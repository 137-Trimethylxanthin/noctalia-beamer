--!nonstrict
-- [[shortcut]]: a control-center tile that steps to the next layout, for
-- when the laptop is already on the desk and the launcher is one keystroke
-- too many. Add it under Settings -> Control Center shortcuts.

local display = require("./lib/display.luau")

local function render(info)
  shortcut.setLabel(if info == nil then noctalia.tr("title") else noctalia.tr("mode." .. info.mode .. ".title"))
  shortcut.setIcon("devices")
  shortcut.setActive(info ~= nil and info.mode ~= "internal")
  shortcut.setEnabled(info ~= nil)
end

local function refresh()
  display.read(render)
end

refresh()

function onClick()
  display.read(function(info)
    if info == nil or #info.external == 0 then
      render(info)
      return noctalia.notify(noctalia.tr("title"), noctalia.tr("nothing-attached"))
    end
    local target = display.nextMode(info.mode)
    display.apply(target, function(ok, reason)
      if ok then
        noctalia.notify(noctalia.tr("title"), noctalia.tr("mode." .. target .. ".title"))
      elseif reason == "no-external" then
        noctalia.notify(noctalia.tr("title"), noctalia.tr("nothing-attached"))
      else
        noctalia.notifyError(noctalia.tr("title"), noctalia.tr("failed"))
      end
      refresh()
    end)
  end)
end

function onRightClick()
  refresh()
end
