local pip = require("lib.pip")

local fails = 0
local function check(name, cond, extra)
  if cond then print("  ok   " .. name)
  else fails = fails + 1; print("  FAIL " .. name .. (extra and ("  -> " .. tostring(extra)) or "")) end
end

print("== corner ==")
-- The machine this was written on: 2048x1280 logical, a 35px bar on top.
local area = { x = 0, y = 35, w = 2048, h = 1245 }
local r = pip.corner(area, "bottom_right", 0.25, 16)
check("width is a quarter", r.w == 512, r.w)
check("16:9", r.h == 288, r.h)
check("right edge", r.x + r.w == 2048 - 16, r.x)
check("bottom edge", r.y + r.h == 1280 - 16, r.y)
local tl = pip.corner(area, "top_left", 0.25, 16)
check("top-left clears the bar", tl.y == 35 + 16 and tl.x == 16, tl.x .. "," .. tl.y)
local s = pip.corner({ x = 2048, y = 0, w = 1920, h = 1080 }, "bottom_left", 0.25, 10)
check("offset by the area origin", s.x == 2058, s.x)

print("== decide (can pin) ==")
local vis = { [1] = true }
local onHome = { ws = 1, sticky = false, floating = false }
local offHome = { ws = 2, sticky = false, floating = false }
local pinnedHere = { ws = 1, sticky = true, floating = true }
local pinnedAway = { ws = 7, sticky = true, floating = true }
check("gone", pip.decide("home", 1, nil, vis, true) == "gone")
check("home, visible: nothing", pip.decide("home", nil, onHome, vis, true) == nil)
check("home, off screen: enter", pip.decide("home", nil, offHome, vis, true) == "enter")
check("sibling focus is not a trigger", pip.decide("home", nil, onHome, { [1] = true, [3] = true }, true) == nil)
check("pip, home back: exit", pip.decide("pip", 1, pinnedHere, vis, true) == "exit")
check("pip, home on another monitor: exit", pip.decide("pip", 2, pinnedAway, { [2] = true, [7] = true }, true) == "exit")
check("pip, elsewhere: nothing", pip.decide("pip", 2, pinnedHere, vis, true) == nil)
check("pip, unpinned by hand: adopt", pip.decide("pip", 2, { ws = 1, sticky = false, floating = true }, vis, true) == "adopt")
check("pip, pinned but off screen (other monitor): carry", pip.decide("pip", 2, pinnedAway, vis, true) == "carry")
check("hidden, away: nothing", pip.decide("hidden", 2, offHome, vis, true) == nil)
check("hidden, seen again: unhide", pip.decide("hidden", 1, onHome, vis, true) == "unhide")

print("== decide (niri: no pin) ==")
local floatAway = { ws = 7, sticky = false, floating = true }
local floatHere = { ws = 3, sticky = false, floating = true }
check("switched away: carry", pip.decide("pip", 2, floatAway, { [3] = true }, false) == "carry")
check("carried: nothing", pip.decide("pip", 2, floatHere, { [3] = true }, false) == nil)
check("floating is the corner marker", pip.decide("pip", 2, { ws = 3, floating = false }, { [3] = true }, false) == "adopt")
check("home back: exit", pip.decide("pip", 2, floatHere, { [2] = true }, false) == "exit")

print("== remembered geometry ==")
local rel = pip.toRelative({ x = 1000, y = 500, w = 640, h = 360 }, area)
local back = pip.fromRelative(rel, area)
check("round trip", back.x == 1000 and back.y == 500 and back.w == 640 and back.h == 360,
  back.x .. "," .. back.y .. " " .. back.w .. "x" .. back.h)
local small = pip.fromRelative(pip.toRelative({ x = 1800, y = 1000, w = 400, h = 225 }, area), { x = 0, y = 0, w = 1280, h = 720 })
check("scales to a smaller screen", small.w == 250 and small.x + small.w <= 1280 and small.y + small.h <= 720,
  small.x .. "," .. small.y .. " " .. small.w .. "x" .. small.h)
