--!nonstrict
-- Reads Noctalia's own merged calendar snapshot.
--
-- Requires a core addition that does not exist yet:
--
--   noctalia.calendar.events(fromUnix?, toUnix?) -> { CalendarEvent } | nil
--
-- CalendarService::snapshot() is already public and const, and
-- calendar_types.h notes "Recurring events are expanded server-side, so every
-- instance carries its own resolved start/end" - so this backend needs no
-- RRULE handling, no parsing, and no credentials at all. See PROPOSAL.md §2.

local model = require("./model.luau")

local M = {}

M.needsPolling = true

function M.fetch(opts, done)
  local api = (noctalia :: any).calendar
  if api == nil or api.events == nil then
    done(nil, "noctalia.calendar.events is not available in this Noctalia build")
    return
  end

  local ok, raw = pcall(api.events, opts.from, opts.to)
  if not ok then
    done(nil, tostring(raw))
    return
  end
  if raw == nil then
    done({}, nil)  -- no accounts configured, or no successful sync yet
    return
  end

  local events = {}
  for _, r in ipairs(raw) do
    local ev = model.normalize(r)
    if ev then table.insert(events, ev) end
  end
  done(model.sortByStart(events), nil)
end

return M
