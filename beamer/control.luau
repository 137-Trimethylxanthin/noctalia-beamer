--!nonstrict
-- [[service]]: the IPC surface, so a compositor keybind can switch layouts
-- without opening the launcher.
--
--   noctalia msg plugin 137-trimethylxanthin/beamer:control all cycle
--   noctalia msg plugin 137-trimethylxanthin/beamer:control all set mirror

local display = require("./lib/display.luau")

local function announce(mode, ok, reason)
  if ok then
    return noctalia.notify(noctalia.tr("title"), noctalia.tr("mode." .. mode .. ".title"))
  end
  if reason == "no-external" then
    noctalia.notify(noctalia.tr("title"), noctalia.tr("nothing-attached"))
  else
    noctalia.notifyError(noctalia.tr("title"), noctalia.tr("failed"))
  end
end

local function switch(mode)
  display.apply(mode, function(ok, reason)
    announce(mode, ok, reason)
  end)
end

function onIpc(event, payload)
  if event == "cycle" then
    display.read(function(info)
      if info == nil then
        return noctalia.notifyError(noctalia.tr("title"), noctalia.tr("unavailable.subtitle"))
      end
      -- Nothing plugged in means every step of the cycle but one is a no-op,
      -- so say so once instead of walking the user through four refusals.
      if #info.external == 0 then
        return noctalia.notify(noctalia.tr("title"), noctalia.tr("nothing-attached"))
      end
      switch(display.nextMode(info.mode))
    end)
  elseif event == "set" and type(payload) == "string" then
    for _, mode in ipairs(display.MODES) do
      if mode == payload then
        return switch(mode)
      end
    end
    noctalia.log("beamer: unknown mode '" .. payload .. "'")
  end
end
