local Package = {}

local cache = {}

function Package.require(path)
    if cache[path] then return cache[path] end
    local value = dofile(path)
    cache[path] = value
    return value
end

function Package.clear(path)
    if path then
        cache[path] = nil
    else
        cache = {}
    end
end

return Package
