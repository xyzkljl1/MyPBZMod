-- MCU core configuration I/O and precise encoding, separate from the vendor JSON library.
local json = require('json')
local M = {}

-- Use dkjson's public custom-encoding hook without modifying its module or input values.
local function precise(value, seen)
    if type(value) == 'number' and value == value and math.abs(value) ~= math.huge
        and tonumber(tostring(value)) ~= value then
        return setmetatable({}, {__tojson = function()
            return (string.format('%.17g', value):gsub(',', '.'))
        end})
    end
    if type(value) ~= 'table' then return value end
    local meta = getmetatable(value)
    if type(meta) == 'table' and meta.__tojson then return value end
    if seen[value] then return seen[value] end
    local copy = {}
    seen[value] = copy
    for key, item in pairs(value) do copy[key] = precise(item, seen) end
    return setmetatable(copy, type(meta) == 'table' and meta or nil)
end

function M.encode(value, options) return json.encode(precise(value, {}), options) end

-- Shared file I/O. Only .new is used; a completed pending file can recover a
-- missing destination. This delete-then-rename protocol is not atomic.
local function readText(path)
  local file, err, code = io.open(path, "rb")
  if not file then return nil, code ~= 2 and err or nil end
  local text, readError = file:read("*a")
  local closed, closeError = file:close()
  if not text or not closed then return nil, readError or closeError end
  return text
end

local function readJson(path, objectOnly)
  local text, err = readText(path)
  local pending = not text and not err
  if pending then text, err = readText(path .. ".new") end
  if not text then return nil, err end
  local clean = text:gsub("^\239\187\191", "")
  local ok, value, position, reason = pcall(json.decode, clean, 1, objectOnly and json.null or nil)
  if not ok or reason or not position or clean:sub(position):find("%S") then
    return nil, "Invalid JSON; file retained: " .. tostring(reason or (not ok and value) or "trailing content")
  end
  if objectOnly and (type(value) ~= "table" or value == json.null
      or (getmetatable(value) or {}).__jsontype == "array") then
    return nil, "Configuration must be a JSON object"
  end
  if pending then
    local restored, restoreError = os.rename(path .. ".new", path)
    if not restored then return nil, "Cannot recover pending configuration: " .. tostring(restoreError) end
  end
  return value, nil, text
end

-- Returns object, error, original text. Missing files return nil, nil, nil.
function M.readObject(path) return readJson(path, true) end

-- expected: original text, false for an absent file, or nil for an unconditional write.
-- Returns the saved text or nil, error. A failed final rename retains .new.
function M.write(value, path, expected, force)
  local keys = {}
  if type(value) == "table" then
    for key in pairs(value) do if type(key) == "string" then keys[#keys + 1] = key end end
    table.sort(keys)
  end
  local ok, text = pcall(M.encode, value, {indent = true, keyorder = keys})
  if not ok then return nil, tostring(text) end
  text = text .. "\n"
  local current, err = readText(path)
  if not current and not err then
    -- Recover a failed previous rename before reusing its only pending file.
    local value
    value, err, current = readJson(path, false)
  end
  if err or (expected ~= nil and expected ~= (current or false)) then
    return nil, err or "Configuration changed outside this editor"
  end
  if not force and current == text then return text end
  local pending = path .. ".new"
  local file, err = io.open(pending, "wb")
  if not file then return nil, "Cannot stage configuration: " .. tostring(err) end
  local written, writeError = file:write(text)
  local closed, closeError = file:close()
  if not written or not closed then
    os.remove(pending)
    return nil, "Cannot stage configuration: " .. tostring(writeError or closeError)
  end
  current, err = readText(path)
  if err or (expected ~= nil and expected ~= (current or false)) then
    os.remove(pending)
    return nil, err or "Configuration changed outside this editor"
  end
  if current then
    local removed, removeError = os.remove(path)
    if not removed then return nil, "Cannot remove old configuration: " .. tostring(removeError) end
  end
  local moved, moveError = os.rename(pending, path)
  if not moved then return nil, "Cannot install configuration; .new retained: " .. tostring(moveError) end
  return text
end

return M
