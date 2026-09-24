--!nonstrict
-- Scroll: a sway fork with a scrolling layout that keeps sway's IPC, spoken
-- through `scrollmsg` on $SCROLLSOCK. Everything Häubchen needs (floating,
-- sticky, move absolute position, resize set) is the same as on sway, so this
-- is the sway backend with the other program. Not yet tested on a real Scroll
-- session. Leaving the corner puts the window back into the scrolling row at
-- the focused position, not necessarily its old column.

return require("./sway.luau").make("scrollmsg", "scroll", "SCROLLSOCK")
