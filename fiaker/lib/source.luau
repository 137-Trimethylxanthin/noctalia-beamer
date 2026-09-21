--!nonstrict
-- Picks the event backend at load time.
--
-- The whole point of this indirection: `noctalia.calendar` does not exist yet
-- (plugin API tops out at 32 with no calendar capability, and the shell's event
-- cache is keyring-encrypted). Until the core patch lands, the vdir backend
-- reads the same .ics files Noctalia's own vdir provider reads, so both agree.
-- When the patch lands, "auto" flips to the native backend and nothing else in
-- this plugin changes.

local M = {}

function M.pick(mode: string?)
  local want = mode or "auto"
  local hasNative = (noctalia :: any).calendar ~= nil

  if want == "native" or (want == "auto" and hasNative) then
    if hasNative then
      return require("./source_native.luau"), "native"
    end
    noctalia.log("fiaker: native calendar API unavailable, falling back to vdir")
  end

  return require("./source_vdir.luau"), "vdir"
end

return M
