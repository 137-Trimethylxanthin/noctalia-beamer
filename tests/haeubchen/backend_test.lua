-- The parsing half of each backend: compositor JSON in, neutral model out.
-- The Hyprland fixtures are trimmed captures from Hyprland 0.56; the sway and
-- niri ones follow sway-ipc(7) and niri-ipc's structs, since neither was
-- available to capture from.
local json = require("json")
noctalia = {
  json = { decode = json.decode },
  getenv = function() return nil end,
  state = { get = function() return nil end },
}

local hypr = require("lib.hyprland")
local sway = require("lib.sway")
local niri = require("lib.niri")

local fails = 0
local function check(name, cond, extra)
  if cond then print("  ok   " .. name)
  else fails = fails + 1; print("  FAIL " .. name .. (extra and ("  -> " .. tostring(extra)) or "")) end
end

print("== hyprland ==")
check("json address kept", hypr.id("0x559EBA2B3E70") == "0x559eba2b3e70")
check("socket2 address gains 0x", hypr.id("559eba2b3e70") == "0x559eba2b3e70")
check("junk refused", hypr.id("0x55; rm -rf ~") == nil)
check("numbered workspace by id", hypr.workspaceSpec({ id = 3, name = "3" }) == "3")
check("named workspace by name", hypr.workspaceSpec({ id = -1337, name = "gaming" }) == "name:gaming")
check("special kept", hypr.workspaceSpec({ id = -98, name = "special:magic" }) == "special:magic")
check("quote refused", hypr.workspaceSpec({ id = -2, name = "a'b" }) == nil)

local monitors = json.decode([[
[{"id":0,"name":"eDP-1","width":2560,"height":1600,"refreshRate":60.001,"x":0,"y":0,
  "activeWorkspace":{"id":1,"name":"1"},"specialWorkspace":{"id":0,"name":""},
  "reserved":[0,35,0,0],"scale":1.25,"transform":0,"focused":true},
 {"id":1,"name":"DP-1","width":1920,"height":1080,"x":2048,"y":0,
  "activeWorkspace":{"id":5,"name":"5"},"specialWorkspace":{"id":-98,"name":"special:special"},
  "reserved":[0,0,0,0],"scale":1.0,"transform":0,"focused":false}]
]])
local screen = hypr.screen(monitors)
check("both actives visible", screen.visible[1] and screen.visible[5])
check("open special visible", screen.visible[-98])
check("area is logical minus the bar", screen.area.w == 2048 and screen.area.h == 1245 and screen.area.y == 35,
  screen.area.w .. "x" .. screen.area.h .. "@" .. screen.area.y)
local portrait = hypr.area({ x = 0, y = 0, width = 1920, height = 1080, scale = 1, transform = 1, reserved = { 0, 0, 0, 0 } })
check("portrait swaps axes", portrait.w == 1080 and portrait.h == 1920)