local off = pip.fromRelative({ x = 0.95, y = 0.95, w = 0.3, h = 0.3 }, area)
check("clamped fully on screen", off.x + off.w <= 2048 and off.y + off.h <= 1280, off.x .. "," .. off.y)
local tiny = pip.fromRelative({ x = 0, y = 0, w = 0.01, h = 0.01 }, area)
check("never smaller than 160x90", tiny.w == 160 and tiny.h == 90)
local placed = { x = 1520, y = 976, w = 512, h = 288 }
check("untouched is not moved", not pip.moved({ x = 1520, y = 976, w = 512, h = 288 }, placed))
check("frame slack is not moved", not pip.moved({ x = 1518, y = 956, w = 516, h = 306 }, placed))
check("dragged is moved", pip.moved({ x = 900, y = 600, w = 512, h = 288 }, placed))
check("resized is moved", pip.moved({ x = 1520, y = 976, w = 800, h = 450 }, placed))
check("nothing placed yet", not pip.moved({ x = 0, y = 0, w = 1, h = 1 }, nil))

print("== snapshot ==")
local snap = pip.snapshot({ floating = true, x = 10, y = 20, w = 300, h = 200, fullscreen = 1 })
check("geometry", snap.x == 10 and snap.y == 20 and snap.w == 300 and snap.h == 200)
check("fullscreen kept", snap.fullscreen == 1 and snap.floating)

print("== autoCandidate ==")
local windows = {
  { id = "a", class = "kitty", title = "nvim" },
  { id = "b", class = "mpv", title = "holiday.mkv" },
  { id = "c", class = "zen", title = "(10) VALORANT - Twitch — Zen Browser" },
}
check("the Twitch tab", pip.autoCandidate(windows, {}, "haeubchen").id == "c")
check("a local mpv file is not a stream", pip.autoCandidate({ windows[1], windows[2] }, {}, "haeubchen") == nil)
check("declined is skipped", pip.autoCandidate(windows, { c = true }, "haeubchen") == nil)
local withPlayer = { windows[3], { id = "d", class = "haeubchen", title = "shroud" } }
check("our own player wins", pip.autoCandidate(withPlayer, {}, "haeubchen").id == "d")

print("== parsePlayable ==")
check("twitch shorthand", pip.parsePlayable("twitch shroud") == "https://www.twitch.tv/shroud")
check("case-insensitive site", pip.parsePlayable("  Kick  xqc ") == "https://kick.com/xqc")
check("yt id", pip.parsePlayable("yt dQw4w9WgXcQ") == "https://www.youtube.com/watch?v=dQw4w9WgXcQ")
check("url", pip.parsePlayable("https://www.youtube.com/watch?v=abc&t=10") == "https://www.youtube.com/watch?v=abc&t=10")
check("plain words are a filter", pip.parsePlayable("zen") == nil)
check("unknown site is a filter", pip.parsePlayable("netflix foo") == nil)
check("url with a space refused", pip.parsePlayable("https://a.b/c d") == nil)

print("== playerArgv ==")
local a = pip.playerArgv("mpv --force-window=immediate {url}", "https://x.y/a b")
check("url is one argument", #a == 3 and a[3] == "https://x.y/a b")
local b = pip.playerArgv("vlc", "u")
check("url appended without placeholder", b[1] == "vlc" and b[2] == "u")
check("empty command", pip.playerArgv("  ", "u") == nil)

print("== streamScore ==")
check("twitch tab ranks first", pip.streamScore({ class = "zen", title = "(10) VALORANT - Twitch — Zen Browser" }) == 2)
check("player app next", pip.streamScore({ class = "mpv", title = "video.mkv" }) == 1)
check("'stream' in a title does not count", pip.streamScore({ class = "kitty", title = "Floating player plugin for streams" }) == 0)

print()
if fails > 0 then print(fails .. " failed"); os.exit(1) end
print("all passed")
