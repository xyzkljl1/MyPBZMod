-- Display from Lua values, never from the slider's float32 position.
local M = {}
function M.text(value)
    if math.type(value) == 'integer' then return tostring(value) end
    for digits = 1, 17 do
        local text = string.format('%.' .. digits .. 'g', value):gsub(',', '.')
        if tonumber(text) == value then
            local mantissa, exponent = text:match('^([^eE]+)[eE]([%+%-]?%d+)$')
            if mantissa and math.abs(value) >= 1e-6 and math.abs(value) < 1e15 then
                local places = math.max(0, #(mantissa:match('%.(%d+)') or '') - tonumber(exponent))
                text = string.format('%.' .. places .. 'f', value):gsub(',', '.')
            end
            return text
        end
    end
    return tostring(value)
end

local function decimalPlaces(value)
    local text = M.text(value)
    local mantissa, exponent = text:match('^([^eE]+)[eE]([%+%-]?%d+)$')
    local fraction = (mantissa or text):match('%.(%d+)') or ''
    return math.max(0, #fraction - (tonumber(exponent) or 0))
end

function M.tick(minimum, step, index)
    local value = minimum + step * index
    if value == 0 or (math.type(minimum) == 'integer' and math.type(step) == 'integer') then return value end
    local places = math.max(decimalPlaces(minimum), decimalPlaces(step))
    local digits = math.max(1, math.min(17, math.floor(math.log(math.abs(value), 10)) + 1 + places))
    return tonumber((string.format('%.' .. digits .. 'g', value):gsub(',', '.')))
end
return M
