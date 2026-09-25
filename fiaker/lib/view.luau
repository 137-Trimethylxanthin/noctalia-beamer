--!nonstrict
-- The two views, as ui.* trees. Shared by the month widget, the day widget and
-- the melange panel so all three stay visually identical and there is one place
-- to change a color or a spacing.
--
-- Two host rules this file has to respect:
--
--   * Children are a TABLE, not varargs: ui.column(props, { a, b, c }).
--   * Colors are palette ROLE TOKENS ("primary", "error", "primary/0.6"), never
--     noctalia.getColor() - that is plugin API 31 and is not in Noctalia 5.1.0.
--     Role tokens resolve live against the active theme at every API level.
--
-- `tooltip` on a container (ui.column/ui.row/ui.box/ui.image) is API 32 and is
-- likewise absent from 5.1.0, so it is not used here. Unknown props are logged
-- and skipped, and the timeline re-renders every 30s, so using it would do
-- nothing except fill the log. ui.button's own tooltip predates 32 and is fine.

local date = require("./date.luau")
local model = require("./model.luau")
local layout = require("./layout.luau")

local M = {}

local CELL_H = 30
local DOT = 4

local function timePattern(): string
  local p = noctalia.timeFormat()
  return (p ~= nil and p ~= "") and p or "{:%H:%M}"
end

local function eventFill(ev, accent: string): string
  return (ev.color ~= nil and ev.color ~= "") and ev.color or accent
end

-- ── Month grid ───────────────────────────────────────────────────────────────

function M.monthTree(opts)
  local mondayFirst = opts.weekStart ~= "sunday"
  local accent = opts.accent or "primary"
  local cells = date.monthGrid(opts.year, opts.month, mondayFirst, opts.nowUnix)
  local counts = opts.counts or {}

  local header = {}
  for _, label in ipairs(date.weekdayHeaders(mondayFirst)) do
    table.insert(header, ui.column({ flexGrow = 1, align = "center" }, {
      ui.label({ text = label, fontSize = 10, color = "on_surface_variant" }),
    }))
  end

  local rows = { ui.row({ gap = 2 }, header) }

  for r = 0, 5 do
    local cols = {}
    for c = 1, 7 do
      local cell = cells[r * 7 + c]
      local selected = (cell.iso == opts.selectedIso)
      local n = counts[cell.iso] or 0

      local fill = nil
      if selected then
        fill = accent
      elseif cell.isToday then
        fill = "surface_variant"
      end

      local textColor
      if selected then
        textColor = "on_primary"
      elseif not cell.inMonth then
        textColor = "on_surface_variant/0.45"
      elseif cell.isWeekend then
        textColor = "on_surface_variant"
      else
        textColor = "on_surface"
      end

      -- Dots cap at three; beyond that the count stops being readable anyway.
      local dots = {}
      for _ = 1, math.min(n, 3) do
        table.insert(dots, ui.box({
          width = DOT, height = DOT, radius = DOT / 2,
          fill = selected and "on_primary" or accent,
        }))
      end

      table.insert(cols, ui.column({
        flexGrow = 1,
        align = "center",
        justify = "center",
        gap = 1,
        minHeight = CELL_H,
        fill = fill,
        radius = 6,
        onClick = function() opts.onSelect(cell.iso) end,
      }, {
        ui.label({
          text = tostring(cell.day),
          fontSize = 12,
          fontWeight = cell.isToday and "bold" or "normal",
          color = textColor,
        }),
        ui.row({ gap = 2, align = "center", justify = "center", minHeight = DOT }, dots),
      }))
    end
    table.insert(rows, ui.row({ gap = 2 }, cols))
  end

  local title = os.date("%B %Y",
    date.mktime({ year = opts.year, month = opts.month, day = 1, hour = 12 }))

  local kids = {
    ui.row({ align = "center", gap = 6 }, {
      ui.button({ glyph = "chevron-left", variant = "ghost", controlSize = "sm",
                  onClick = function() opts.onStep(-1) end }),
      ui.label({ text = title, fontSize = 13, fontWeight = "bold",
                 flexGrow = 1, textAlign = "center" }),
      ui.button({ glyph = "chevron-right", variant = "ghost", controlSize = "sm",
                  onClick = function() opts.onStep(1) end }),
    }),
    ui.separator({ spacing = 2 }),
  }
  for _, row in ipairs(rows) do table.insert(kids, row) end

  return ui.column({ gap = 4, padding = 8 }, kids)
end

-- ── Day timeline ─────────────────────────────────────────────────────────────

local function eventBody(ev, h: number, pattern: string)
  local kids = {
    ui.label({ text = ev.title, fontSize = 11, fontWeight = "medium",
               color = "on_primary", maxLines = 1 }),
  }
  -- A second line only where the box is tall enough to hold one.
  if h >= 34 then
    table.insert(kids, ui.label({
      text = noctalia.formatTime(pattern, ev.startUnix)
          .. "–" .. noctalia.formatTime(pattern, ev.endUnix),
      fontSize = 9, color = "on_primary/0.8", maxLines = 1,
    }))
  end
  return kids