local clients = json.decode([[
[{"address":"0x559eba2b3e70","mapped":true,"hidden":false,"at":[10,45],"size":[2028,1225],
  "workspace":{"id":1,"name":"1"},"floating":false,"monitor":0,"class":"vesktop",
  "title":"Discord","pinned":false,"fullscreen":0,"fullscreenClient":0},
 {"address":"0x559eba275c00","mapped":true,"at":[1520,976],"size":[512,288],
  "workspace":{"id":5,"name":"5"},"floating":true,"class":"zen",
  "title":"VALORANT - Twitch","pinned":true,"fullscreen":0,"fullscreenClient":0},
 {"address":"0x559eba000000","mapped":false,"at":[0,0],"size":[0,0],
  "workspace":{"id":-1,"name":""},"floating":false,"class":"ghost","title":"","pinned":false}]
]])
local windows = hypr.windows(clients)
check("unmapped left out", #windows == 2, #windows)
check("fields", windows[2].id == "0x559eba275c00" and windows[2].ws == 5 and windows[2].sticky and windows[2].floating
  and windows[2].x == 1520 and windows[2].w == 512)
check("home spec", hypr.homeOf(windows[1]).spec == "1")

local e = hypr.parseEvent("workspacev2>>2,2")
check("workspace switch is a check", e and e.kind == "check")
e = hypr.parseEvent("openwindow>>559eba711410,1,haeubchen,Häubchen - shroud, live")
check("openwindow", e and e.kind == "open" and e.id == "0x559eba711410" and e.class == "haeubchen")
e = hypr.parseEvent("closewindow>>559eba711410")
check("closewindow", e and e.kind == "close" and e.id == "0x559eba711410")
check("title change is a check", hypr.parseEvent("windowtitlev2>>559eba711410,new title").kind == "check")
check("noise ignored", hypr.parseEvent("activewindowv2>>559eba275c00") == nil)

print("== sway ==")
check("con id", sway.id(42) == "42" and sway.id("42") == "42" and sway.id("4;2") == nil)
local tree = json.decode([[
{"id":1,"type":"root","nodes":[
  {"id":2,"type":"output","name":"__i3","nodes":[
    {"id":3,"type":"workspace","name":"__i3_scratch","nodes":[],"floating_nodes":[
      {"id":99,"type":"floating_con","app_id":"foot","name":"scratch","pid":9,"nodes":[],"floating_nodes":[],
       "rect":{"x":0,"y":0,"width":10,"height":10},"sticky":false,"fullscreen_mode":0}]}]},
  {"id":4,"type":"output","name":"eDP-1","nodes":[
    {"id":5,"type":"workspace","name":"1","num":1,"nodes":[
      {"id":6,"type":"con","layout":"splith","nodes":[
        {"id":7,"type":"con","app_id":"foot","name":"~","pid":100,"nodes":[],"floating_nodes":[],
         "rect":{"x":0,"y":30,"width":960,"height":1050},"sticky":false,"fullscreen_mode":0,"focused":true},
        {"id":8,"type":"con","app_id":null,"window_properties":{"class":"firefox"},"name":"Twitch","pid":101,
         "nodes":[],"floating_nodes":[],"rect":{"x":960,"y":30,"width":960,"height":1050},
         "sticky":false,"fullscreen_mode":1}]}],
     "floating_nodes":[
      {"id":9,"type":"floating_con","app_id":"mpv","name":"clip","pid":102,"nodes":[],"floating_nodes":[],
       "rect":{"x":100,"y":100,"width":640,"height":360},"sticky":true,"fullscreen_mode":0}]}]}]}
]])
local sw = sway.windows(tree)
check("scratchpad left out, three windows", #sw == 3, #sw)
check("tiled window", sw[1].id == "7" and sw[1].ws == "1" and not sw[1].floating and sw[1].class == "foot")
check("xwayland class", sw[2].class == "firefox" and sw[2].fullscreen == 1)
check("floating sticky", sw[3].floating and sw[3].sticky and sw[3].w == 640)
local ss = sway.screen(json.decode([[
[{"num":1,"name":"1","visible":true,"focused":true,"output":"eDP-1","rect":{"x":0,"y":30,"width":1920,"height":1050}},
 {"num":2,"name":"2","visible":false,"focused":false,"output":"eDP-1","rect":{"x":0,"y":30,"width":1920,"height":1050}}]
]]))
check("visible by name", ss.visible["1"] and not ss.visible["2"])
check("area is the workspace rect (bar excluded)", ss.area.y == 30 and ss.area.h == 1050)
e = sway.parseEvent([[{"change":"new","container":{"id":12,"app_id":"haeubchen","name":"shroud"}}]])
check("new window", e.kind == "open" and e.id == "12" and e.class == "haeubchen")
e = sway.parseEvent([[{"change":"close","container":{"id":12}}]])
check("closed window", e.kind == "close" and e.id == "12")
check("workspace event is a check", sway.parseEvent([[{"change":"focus","current":{"name":"2"}}]]).kind == "check")

print("== niri ==")
local nws = json.decode([[
[{"id":10,"idx":1,"name":null,"output":"eDP-1","is_urgent":false,"is_active":false,"is_focused":false,"active_window_id":20},
 {"id":11,"idx":2,"name":"chat","output":"eDP-1","is_urgent":false,"is_active":true,"is_focused":true,"active_window_id":21}]
]])
local nwin = json.decode([[
[{"id":20,"title":"VALORANT - Twitch","app_id":"firefox","pid":5,"workspace_id":10,"is_focused":false,
  "is_floating":false,"is_urgent":false,
  "layout":{"pos_in_scrolling_layout":[1,1],"tile_size":[1000.0,1200.0],"window_size":[996,1196],
            "tile_pos_in_workspace_view":null,"window_offset_in_tile":[2.0,2.0]}},
 {"id":21,"title":"notes","app_id":"foot","pid":6,"workspace_id":11,"is_focused":true,
  "is_floating":true,"is_urgent":false,
  "layout":{"pos_in_scrolling_layout":null,"tile_size":[600.0,400.0],"window_size":[600,400],
            "tile_pos_in_workspace_view":[50.5,60.0],"window_offset_in_tile":[0.0,0.0]}}]
]])
local nw = niri.windows(nwin, nws)
check("two windows", #nw == 2)
check("tiled", nw[1].id == "20" and nw[1].ws == 10 and not nw[1].floating and nw[1].wsLabel == "1")
check("floating with position", nw[2].floating and nw[2].x == 50 and nw[2].y == 60 and nw[2].wsLabel == "chat")
local ns = niri.screen(nws, json.decode([[{"eDP-1":{"name":"eDP-1","logical":{"x":0,"y":0,"width":2048,"height":1280,"scale":1.25,"transform":"Normal"}}}]]))
check("active workspace visible", ns.visible[11] and not ns.visible[10])
check("area in working-area coordinates", ns.area.x == 0 and ns.area.w == 2048 and ns.area.h == 1280)
check("focused workspace id for carrying", ns.workspace == 11)
e = niri.parseEvent([[{"WindowOpenedOrChanged":{"window":{"id":30,"app_id":"haeubchen","title":"x","workspace_id":11,"is_floating":false,"layout":{}}}}]])
check("opened", e.kind == "open" and e.id == "30" and e.class == "haeubchen")
check("closed", niri.parseEvent([[{"WindowClosed":{"id":30}}]]).kind == "close")
check("workspace switch is a check", niri.parseEvent([[{"WorkspaceActivated":{"id":10,"focused":true}}]]).kind == "check")
check("layout noise ignored", niri.parseEvent([[{"WindowLayoutsChanged":{"changes":[]}}]]) == nil)

print()
if fails > 0 then print(fails .. " failed"); os.exit(1) end
print("all passed")
