local State = {}

local function clamp(value, minValue, maxValue)
    if value < minValue then
        return minValue
    elseif value > maxValue then
        return maxValue
    end

    return value
end

local function readSerializedTable(path)
    if not fs.exists(path) then
        return nil
    end

    local file = fs.open(path, "r")
    if not file then
        return nil
    end

    local content = file.readAll()
    file.close()

    local ok, value = pcall(textutils.unserialize, content)
    if not ok or type(value) ~= "table" then
        return nil
    end

    return value
end

local function writeSerializedTable(path, value, errorMessage)
    local dir = fs.getDir(path)
    if dir and dir ~= "" and not fs.exists(dir) then
        fs.makeDir(dir)
    end

    -- Атомарная запись через .tmp + fs.move, чтобы прерывание не оставляло
    -- битый файл настроек.
    local tmp = path .. ".tmp"
    if fs.exists(tmp) then fs.delete(tmp) end
    local file = fs.open(tmp, "w")
    if not file then
        error((errorMessage or "Cannot write file: ") .. path)
    end
    file.write(textutils.serialize(value))
    file.close()

    if fs.exists(path) then fs.delete(path) end
    local ok = pcall(fs.move, tmp, path)
    if not ok then
        error((errorMessage or "Cannot move into place: ") .. path)
    end
end

local function buildDefaultColumnSettings(columns)
    local settings = {}

    for _, column in ipairs(columns or {}) do
        if type(column) == "table" and type(column.id) == "string" then
            if column.required then
                settings[column.id] = true
            elseif column.defaultVisible == false then
                settings[column.id] = false
            else
                settings[column.id] = true
            end
        end
    end

    return settings
end

function State.readSerializedTable(path)
    return readSerializedTable(path)
end

function State.writeSerializedTable(path, value)
    writeSerializedTable(path, value)
end

function State.loadUiSettings(config, columns)
    local minScale = config.monitorTextScaleMin or 0.5
    local maxScale = config.monitorTextScaleMax or 1.5
    local settings = {
        monitorTextScale = config.monitorTextScale or minScale,
        themeIndex = 1,
        viewIndex = 1,
        compact = false,
        buttonStyle = "full",
        showTopControls = true,
        soundVolume = (config.uiSounds and config.uiSounds.volume) or (config.sounds and config.sounds.volume) or 0.5,
        columns = buildDefaultColumnSettings(columns or config.uiColumns or config.columnDefinitions),
        collapsedSections = {},
    }

    local loaded = readSerializedTable(config.uiSettingsFile or "ui_settings.db")
    if type(loaded) ~= "table" then
        return settings
    end

    if type(loaded.monitorTextScale) == "number" then
        settings.monitorTextScale = clamp(loaded.monitorTextScale, minScale, maxScale)
    end

    if type(loaded.themeIndex) == "number" and loaded.themeIndex >= 1 then
        settings.themeIndex = loaded.themeIndex
    end

    if type(loaded.viewIndex) == "number" and loaded.viewIndex >= 1 then
        settings.viewIndex = loaded.viewIndex
    end

    if type(loaded.compact) == "boolean" then
        settings.compact = loaded.compact
    end

    if loaded.buttonStyle == "short" then
        settings.buttonStyle = "short"
    end

    if type(loaded.showTopControls) == "boolean" then
        settings.showTopControls = loaded.showTopControls
    end

    if type(loaded.soundVolume) == "number" then
        settings.soundVolume = clamp(loaded.soundVolume, 0, 1)
    end

    if type(loaded.columns) == "table" then
        for columnId, visible in pairs(loaded.columns) do
            if settings.columns[columnId] ~= nil and type(visible) == "boolean" then
                settings.columns[columnId] = visible
            end
        end
    end

    if type(loaded.collapsedSections) == "table" then
        for key, value in pairs(loaded.collapsedSections) do
            if value == true then
                settings.collapsedSections[key] = true
            end
        end
    end

    return settings
end

function State.saveUiSettings(config, settings)
    writeSerializedTable(config.uiSettingsFile or "ui_settings.db", settings, "Cannot write UI settings file: ")
end

return State
