-- Local device settings are data, never part of an OTA release.
-- Absence of this file deliberately preserves the legacy registry boot path.
local FsUtil = dofile("/os/lib/fsutil.lua")
local Device = {}
Device.PATH = "/data/system/device.db"

local function validate(value)
    if type(value) ~= "table" or value.schemaVersion ~= 1 then
        return nil, "Unsupported device settings format"
    end
    local c = value.computer
    if type(c) ~= "table" or type(c.role) ~= "string"
        or not c.role:match("^[%w_]+$") or type(c.label) ~= "string"
        or (c.pocketos ~= nil and type(c.pocketos) ~= "table")
        or (c.apps ~= nil and type(c.apps) ~= "table") then
        return nil, "Invalid device settings"
    end
    return value
end

function Device.load()
    FsUtil.repair(Device.PATH)
    if not fs.exists(Device.PATH) then
        if fs.exists(Device.PATH .. ".bak") or fs.exists(Device.PATH .. ".tmp") then
            return nil, "Device settings write was interrupted"
        end
        return nil
    end
    local data, err = FsUtil.readFile(Device.PATH)
    if not data then return nil, err end
    local ok, value = pcall(textutils.unserialize, data)
    if not ok then return nil, "Cannot read device settings" end
    return validate(value)
end

function Device.save(value)
    local valid, err = validate(value)
    if not valid then return false, err end
    -- Keep the previous profile available for manual recovery.
    if fs.exists(Device.PATH) then
        local old, readErr = FsUtil.readFile(Device.PATH)
        if not old then return false, readErr end
        local ok, backupErr = FsUtil.atomicWrite(Device.PATH .. ".bak", old)
        if not ok then return false, backupErr end
    end
    return FsUtil.atomicWrite(Device.PATH, textutils.serialize(value))
end

function Device.fresh(role)
    return {
        schemaVersion = 1,
        setupComplete = false,
        computer = {
            role = role or "pocketos",
            label = "My computer",
            updateMode = "manual",
            apps = {},
            pocketos = {},
        },
    }
end

function Device.context(value)
    -- Never merge world-specific IDs or URLs into a standalone installation.
    return {
        pocketosDefaults = {
            useMonitor = true,
            storeProtocol = "pocket_store",
            refreshSeconds = 5,
            staleSeconds = 15,
            topLimit = 20,
            scrollStep = 3,
        },
        default = value.computer,
    }
end

return Device
