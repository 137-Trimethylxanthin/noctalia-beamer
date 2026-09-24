--!nonstrict
-- Pure decisions for Häubchen: no compositor, no noctalia.*, so the tests can
-- run it under plain Lua.
--
-- It works on the neutral model every backend (lib/backend/*.luau) produces:
--
--   window  { id, title, class, ws, floating, sticky, fullscreen, x, y, w, h }
--           `id` is the backend's own window id as a string, `ws` the key of
--           the workspace it is on. `sticky` is Hyprland's pin / sway's sticky.
--           Backends may add fields of their own (`wsLabel` for the launcher,
--           Hyprland's raw `workspace`); nothing here reads them.
--   screen  { visible = { [ws] = true }, area = { x, y, w, h } }
--           `area` is the usable rectangle of the focused monitor (bars
--           subtracted where the compositor says where they are), in logical
--           pixels and the compositor's global coordinates.

local M = {}

M.CORNERS = { "bottom_right", "bottom_left", "top_right", "top_left" }

function M.findWindow(windows, id)
  for _, window in ipairs(windows or {}) do
    if window.id == id then
      return window
    end
  end
  return nil
end

-- The corner rectangle inside `area`, 16:9, `fraction` of its width.
function M.corner(area, corner, fraction, margin)
  local w = math.floor(area.w * fraction + 0.5)
  local h = math.floor(w * 9 / 16 + 0.5)
  -- On a very wide screen a large fraction would be taller than the area:
  -- fit the height, and keep 16:9 by narrowing.
  local maxH = area.h - 2 * margin
  if maxH > 0 and h > maxH then
    h = math.floor(maxH)
    w = math.floor(h * 16 / 9 + 0.5)
  end

  local x
  if corner == "bottom_left" or corner == "top_left" then
    x = area.x + margin
  else
    x = area.x + area.w - margin - w
  end
  local y
  if corner == "top_left" or corner == "top_right" then
    y = area.y + margin
  else
    y = area.y + area.h - margin - h
  end

  return { x = math.floor(x), y = math.floor(y), w = w, h = h }
end

-- ── The corner window's own size and place ─────────────────────────────────
--
-- Once you drag or resize the corner window, that is where it goes from then
-- on. It is kept relative to the usable area, so it lands in the same spot on
-- a monitor of another size.

local MIN_W, MIN_H = 160, 90

local function round(v)
  return math.floor(v + 0.5)
end

function M.toRelative(rect, area)
  return {
    x = (rect.x - area.x) / area.w,
    y = (rect.y - area.y) / area.h,
    w = rect.w / area.w,
    h = rect.h / area.h,
  }
end

-- Back to pixels, kept inside the area so a spot saved on a big monitor is
-- still fully visible on a small one.
function M.fromRelative(rel, area)
  local w = math.max(MIN_W, math.min(area.w, round(rel.w * area.w)))
  local h = math.max(MIN_H, math.min(area.h, round(rel.h * area.h)))
  local x = area.x + round(rel.x * area.w)
  local y = area.y + round(rel.y * area.h)
  x = math.max(area.x, math.min(area.x + area.w - w, x))
  y = math.max(area.y, math.min(area.y + area.h - h, y))
  return { x = x, y = y, w = w, h = h }
end

-- Whether the user moved or resized the corner window since it was placed.
-- The tolerance absorbs compositors that report the frame (borders, title
-- bar) rather than the exact size that was asked for.
function M.moved(window, placed, tolerance)
  if placed == nil then
    return false
  end
  tolerance = tolerance or 24
  return math.abs(window.x - placed.x) > tolerance
    or math.abs(window.y - placed.y) > tolerance
    or math.abs(window.w - placed.w) > tolerance
    or math.abs(window.h - placed.h) > tolerance
end

-- What the window was like before Häubchen touched it, so leaving the corner
-- puts it back exactly: tiled, floating somewhere, or fullscreen.
function M.snapshot(window)
  return {
    floating = window.floating == true,
    x = window.x or 0,
    y = window.y or 0,
    w = window.w or 0,
    h = window.h or 0,
    fullscreen = window.fullscreen or 0,
    fullscreenClient = window.fullscreenClient or 0,
  }
end

-- Whether the window still looks like Häubchen put it in the corner. Where the
-- compositor can pin (`sticky`), that is the pin; niri cannot, so there it is
-- floating.
local function inCorner(window, canPin)
  if canPin then
    return window.sticky == true
  end
  return window.floating == true
end

-- The one state machine. Given what Häubchen thinks (`mode`, `homeWs`) and what
-- the compositor says, returns the step to take:
--
--   "gone"   the window closed
--   "enter"  it left the screen: shrink it into the corner
--   "exit"   its home workspace is back on screen: put it home
--   "carry"  in the corner, but its workspace went off screen: bring it along
--            (every workspace switch on niri, which cannot pin; a monitor
--            change elsewhere)
--   "adopt"  someone unpinned or retiled it by hand: let go, it is home now
--   "unhide" hidden, and the user went back to it: auto-PiP resumes
--   nil      nothing to do
--
-- mode is "home" (on its workspace), "pip" (in the corner) or "hidden"
-- (parked at home, auto-PiP suspended until it is seen again).
function M.decide(mode, homeWs, window, visible, canPin)
  if window == nil then
    return "gone"
  end
  local onScreen = window.ws ~= nil and visible[window.ws] == true

  if mode == "home" then
    if not onScreen then
      return "enter"
    end
  elseif mode == "pip" then
    if homeWs ~= nil and visible[homeWs] then
      return "exit"
    end
    if not inCorner(window, canPin) then
      return "adopt"
    end
    if not onScreen then
      return "carry"
    end
  elseif mode == "hidden" then
    if onScreen then
      return "unhide"
    end
  end
  return nil
end

-- Ranks a window for the /pip list and for auto-follow: a site in the title
-- beats a player app, which beats everything else, so the Twitch tab is on
-- top. Words like "stream" or "live" are left out on purpose: they are in too
-- many titles.
local SITE_WORDS = { "twitch", "youtube", "kick.com", "- kick" }
local PLAYER_CLASSES = { "mpv", "vlc", "haruna", "celluloid", "haeubchen" }

function M.streamScore(window)
  local title = string.lower(window.title or "")
  for _, word in ipairs(SITE_WORDS) do
    if string.find(title, word, 1, true) then
      return 2
    end
  end
  local class = string.lower(window.class or "")
  for _, word in ipairs(PLAYER_CLASSES) do
    if string.find(class, word, 1, true) then
      return 1
    end
  end
  return 0
end

-- The window auto-follow should pick up, or nil. Only something that is
-- plainly a stream: a site in the title, or the player Häubchen itself opens.
-- A generic mpv playing a local file is left alone. `declined` holds ids the
-- user stopped following, which are never picked up again by themselves.
function M.autoCandidate(windows, declined, playerClass)
  local best = nil
  for _, window in ipairs(windows or {}) do
    if not declined[window.id] then
      local score = M.streamScore(window)
      if window.class == playerClass then
        score = 3
      end
      if score >= 2 and (best == nil or score > best.score) then
        best = { window = window, score = score }
      end
    end
  end
  return best and best.window or nil
end

-- `/pip <text>` as something to play, or nil when it is a filter for the window
-- list instead. Shorthands for the three sites people actually watch.
local SITES = {
  twitch = "https://www.twitch.tv/",
  tw = "https://www.twitch.tv/",
  kick = "https://kick.com/",
  yt = "https://www.youtube.com/watch?v=",
  youtube = "https://www.youtube.com/watch?v=",
}

function M.parsePlayable(text)
  text = string.match(text or "", "^%s*(.-)%s*$")
  if string.match(text, "^https?://[%w%-._~:/?#%[%]@!$&'()*+,;=%%]+$") then
    return text
  end
  local site, rest = string.match(text, "^(%a+)%s+([%w_%-]+)$")
  if site ~= nil and SITES[string.lower(site)] then
    return SITES[string.lower(site)] .. rest
  end
  return nil
end

-- Splits the player command setting into argv, substituting the URL as one
-- whole argument so it never passes through a shell.
function M.playerArgv(template, url)
  local argv, sawUrl = {}, false
  for word in string.gmatch(template or "", "%S+") do
    if word == "{url}" then
      table.insert(argv, url)
      sawUrl = true
    else
      table.insert(argv, word)
    end
  end
  if #argv == 0 then
    return nil
  end
  if not sawUrl then
    table.insert(argv, url)
  end
  return argv
end

return M