end

local function renderItem(item, accent: string, nowColor: string, pattern: string)
  if item.kind == "gap" then
    -- The fill has to be given: a box without one paints black.
    return ui.box({ height = item.h, fill = "surface/0" })
  end
  if item.kind == "line" then
    return ui.box({ height = item.h, fill = nowColor, radius = 1 })
  end

  local ev = item.ev
  local fill = eventFill(ev, accent)
  local topR = item.clippedTop and 0 or 5
  local botR = item.clippedBottom and 0 or 5

  if not item.split then
    return ui.column({
      height = item.h, fill = fill, radius = topR,
      paddingH = 5, paddingV = 2, gap = 0, justify = "start",
    }, eventBody(ev, item.h, pattern))
  end

  -- The now-line crosses this event: two stacked halves with the line between
  -- them, title in whichever half has room.
  local s = item.split
  return ui.column({ gap = 0 }, {
    ui.column({ height = s.topH, fill = fill, radius = topR, paddingH = 5, paddingV = 2 },
      s.labelIn == "top" and eventBody(ev, s.topH, pattern) or {}),
    ui.box({ height = 2, fill = nowColor }),
    ui.column({ height = s.botH, fill = fill, radius = botR, paddingH = 5, paddingV = 2 },
      s.labelIn == "bottom" and eventBody(ev, s.botH, pattern) or {}),
  })
end

function M.dayTree(opts)
  local accent = opts.accent or "primary"
  local nowColor = opts.nowColor or "error"
  local pattern = timePattern()
  local dayTs = opts.dayTs

  local timed, allDay = model.onDay(opts.events or {}, dayTs)
  local plan = layout.planDay(timed, {
    dayTs = dayTs,
    hourFrom = opts.hourFrom,
    hourTo = opts.hourTo,
    pxPerMinute = opts.pxPerMinute,
    nowUnix = opts.nowUnix,
  })

  -- Hour labels in the shell's own clock format, so a 12-hour clock reads
  -- 9:00 AM here too.
  local hourPattern = timePattern()
  local gutter = {}
  for _, hr in ipairs(plan.hours) do
    local text = string.format("%02d:00", hr.hour)
    if hr.at then text = noctalia.formatTime(hourPattern, hr.at) end
    table.insert(gutter, ui.column({ height = hr.h, align = "end" }, {
      ui.label({ text = text,
                 fontSize = 9, color = "on_surface_variant/0.8" }),
    }))
  end

  local lanes = {}
  for _, items in ipairs(plan.lanes) do
    local nodes = {}
    for _, item in ipairs(items) do
      table.insert(nodes, renderItem(item, accent, nowColor, pattern))
    end
    table.insert(lanes, ui.column({ gap = 0, flexGrow = 1 }, nodes))
  end

  local kids = {
    ui.row({ align = "center", gap = 6 }, {
      ui.button({ glyph = "chevron-left", variant = "ghost", controlSize = "sm",
                  onClick = function() opts.onStep(-1) end }),
      ui.label({ text = os.date("%A, %d.%m.", dayTs), fontSize = 13,
                 fontWeight = "bold", flexGrow = 1, textAlign = "center" }),
      ui.button({ glyph = "chevron-right", variant = "ghost", controlSize = "sm",
                  onClick = function() opts.onStep(1) end }),
    }),
  }

  if opts.showAllDay and #allDay > 0 then
    local chips = {}
    for _, ev in ipairs(allDay) do
      table.insert(chips, ui.column({
        fill = eventFill(ev, accent), radius = 4, paddingH = 5, paddingV = 1,
      }, {
        ui.label({ text = ev.title, fontSize = 10, color = "on_primary", maxLines = 1 }),
      }))
    end
    table.insert(kids, ui.row({ gap = 3 }, chips))
  end

  table.insert(kids, ui.separator({ spacing = 2 }))

  if #timed == 0 then
    table.insert(kids, ui.column({ minHeight = 80, align = "center", justify = "center" }, {
      ui.label({ text = noctalia.tr("day.empty"), fontSize = 11, color = "on_surface_variant" }),
    }))
  else
    local grid = ui.row({ gap = 4 }, {
      ui.column({ gap = 0, width = 34 }, gutter),
      ui.row({ gap = 2, flexGrow = 1 }, lanes),
    })
    -- A desktop widget sizes itself from its tree and has nothing to scroll
    -- inside, so only the panel (which is height-bounded) gets a scroll box.
    if opts.scrollable then
      table.insert(kids, ui.scroll({ flexGrow = 1 }, { grid }))
    else
      table.insert(kids, grid)
    end
  end

  -- In the panel the column has to take the height it is given, or the scroll
  -- box inside has nothing to be bounded by and the timeline runs past the
  -- panel's footer.
  return ui.column({ gap = 4, padding = 8, flexGrow = opts.scrollable and 1 or nil }, kids)
end

return M
