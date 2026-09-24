-- Vitrine's decisions, and the Hyprland backend's parsing and rules. The
-- monitor fixtures are shaped like `hyprctl monitors all -j` on Hyprland 0.56
-- and like lib/outputs.py's `list`.
noctalia = { getenv = function() return nil end, commandExists = function() return false end }
table.unpack = table.unpack or unpack

local core = require("lib.core")
local hypr = require("lib.hyprland")

local fails = 0
local function check(name, cond, extra)
  if cond then print("  ok   " .. name)
  else fails = fails + 1; print("  FAIL " .. name .. (extra ~= nil and ("  -> " .. tostring(extra)) or "")) end
end

local function head(name, enabled, extra)
  local h = { name = name, enabled = enabled, x = 0, y = 0, scale = 1, transform = 0, width = 1920, height = 1080, refresh = 60000 }
  for k, v in pairs(extra or {}) do h[k] = v end
  return h
end

local panel = head("eDP-1", true, { width = 2560, height = 1600, scale = 1.25, transform = 0 })
local acer = head("DP-7", true, { x = 2048 })

print("== classify ==")
local info = core.classify({ acer, panel })
check("the panel is internal wherever it is listed", info.internal.name == "eDP-1" and #info.external == 1)
check("both on: extend", info.mode == "extend")
check("external off: laptop only", core.classify({ panel, head("DP-7", false) }).mode == "internal")
check("panel off: external only", core.classify({ head("eDP-1", false), acer }).mode == "external")
check("a mirror: duplicate", core.classify({ panel, head("DP-7", true, { mirrorOf = "eDP-1" }) }).mode == "mirror")
check("the panel mirroring an external: duplicate", core.classify({ head("eDP-1", true, { mirrorOf = "DP-7" }), acer }).mode == "mirror")
check("a mirror on a disabled screen is no mirror", core.classify({ panel, head("DP-7", false, { mirrorOf = "eDP-1" }) }).mode == "internal")
local virt = core.classify({ panel, head("HEADLESS-2", true), head("WL-1", true) })
check("headless and nested outputs are no screens", #virt.external == 0 and virt.mode == "internal", #virt.external)
local desk = core.classify({ head("HDMI-A-1", true), head("DP-2", true) })
check("a desktop keeps the same first screen", desk.internal.name == "DP-2")
check("a name that could inject is ignored", #core.classify({ panel, head("DP-1;rm", true) }).external == 0)

print("== sizes and lid ==")
local w, h = core.logicalSize(panel)
check("logical size divides by scale", w == 2048 and h == 1280, w .. "x" .. h)
w, h = core.logicalSize(head("DSI-1", true, { width = 800, height = 1280, transform = 3 }))
check("a rotated panel swaps", w == 1280 and h == 800, w .. "x" .. h)
check("lid closed", core.parseLid("state:      closed\n") == "closed")
check("lid open", core.parseLid("state:      open\n") == "open")
check("no lid", core.parseLid(nil) == nil)

print("== what is allowed ==")
local caps = { mirror = true, lidClosed = false, external = 1 }
check("everything with a screen and mirroring", core.allowed("mirror", caps) and core.allowed("external", caps))
check("no mirroring on this compositor", select(2, core.allowed("mirror", { mirror = false, external = 1 })) == "no-mirror")
check("lid closed: not the panel", select(2, core.allowed("internal", { lidClosed = true, external = 1 })) == "lid-closed")
check("nothing attached", select(2, core.allowed("external", { external = 0 })) == "no-external")
check("cycle skips what is not possible", core.nextMode("extend", { mirror = false, external = 1 }) == "external")
check("cycle with the lid closed never lands on the panel",
  core.nextMode("external", { mirror = true, lidClosed = true, external = 1 }) == "extend")

print("== plans ==")
local rotated = head("DSI-1", true, { width = 800, height = 1280, transform = 3, scale = 1.5 })
local mem = { internal = core.record(rotated) }
local offInfo = core.classify({ head("DSI-1", false), acer })
local steps = core.plan("internal", offInfo, mem, { external = 1 })
check("laptop only: panel first, then the external off", #steps == 2 and steps[1][1].name == "DSI-1" and steps[2][1].enabled == false)
check("the panel comes back rotated and scaled", steps[1][1].transform == 3 and steps[1][1].scale == 1.5 and steps[1][1].mode.width == 800)
check("the external goes off only once the panel is up", steps[2].requires[1] == "DSI-1")
steps = core.plan("external", core.classify({ panel, head("DP-7", false) }), {}, { external = 1 })
check("external only: external on first", steps[1][1].name == "DP-7" and steps[1][1].enabled and steps[1][1].mode == "preferred")
check("then the panel off, if the external came up", steps[2].requires[1] == "DP-7" and steps[2][1].name == "eDP-1" and not steps[2][1].enabled)
steps = core.plan("mirror", info, {}, caps)
check("duplicate mirrors the panel at scale 1", steps[1][2].mirror == "eDP-1" and steps[1][2].scale == 1)
check("duplicate refused without mirroring", core.plan("mirror", info, {}, { mirror = false, external = 1 }) == nil)
local snap = core.snapshot(info)
check("extend is remembered as it is", snap and #snap.outputs == 2 and snap.outputs[2].x == 2048)
local laptopOnly = core.classify({ panel, head("DP-7", false) })
steps = core.plan("extend", laptopOnly, { extend = snap }, caps)
check("extend brings the remembered layout back", not steps.fallback and #steps[1] == 2 and steps[1][2].x == 2048)
steps = core.plan("extend", laptopOnly, {}, caps)
check("with nothing remembered: panel, then the external to its right", steps.fallback and steps[1][2].x == 2048, steps[1][2].x)
check("no screens at all", core.plan("internal", { external = {} }, {}, {}) == nil)

print("== hyprland ==")
local monitors = {
  { id = 0, name = "eDP-1", description = "California Institute of Technology 0x160", make = "California Institute of Technology",
    model = "0x160", serial = "", width = 2560, height = 1600, refreshRate = 60.001, x = 0, y = 0, scale = 1.25, transform = 0,
    disabled = false, mirrorOf = "none", availableModes = { "2560x1600@60.00Hz" } },
  { id = 1, name = "DP-7", width = 1920, height = 1080, refreshRate = 144.001, x = 2048, y = 0, scale = 1, transform = 0,
    disabled = false, mirrorOf = "none", availableModes = { "1920x1080@144.00Hz", "1280x720@60.00Hz" } },
}
local heads = hypr.heads(monitors)
check("heads from monitors", #heads == 2 and heads[1].enabled and heads[1].refresh == 60001 and #heads[2].modes == 2)
check("mirrorOf none is no mirror", core.classify(heads).mode == "extend")
check("keyword: disable", hypr.keywordRule({ name = "eDP-1", enabled = false }) == "eDP-1,disable")
check("keyword: full rule", hypr.keywordRule({ name = "DSI-1", enabled = true, mode = { width = 800, height = 1280, refresh = 60000 },
  x = 0, y = 0, scale = 1.5, transform = 3 }) == "DSI-1,800x1280@60.000,0x0,1.5,transform,3")
check("keyword: preferred, auto, mirror", hypr.keywordRule({ name = "DP-7", enabled = true, mode = "preferred", scale = 1, mirror = "eDP-1" })
  == "DP-7,preferred,auto,1,mirror,eDP-1")
local lua = hypr.evalRule({ name = "DP-7", enabled = true, mode = "preferred", scale = 1, mirror = "" })
check("eval: an empty mirror clears it", string.find(lua, 'mirror=""', 1, true) ~= nil and string.find(lua, 'position="auto"', 1, true) ~= nil, lua)
check("eval: transform kept", string.find(hypr.evalRule({ name = "DSI-1", enabled = true, transform = 3 }), "transform=3", 1, true) ~= nil)

print()
if fails > 0 then print(fails .. " failed"); os.exit(1) end
print("all passed")
