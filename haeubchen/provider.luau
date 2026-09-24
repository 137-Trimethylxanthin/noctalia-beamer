--!nonstrict
-- [[launcher_provider]]: /pip.
--
--   /pip                     what is being followed, plus every window to follow
--   /pip twit                the window list, filtered
--   /pip twitch <channel>    open it in the player (also: kick <channel>, yt <id>, a URL)
--
-- The work happens in the watch service; this only files requests with it.

local pip = require("./lib/pip.luau")
local backend = require("./lib/backend.luau").pick()

local windows = {}
local icons = {}

local function request(op, fields)
  local value = fields or {}
  value.op = op
  -- The nonce makes a repeated request a change, so watch() fires for it.
  value.n = noctalia.nowMs()
  noctalia.state.set("request", value)
end

local function iconFor(class)
  if class == nil or class == "" then
    return nil
  end
  if icons[class] == nil then
    icons[class] = noctalia.appIconPath(class, 32) or false
  end
  return icons[class] or nil
end

local function statusRows(filter)
  local status = noctalia.state.get("status") or { mode = "idle" }
  if status.mode == "idle" or filter ~= "" then
    return {}
  end
  local name = status.title or status.class or ""
  if status.auto then
    name = noctalia.tr("row.auto", { title = name })
  end
  local rows = {}
  if status.mode == "hidden" then
    table.insert(rows, { id = "toggle", title = noctalia.tr("row.show.title"), subtitle = name, glyph = "picture-in-picture-on", score = 300 })
  else
    table.insert(rows, { id = "toggle", title = noctalia.tr("row.hide.title"), subtitle = name, glyph = "picture-in-picture-off", score = 300 })
  end
  table.insert(rows, { id = "back", title = noctalia.tr("row.back.title"), subtitle = name, glyph = "arrow-back-up", score = 299 })
  table.insert(rows, { id = "stop", title = noctalia.tr("row.stop.title"), subtitle = name, glyph = "player-stop", score = 298 })
  if status.custom then
    table.insert(rows, { id = "reset", title = noctalia.tr("row.reset.title"), subtitle = noctalia.tr("row.reset.subtitle"), glyph = "arrows-minimize", score = 297 })
  end
  return rows
end

local function build(query)
  local text = noctalia.string.trim(query)
  local rows = {}

  local url = pip.parsePlayable(text)
  if url ~= nil then
    table.insert(rows, {
      id = "play:" .. url,
      title = noctalia.tr("row.play.title"),
      subtitle = url,
      glyph = "player-play",
      score = 400,
    })
    return rows
  end

  local filter = string.lower(text)
  for _, row in ipairs(statusRows(filter)) do
    table.insert(rows, row)
  end

  local followed = (noctalia.state.get("status") or {}).id
  for _, window in ipairs(windows) do
    if window.id ~= followed then
      local label = window.class .. " " .. window.title
      local score = 0
      if filter ~= "" then
        score = noctalia.fuzzyScore(filter, label)
      end
      if score ~= nil then
        table.insert(rows, {
          id = "follow:" .. window.id,
          title = if window.title ~= "" then window.title else window.class,
          subtitle = noctalia.tr("row.follow.subtitle", { class = window.class, workspace = tostring(window.wsLabel or "?") }),
          icon = iconFor(window.class),
          glyph = "app-window",
          score = score + pip.streamScore(window) * 100,
        })
      end
    end
  end

  if #rows == 0 then
    if backend == nil then
      table.insert(rows, { id = "", title = noctalia.tr("unsupported.title"), subtitle = noctalia.tr("unsupported.subtitle"), glyph = "plug-off" })
    else
      table.insert(rows, { id = "", title = noctalia.tr("row.empty.title"), subtitle = noctalia.tr("row.empty.subtitle"), glyph = "picture-in-picture" })
    end
  end
  return rows
end

function onQuery(query)
  launcher.setResults(query, build(query))
  if backend == nil then
    return
  end
  backend.list(function(list)
    if list ~= nil then
      windows = list
      launcher.setResults(query, build(query))
    end
  end)
end

function onActivate(id)
  if id == "" then
    return
  end
  local kind, rest = string.match(id, "^(%a+):(.+)$")
  if kind == "follow" then
    request("follow", { id = rest })
  elseif kind == "play" then
    request("play", { url = rest })
  else
    request(id)
  end
end
