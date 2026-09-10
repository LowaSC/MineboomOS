-- Optional per-device service overrides, outside OTA-managed files.
local FsUtil = dofile("/os/lib/fsutil.lua")
local Connections = {}
Connections.PATH = "/data/system/connections.db"

local FIELDS = {osSourceUrl = true, osSourceUrlDev = true, userServerId = true}

function Connections.isUrl(value)
    return type(value) == "string" and value:match("^https?://[^/%s]+[^%s]*$") ~= nil
end

-- Distribution references are explicit manifest data, relative to its directory.
function Connections.resolve(base, ref)
    if Connections.isUrl(ref) then return ref end
    if type(ref) ~= "string" or ref == "" or ref:find("[%s?#]")
        or ref:sub(1, 2) == "//" then return nil end
    local origin, path = tostring(base or ""):match("^(https?://[^/]+)(.*)$")
    if not origin or origin:find("[%s?#]") or path:find("[?#]") then return nil end
    local full = ref:sub(1, 1) == "/" and ref or (path .. "/" .. ref)
    local parts = {}
    for part in full:gmatch("[^/]+") do
        if part == ".." then
            if #parts == 0 then return nil end
            table.remove(parts)
        elseif part ~= "." then parts[#parts + 1] = part end
    end
    return origin .. "/" .. table.concat(parts, "/")
end

local function validField(key, value)
    if not FIELDS[key] then return false end
    if value == false then return true end
    if key == "userServerId" then
        return type(value) == "number" and value >= 0 and value == math.floor(value)
            and value <= 2147483647
    end
    return Connections.isUrl(value)
end

function Connections.load()
    if not fs.exists(Connections.PATH) then
        if fs.exists(Connections.PATH .. ".tmp") or fs.exists(Connections.PATH .. ".bak") then
            return nil, "Restore interrupted connections settings from backup"
        end
        return {}
    end
    local data, err = FsUtil.readFile(Connections.PATH)
    if not data then return nil, err end
    local ok, cfg = pcall(textutils.unserialize, data)
    if not ok or type(cfg) ~= "table" or cfg.schemaVersion ~= 1 then
        return nil, "Invalid connections settings"
    end
    for key, value in pairs(cfg) do
        if key ~= "schemaVersion" and not validField(key, value) then
            return nil, "Invalid connection: " .. tostring(key)
        end
    end
    return cfg
end

function Connections.set(key, value)
    if not validField(key, value) then return false, "Invalid connection value" end
    local cfg, err = Connections.load()
    if not cfg then return false, err end
    if fs.exists(Connections.PATH) then
        local old, readErr = FsUtil.readFile(Connections.PATH)
        if not old then return false, readErr end
        local backedUp, backupErr = FsUtil.atomicWrite(Connections.PATH .. ".bak", old)
        if not backedUp then return false, backupErr end
    end
    cfg.schemaVersion = 1
    cfg[key] = value
    return FsUtil.atomicWrite(Connections.PATH, textutils.serialize(cfg))
end

function Connections.apply(cfg, manifest, source)
    local distribution = manifest and manifest.distribution or {}
    local channels = distribution.channels or {}
    if not cfg.osSourceUrl or cfg.osSourceUrl == "" then
        cfg.osSourceUrl = Connections.resolve(source, channels.stable)
    end
    if not cfg.osSourceUrlDev or cfg.osSourceUrlDev == "" then
        cfg.osSourceUrlDev = Connections.resolve(source, channels.dev)
    end
    if not cfg.storeComputer and not cfg.storeSourceUrl and not cfg.storeSourceUrlInternet then
        cfg.storeSourceUrlInternet = Connections.resolve(source, distribution.appStore)
    end
    local overrides, err = Connections.load()
    if not overrides then return false, err end
    for key in pairs(FIELDS) do
        if overrides[key] ~= nil then
            if overrides[key] == false then cfg[key] = nil
            else cfg[key] = overrides[key] end
        end
    end
    -- New connections are scoped by server. Legacy configured sessions keep
    -- their original paths until explicitly changed through Connections.
    cfg.userServerIsolated = type(overrides.userServerId) == "number"
    return true
end

return Connections
