--!nonstrict
-- [[launcher_provider]]: type /beam to pick a monitor layout.

local display = require("./lib/display.luau")

local ROWS = {
  { id = "extend",   glyph = "layout-columns" },
  { id = "mirror",   glyph = "copy" },
  { id = "external", glyph = "device-desktop" },
  { id = "internal", glyph = "device-laptop" },
}

local current = nil
local externalCount = 0
local hyprland = true

local function matches(row, filter)
  if filter == "" then
    return true
  end
  -- Match the translated title and the mode id, so both "duplicate" and
  -- "mirror" find the same row whatever the user's language is.
  return string.find(string.lower(noctalia.tr("mode." .. row.id .. ".title")), filter, 1, true) ~= nil
    or string.find(row.id, filter, 1, true) ~= nil
end

local function build(filter)
  if not hyprland then
    return { { id = "", title = noctalia.tr("unavailable.title"), subtitle = noctalia.tr("unavailable.subtitle"), glyph = "plug-off" } }
  end

  local rows = {}
  for _, row in ipairs(ROWS) do
    if matches(row, filter) then
      local subtitle = noctalia.tr("mode." .. row.id .. ".subtitle")
      if row.id == current then
        subtitle = noctalia.tr("active") .. "  ·  " .. subtitle
      elseif externalCount == 0 and row.id ~= "internal" then
        subtitle = noctalia.tr("nothing-attached")
      end
      table.insert(rows, {
        id = row.id,
        title = noctalia.tr("mode." .. row.id .. ".title"),
        subtitle = subtitle,
        glyph = row.glyph,
      })
    end
  end
  return rows
end

function onQuery(query)
  local filter = string.lower(noctalia.string.trim(query))

  -- Draw from what is already known so the list does not flicker while
  -- hyprctl is asked what is actually plugged in.
  launcher.setResults(query, build(filter))

  display.read(function(info)
    if info == nil then
      hyprland = false
      return launcher.setResults(query, build(filter))
    end
    hyprland = true
    if info.mode ~= current or #info.external ~= externalCount then
      current = info.mode
      externalCount = #info.external
      launcher.setResults(query, build(filter))
    end
  end)
end

function onActivate(id)
  if id == "" then
    return
  end
  current = id
  display.apply(id, function(ok, reason)
    if ok then
      return noctalia.notify(noctalia.tr("title"), noctalia.tr("mode." .. id .. ".title"))
    end
    if reason == "no-external" then
      noctalia.notify(noctalia.tr("title"), noctalia.tr("nothing-attached"))
    else
      noctalia.notifyError(noctalia.tr("title"), noctalia.tr("failed"))
    end
  end)
end
