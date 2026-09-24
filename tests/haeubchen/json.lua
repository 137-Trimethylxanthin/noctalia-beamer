-- A minimal JSON decoder, standing in for noctalia.json.decode in the tests.
local M = {}

local function skip(s, i)
  return string.find(s, "[^ \t\r\n]", i) or #s + 1
end

local parse

local function parseString(s, i)
  local out, j = {}, i + 1
  while true do
    local c = string.sub(s, j, j)
    if c == "" then error("unterminated string") end
    if c == '"' then return table.concat(out), j + 1 end
    if c == "\\" then
      local e = string.sub(s, j + 1, j + 1)
      local map = { n = "\n", t = "\t", r = "\r", b = "\b", f = "\f", ["/"] = "/", ["\\"] = "\\", ['"'] = '"' }
      if e == "u" then
        table.insert(out, utf8.char(tonumber(string.sub(s, j + 2, j + 5), 16)))
        j = j + 6
      else
        table.insert(out, map[e]); j = j + 2
      end
    else
      table.insert(out, c); j = j + 1
    end
  end
end

parse = function(s, i)
  i = skip(s, i)
  local c = string.sub(s, i, i)
  if c == "{" then
    local t = {}
    i = skip(s, i + 1)
    if string.sub(s, i, i) == "}" then return t, i + 1 end
    while true do
      local k; k, i = parseString(s, skip(s, i))
      i = skip(s, i) + 1 -- ':'
      local v; v, i = parse(s, i)
      t[k] = v
      i = skip(s, i)
      local d = string.sub(s, i, i)
      if d == "}" then return t, i + 1 end
      i = i + 1
    end
  elseif c == "[" then
    local t = {}
    i = skip(s, i + 1)
    if string.sub(s, i, i) == "]" then return t, i + 1 end
    while true do
      local v; v, i = parse(s, i)
      table.insert(t, v)
      i = skip(s, i)
      local d = string.sub(s, i, i)
      if d == "]" then return t, i + 1 end
      i = i + 1
    end
  elseif c == '"' then
    return parseString(s, i)
  elseif string.sub(s, i, i + 3) == "true" then return true, i + 4
  elseif string.sub(s, i, i + 4) == "false" then return false, i + 5
  elseif string.sub(s, i, i + 3) == "null" then return nil, i + 4
  end
  local num = string.match(s, "^-?%d+%.?%d*[eE]?[-+]?%d*", i)
  return tonumber(num), i + #num
end

function M.decode(s)
  local ok, v = pcall(parse, s, 1)
  if ok then return v end
  return nil
end

return M
