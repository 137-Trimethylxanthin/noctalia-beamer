--!nonstrict
-- [[launcher_provider]]: type /display to pick a monitor layout. The control
-- service reads the monitors and does the switching; this only shows what it
-- published and asks it.

local ROWS = {
  { id = "extend",   glyph = "layout-columns" },
  { id = "mirror",   glyph = "copy" },
  { id = "external", glyph = "device-desktop" },
  { id = "internal", glyph = "device-laptop" },
}

local lastQuery = ""

local function matches(row, filter)
  if filter == "" then
    return true
  end
  -- Match the translated title and the mode id, so both "duplicate" and
  -- "mirror" find the same row whatever the user's language is.
  return string.find(string.lower(noctalia.tr("mode." .. row.id .. ".title")), filter, 1, true) ~= nil
    or string.find(row.id, filter, 1, true) ~= nil
end

local WHY = {
  ["no-external"] = "nothing-attached",
  ["lid-closed"] = "lid-closed",
  ["no-mirror"] = "no-mirror",
}

local function build(filter)
  local status = noctalia.state.get("status")
  if status == nil then
    return {}
  end
  if not status.available then
    return { { id = "", title = noctalia.tr("unavailable.title"), subtitle = noctalia.tr("unavailable.subtitle"), glyph = "plug-off" } }
  end
  local rows = {}
  for _, row in ipairs(ROWS) do
    if matches(row, filter) then
      local subtitle = noctalia.tr("mode." .. row.id .. ".subtitle")
      local allowed = status.allowed and status.allowed[row.id]
      if row.id == status.mode then
        subtitle = noctalia.tr("active") .. "  ·  " .. subtitle
      elseif allowed ~= true and WHY[allowed] then
        subtitle = noctalia.tr(WHY[allowed])
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

local function render()
  launcher.setResults(lastQuery, build(string.lower(noctalia.string.trim(lastQuery))))
end

-- Every new reading redraws the latest query, so the Active marker follows
-- what is really on.
noctalia.state.watch("status", function()
  render()
end)

function onQuery(query)
  lastQuery = query
  render()
  noctalia.state.set("request", { op = "refresh", n = noctalia.nowMs() })
end

function onActivate(id)
  if id == "" then
    return
  end
  noctalia.state.set("request", { op = "set", mode = id, n = noctalia.nowMs() })
end
