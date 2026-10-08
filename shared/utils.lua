-- nonick_lib · shared/utils.lua
-- Small shared helpers used across NN modules and handy in consumer scripts.

NN.Utils = NN.Utils or {}

-- Safe numeric field read: returns t[k] when it is a number, else the default.
function NN.Utils.num(t, k, d)
    if type(t) == 'table' and type(t[k]) == 'number' then return t[k] end
    return d
end

function NN.Utils.clamp(value, minValue, maxValue)
    if value < minValue then return minValue end
    if value > maxValue then return maxValue end
    return value
end

function NN.Utils.round(value, decimals)
    local mult = 10 ^ (decimals or 0)
    return math.floor(value * mult + 0.5) / mult
end

-- Snap a value to a fixed step (grid placement, rotation steps, ...).
function NN.Utils.snap(value, step)
    if not step or step <= 0 then return value end
    return math.floor((value / step) + 0.5) * step
end

function NN.Utils.trim(s)
    return (tostring(s or ''):gsub('^%s+', ''):gsub('%s+$', ''))
end

-- Build a namespaced debug printer:
--   local dbg = NN.Utils.debugPrinter('myscript', function() return Config.Debug end)
--   dbg('hello')  -->  [myscript] hello   (only when the enabled fn returns truthy)
function NN.Utils.debugPrinter(prefix, isEnabled)
    return function(message)
        if isEnabled and not isEnabled() then return end
        print(('[%s] %s'):format(prefix or NN.resource, tostring(message)))
    end
end

-- Load + decode a JSON file from a resource (defaults to the calling resource).
-- Returns nil on missing file or invalid JSON.
function NN.Utils.loadJson(path, resource)
    local raw = LoadResourceFile(resource or NN.resource, path)
    if not raw or raw == '' then return nil end
    local ok, data = pcall(json.decode, raw)
    if not ok then return nil end
    return data
end

-- Encode + save a JSON file into a resource (server-side only).
function NN.Utils.saveJson(path, data, resource)
    if not IsDuplicityVersion() then return false end
    local ok, encoded = pcall(json.encode, data)
    if not ok then return false end
    return SaveResourceFile(resource or NN.resource, path, encoded, -1)
end
