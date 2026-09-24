--!nonstrict
-- Follows a compositor's event stream, and starts it again when it ends.
--
-- runStream has no end-of-stream callback, so the command is followed by an
-- echo: when socat, swaymsg or niri exits (the compositor restarted, the
-- socket dropped), that line arrives, and the next tick starts a new stream a
-- few seconds later. Lines from a stream that was replaced are ignored.

local M = {}

M.ENDED = "haeubchen:ended"
local RETRY_MS = 3000

-- `parse(line)` turns one line into a neutral event, a list of them, or nil;
-- `onEvent` gets them, plus one { kind = "check" } each time the stream
-- (re)starts, so anything missed while it was down is picked up.
function M.follow(command, parse, onEvent)
  local gen, down, retryAt = 0, false, 0
  local handle = {}

  function handle.listen()
    gen += 1
    local mine = gen
    down = false
    local ok = noctalia.runStream(command .. "; echo " .. M.ENDED, function(line)
      if mine ~= gen then
        return
      end
      line = noctalia.string.trim(line or "")
      if line == M.ENDED then
        down = true
        retryAt = noctalia.nowMs() + RETRY_MS
        return
      end
      -- One line may stand for several events (a full snapshot).
      local event = parse(line)
      if event ~= nil and event.kind == nil then
        for _, one in ipairs(event) do
          onEvent(one)
        end
      elseif event ~= nil then
        onEvent(event)
      end
    end)
    if not ok then
      down = true
      retryAt = noctalia.nowMs() + RETRY_MS
    end
    onEvent({ kind = "check" })
    return ok
  end

  -- Called from the service's update(); restarts a stream that ended.
  function handle.tick()
    if down and noctalia.nowMs() >= retryAt then
      noctalia.log("haeubchen: event stream ended; following it again")
      handle.listen()
    end
  end

  return handle
end

return M
