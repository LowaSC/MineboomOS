-- Shared modem/rednet helpers for MineboomOS.
-- CC:Tweaked exposes modems as peripherals on one of the six sides.
local Modem = {}

Modem.SIDES = {"back", "front", "left", "right", "top", "bottom"}

local function hasModemType(t)
    if t == "modem" then return true end
    if type(t) == "table" then
        for _, v in ipairs(t) do
            if v == "modem" then return true end
        end
    end
    return false
end

function Modem.isModemSide(side)
    if type(side) ~= "string" or side == "" or type(peripheral) ~= "table" then
        return false
    end
    if type(peripheral.getType) == "function" then
        local ok, t = pcall(peripheral.getType, side)
        if ok and hasModemType(t) then return true end
    end
    if type(peripheral.wrap) == "function" then
        local ok, p = pcall(peripheral.wrap, side)
        if ok and type(p) == "table" and type(p.isWireless) == "function" then
            return true
        end
    end
    return false
end

local function appendSide(list, seen, side)
    if type(side) == "string" and side ~= "" and not seen[side] then
        table.insert(list, side)
        seen[side] = true
    end
end

function Modem.candidateSides(preferred)
    local out, seen = {}, {}
    appendSide(out, seen, preferred)
    for _, side in ipairs(Modem.SIDES) do
        appendSide(out, seen, side)
    end
    return out
end

function Modem.open(preferred)
    if type(rednet) ~= "table" then
        return nil, "rednet unavailable"
    end

    local lastErr = nil
    for _, side in ipairs(Modem.candidateSides(preferred)) do
        if Modem.isModemSide(side) then
            local okOpen, already = pcall(rednet.isOpen, side)
            if okOpen and already then return side end

            local ok, err = pcall(rednet.open, side)
            if ok then return side end
            lastErr = err
        end
    end

    return nil, lastErr or "modem not found"
end

return Modem
