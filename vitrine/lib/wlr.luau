--!nonstrict
-- Every compositor but Hyprland: the standard wlr-output-management
-- protocol, which sway, Scroll, niri, MangoWC, labwc, dwl, River/Triad and
-- Umbriel all implement. lib/outputs.py speaks it (through uv and
-- pywayland); this only runs it.
--
-- The protocol has no mirroring, so Duplicate is not offered here: two
-- outputs at the same position each still show their own workspace.

local M = { name = "wlr", caps = { mirror = false } }

local function script()
  local dir = noctalia.pluginDir()
  return dir and (dir .. "/lib/outputs.py") or nil
end

function M.available()
  return noctalia.getenv("WAYLAND_DISPLAY") ~= nil and noctalia.commandExists("uv") and script() ~= nil
end

local function run(args, done)
  local argv = { "uv", "run", "--quiet", "--script", script() }
  for _, a in ipairs(args) do
    table.insert(argv, a)
  end
  local accepted = noctalia.runAsync(argv, function(result)
    done(result.exitCode, noctalia.string.trim(result.stdout or ""), noctalia.string.trim(result.stderr or ""))
  end)
  if not accepted then
    done(-1, "", "could not start uv")
  end
end

function M.list(done)
  run({ "list" }, function(code, out, err)
    if code ~= 0 then
      if string.sub(out, 1, 12) == "unsupported:" then
        M.unsupported = noctalia.string.trim(string.sub(out, 13))
      end
      noctalia.log("vitrine: outputs.py list: " .. (out ~= "" and out or err))
      return done(nil)
    end
    local heads = noctalia.json.decode(out)
    done(if type(heads) == "table" then heads else nil)
  end)
end

-- Applies one step; `done(ok, output)`. `mirror` has no meaning here and is
-- dropped.
function M.apply(configs, done)
  local plain = {}
  for _, cfg in ipairs(configs) do
    local c = {}
    for k, v in pairs(cfg) do
      if k ~= "mirror" then
        c[k] = v
      end
    end
    table.insert(plain, c)
  end
  local encoded = noctalia.json.encode(plain)
  if encoded == nil then
    return done(false, "could not encode the configuration")
  end
  run({ "apply", encoded }, function(code, out, err)
    done(code == 0, out ~= "" and out or err)
  end)
end

-- Nothing to reload: the core always has a layout to apply for Extend.
M.restoreConfig = nil

return M
