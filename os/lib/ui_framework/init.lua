local Ui = {}

local DEFAULT_VIEWS = {
    { id = "list", label = "LIST", type = "list" },
    { id = "table", label = "TABLE", type = "table" },
    { id = "charts", label = "CHARTS", type = "charts" },
}
local UI_ROOT = "/os/lib/ui_framework"
local THEMES = dofile(UI_ROOT .. "/themes.lua")
local MIN_NAME_WIDTH = 8
local TOP_BUTTON_Y = 1
local DEFAULT_COLUMNS = {
    { id = "ctrl",   title = "CTRL",     width = 6,  defaultVisible = false },
    { id = "side",   title = "SIDE",     width = 7,  defaultVisible = false },
    { id = "link",   title = "LINK",     width = 6,  defaultVisible = false },
    { id = "uptime", title = "AGE",      width = 7,  defaultVisible = false },
    { id = "stock",  title = "RS STOCK", width = 12 },
    { id = "rate",   title = "ITEMS/H",  width = 12 },
    { id = "state",  title = "STATE",    width = 8, required = true },
}
local DEFAULT_ACTION_BUTTONS = {
    full = {
        { id = "all_on",         x = 2,  width = 6, label = " ON ",   fg = colors.black, bg = colors.green },
        { id = "all_off",        x = 9,  width = 7, label = " OFF ",  fg = colors.white, bg = colors.red },
        { id = "emergency_stop", x = 17, width = 8, label = " STOP ", fg = colors.white, bg = colors.orange },
    },
    short = {
        { id = "all_on",         x = 2,  width = 4, label = " A+ ", fg = colors.black, bg = colors.green },
        { id = "all_off",        x = 7,  width = 4, label = " A- ", fg = colors.white, bg = colors.red },
        { id = "emergency_stop", x = 12, width = 4, label = " ! ",  fg = colors.white, bg = colors.orange },
    },
}
local DEFAULT_SOUNDS = {
    menu = { name = "minecraft:block.note_block.hat", pitch = 1.2 },
    settings = { name = "minecraft:block.note_block.hat", pitch = 1.2 },
    toggle_on = { name = "minecraft:block.note_block.hat", pitch = 1.45 },
    toggle_off = { name = "minecraft:block.note_block.hat", pitch = 0.95 },
    locked = { name = "minecraft:block.note_block.basedrum", pitch = 0.7 },
    error = { name = "minecraft:block.note_block.basedrum", pitch = 0.5 },
}

local function resolveSoundConfig(config)
    local soundConfig = config.uiSounds or config.sounds or {}

    if soundConfig == false or soundConfig.enabled == false then
        return {
            enabled = false,
            sounds = {},
        }
    end

    local resolved = {
        enabled = true,
        volume = soundConfig.volume or 0.5,
        volumeStep = soundConfig.volumeStep or 0.1,
        speakerSide = soundConfig.speakerSide,
        sounds = {},
    }

    for id, sound in pairs(DEFAULT_SOUNDS) do
        resolved.sounds[id] = {
            name = sound.name,
            volume = sound.volume,
            pitch = sound.pitch,
        }
    end

    if type(soundConfig.sounds) == "table" then
        for id, sound in pairs(soundConfig.sounds) do
            if type(sound) == "string" then
                resolved.sounds[id] = {
                    name = sound,
                }
            elseif type(sound) == "table" and type(sound.name) == "string" then
                resolved.sounds[id] = {
                    name = sound.name,
                    volume = sound.volume,
                    pitch = sound.pitch,
                }
            end
        end
    end

    return resolved
end

local function findSpeaker(side)
    if side then
        local ok, speaker = pcall(peripheral.wrap, side)
        if ok and speaker and type(speaker.playSound) == "function" then
            return speaker
        end
    end

    local ok, speaker = pcall(peripheral.find, "speaker")
    if ok and speaker then
        return speaker
    end

    return nil
end

local function fillLine(monitor, y, bg)
    local width = monitor.getSize()

    monitor.setCursorPos(1, y)
    monitor.setBackgroundColor(bg)
    monitor.write(string.rep(" ", width))
end

local function writeAt(monitor, x, y, text, fg, bg)
    monitor.setCursorPos(x, y)
    monitor.setTextColor(fg)
    monitor.setBackgroundColor(bg)
    monitor.write(text)
end

local function writeClipped(monitor, x, y, text, maxWidth, fg, bg)
    local value = text or ""

    if maxWidth <= 0 then
        return
    end

    if #value > maxWidth then
        value = string.sub(value, 1, maxWidth)
    end

    writeAt(monitor, x, y, value, fg, bg)
end

local function drawEmptyState(monitor, theme, x, y, regionWidth, regionHeight, message, iconChar, accentColor)
    if regionWidth <= 0 or regionHeight <= 0 then
        return
    end

    iconChar = iconChar or string.char(15)
    accentColor = accentColor or theme.headerBg

    monitor.setBackgroundColor(theme.pageBg)
    for row = 0, regionHeight - 1 do
        monitor.setCursorPos(x, y + row)
        monitor.write(string.rep(" ", regionWidth))
    end

    local iconY = y + math.floor((regionHeight - 1) / 2) - 1
    if iconY < y then
        iconY = y
    end
    local labelY = iconY + 2
    if labelY > y + regionHeight - 1 then
        labelY = y + regionHeight - 1
    end

    local iconX = x + math.floor((regionWidth - 1) / 2)
    monitor.setCursorPos(iconX, iconY)
    monitor.setTextColor(accentColor)
    monitor.setBackgroundColor(theme.pageBg)
    monitor.write(iconChar)

    local text = tostring(message or "")
    if #text > regionWidth then
        text = string.sub(text, 1, regionWidth)
    end
    local labelX = x + math.floor((regionWidth - #text) / 2)
    if labelX < x then
        labelX = x
    end
    monitor.setCursorPos(labelX, labelY)
    monitor.setTextColor(theme.mutedFg or theme.rowFg)
    monitor.setBackgroundColor(theme.pageBg)
    monitor.write(text)
end

local function drawCell(monitor, x, y, width, text, fg, bg)
    if width <= 0 then
        return
    end

    monitor.setCursorPos(x, y)
    monitor.setBackgroundColor(bg)
    monitor.write(string.rep(" ", width))
    writeClipped(monitor, x + 1, y, text, width - 2, fg, bg)
end

local function drawStatus(monitor, x, y, width, enabled, onLabel, offLabel)
    local text = onLabel or " ON "
    local bg = colors.green
    local fg = colors.black

    if not enabled then
        text = offLabel or " OFF "
        bg = colors.red
        fg = colors.white
    end

    drawCell(monitor, x, y, width, text, fg, bg)
end

local function drawButton(monitor, button)
    monitor.setCursorPos(button.x, button.y)
    monitor.setBackgroundColor(button.bg)
    monitor.write(string.rep(" ", button.width))
    writeAt(monitor, button.x, button.y, button.label, button.fg, button.bg)
end

local function addButton(buttons, id, x, y, width, label, fg, bg)
    if x > 0 then
        table.insert(buttons, {
            id = id,
            x = x,
            y = y,
            width = width,
            label = label,
            fg = fg,
            bg = bg,
        })
    end
end

local function appendTopButton(buttons, screenWidth, nextX, id, label, fg, bg)
    local buttonWidth = #label

    if nextX + buttonWidth - 1 <= screenWidth then
        addButton(buttons, id, nextX, TOP_BUTTON_Y, buttonWidth, label, fg, bg)
        return nextX + buttonWidth + 1
    end

    return nextX
end

local function appendFixedButton(buttons, screenWidth, x, id, label, fg, bg)
    if x > 0 and x + #label - 1 <= screenWidth then
        addButton(buttons, id, x, TOP_BUTTON_Y, #label, label, fg, bg)
    end
end

local function buttonContains(button, x, y)
    return y == button.y and x >= button.x and x < button.x + button.width
end

local function drawButtons(monitor, buttons, screenWidth)
    local visibleButtons = {}

    for _, button in ipairs(buttons) do
        if button.x <= screenWidth then
            drawButton(monitor, button)
            table.insert(visibleButtons, button)
        end
    end

    return visibleButtons
end

local function clampScroll(scrollOffset, maxScroll)
    if maxScroll < 0 then
        maxScroll = 0
    end

    if scrollOffset > maxScroll then
        return maxScroll
    end

    return scrollOffset
end

local function normalizeViews(views)
    local normalized = {}

    if type(views) == "table" then
        for _, view in ipairs(views) do
            if type(view) == "string" then
                table.insert(normalized, {
                    id = string.lower(view),
                    label = view,
                    type = string.lower(view),
                })
            elseif type(view) == "table" then
                local label = view.label or view.id
                if type(label) == "string" then
                    table.insert(normalized, {
                        id = view.id or string.lower(label),
                        label = label,
                        type = view.type or string.lower(label),
                        renderer = view.renderer,
                    })
                end
            end
        end
    end

    if #normalized == 0 then
        for _, view in ipairs(DEFAULT_VIEWS) do
            table.insert(normalized, view)
        end
    end

    return normalized
end

local function normalizeColumns(columns)
    local normalized = {}

    if type(columns) == "table" then
        for _, column in ipairs(columns) do
            if type(column) == "table" and type(column.id) == "string" then
                table.insert(normalized, {
                    id = column.id,
                    title = column.title or string.upper(column.id),
                    width = column.width or 10,
                    required = column.required == true,
                    defaultVisible = column.defaultVisible,
                    kind = column.kind,
                    buttonPrefix = column.buttonPrefix,
                    buttonFg = column.buttonFg,
                    buttonBg = column.buttonBg,
                    value = column.value,
                })
            end
        end
    end

    if #normalized == 0 then
        for _, column in ipairs(DEFAULT_COLUMNS) do
            table.insert(normalized, column)
        end
    end

    return normalized
end

local function buildColumnSettings(columns)
    local settings = {}

    for _, column in ipairs(columns) do
        if column.defaultVisible == false then
            settings[column.id] = false
        else
            settings[column.id] = true
        end
    end

    return settings
end

local function getSections(data, config)
    if type(data) == "table" and type(data.sections) == "table" then
        return data.sections
    end

    if type(data) == "table" and type(data.groups) == "table" then
        return data.groups
    end

    if type(data) == "table" and type(data.rows) == "table" then
        return {
            {
                title = data.title or "",
                rows = data.rows,
            },
        }
    end

    return config.groups or config.sections or {}
end

local function getSectionRows(section)
    return section.rows or section.items or section.devices or {}
end

local function sectionKey(group, index)
    return group.id or group.key or group.title or group.label or ("section_" .. tostring(index))
end

local function buildListRows(sections, compact, collapsedSections)
    local rows = {}
    collapsedSections = collapsedSections or {}

    for index, group in ipairs(sections) do
        local title = group.title or group.label or ""
        local key = sectionKey(group, index)
        local collapsed = collapsedSections[key] == true

        table.insert(rows, { type = "section", title = title, key = key, collapsed = collapsed, group = group })

        if not collapsed then
            if not compact then
                table.insert(rows, { type = "columns" })
            end

            for _, row in ipairs(getSectionRows(group)) do
                table.insert(rows, { type = "device", device = row })
            end

            if not compact then
                table.insert(rows, { type = "blank" })
            end
        end
    end

    return rows
end

local function buildVisibleColumns(columnSettings, columnDefinitions)
    local visibleColumns = {}

    for _, column in ipairs(columnDefinitions) do
        if column.required or columnSettings[column.id] ~= false then
            table.insert(visibleColumns, column)
        end
    end

    return visibleColumns
end

local function buildColumnLayout(screenWidth, columns)
    local layout = {}
    local nextX = screenWidth + 1

    for index = #columns, 1, -1 do
        local column = columns[index]
        nextX = nextX - column.width
        layout[column.id] = {
            x = nextX,
            width = column.width,
            title = column.title,
        }
    end

    return layout, nextX
end

local function formatDuration(seconds)
    if type(seconds) ~= "number" or seconds < 0 then
        return "--"
    end

    if seconds < 60 then
        return tostring(seconds) .. "s"
    elseif seconds < 3600 then
        return tostring(math.floor(seconds / 60)) .. "m"
    end

    return tostring(math.floor(seconds / 3600)) .. "h"
end

local function getColumnValue(column, device, deviceUptime, rsStock, controllerStatus, history, context)
    local columnId = column.id

    if type(column.value) == "function" then
        local ok, value = pcall(column.value, device, context)
        if ok and value ~= nil then
            return tostring(value)
        end
    end

    if context and context.hooks and type(context.hooks.getCellValue) == "function" then
        local ok, value = pcall(context.hooks.getCellValue, device, columnId, context)
        if ok and value ~= nil then
            return tostring(value)
        end
    end

    if type(device) == "table" then
        if type(device.cells) == "table" and device.cells[columnId] ~= nil then
            return tostring(device.cells[columnId])
        end

        if device[columnId] ~= nil then
            return tostring(device[columnId])
        end
    end

    if columnId == "ctrl" then
        if device.controller ~= nil then
            return tostring(device.controller)
        end

        return "--"
    elseif columnId == "side" then
        return device.side or "--"
    elseif columnId == "link" then
        local controller = device.controller
        local status = controllerStatus and controllerStatus[controller]

        if not status or not status.lastSeen then
            return "--"
        end

        local now = os.epoch and math.floor(os.epoch("utc") / 1000) or math.floor(os.clock())
        if now - status.lastSeen <= 20 then
            return "OK"
        end

        return "OLD"
    elseif columnId == "uptime" then
        local now = os.epoch and math.floor(os.epoch("utc") / 1000) or math.floor(os.clock())
        local since = deviceUptime and deviceUptime.since

        if not since then
            return "--"
        end

        return formatDuration(now - since)
    elseif columnId == "stock" then
        if device.rsStockKey and rsStock and rsStock[device.rsStockKey] ~= nil then
            return tostring(rsStock[device.rsStockKey])
        end

        return "--"
    elseif columnId == "rate" then
        if not device.rsStockKey or not history or not history[device.rsStockKey] or #history[device.rsStockKey] < 2 then
            return "--/h"
        end

        local itemHistory = history[device.rsStockKey]
        local latest = itemHistory[#itemHistory]
        local earliest = itemHistory[1]

        local deltaItems = latest.count - earliest.count
        local deltaTime = latest.time - earliest.time

        if deltaTime <= 0 then
            return "0/h"
        end

        local itemsPerHour = math.floor((deltaItems / deltaTime) * 3600)
        local sign = ""
        if itemsPerHour > 0 then
            sign = "+"
        end

        return sign .. tostring(itemsPerHour) .. "/h"
    end

    return "--"
end

function Ui.create(monitor, config)
    local columnDefinitions = normalizeColumns(config.uiColumns or config.columnDefinitions)
    local views = normalizeViews(config.uiViews or config.views)
    local columnSettings = buildColumnSettings(columnDefinitions)
    local soundConfig = resolveSoundConfig(config)

    -- Подключаем общую библиотеку скроллбара; pcall на случай если файла
    -- нет на старой инсталляции — фреймворк должен работать и без него.
    local Scrollbar = nil
    local okSb, mod = pcall(dofile, "/os/lib/scrollbar.lua")
    if okSb and type(mod) == "table" then Scrollbar = mod end

    local self = {
        monitor = monitor,
        config = config,
        soundConfig = soundConfig,
        speaker = findSpeaker(soundConfig.speakerSide),
        columnDefinitions = columnDefinitions,
        views = views,
        hooks = config.uiHooks or config.hooks or {},
        actionButtons = config.actionButtons or DEFAULT_ACTION_BUTTONS,
        enableComputersMenu = config.enableComputersMenu ~= false and type(config.computers) == "table",
        enableCompact = config.enableCompact ~= false,
        listRows = nil,
        listRowsCompact = nil,
        deviceRows = {},
        buttons = {},
        topButtons = {},
        modalButtons = {},
        cellButtons = {},
        message = "",
        themeIndex = 1,
        viewIndex = 1,
        pageIndex = 1,
        compact = false,
        buttonStyle = "full",
        showTopControls = true,
        columns = columnSettings,
        modal = nil,
        rebootTarget = nil,
        settingsScroll = 0,
        scrollOffset = 0,
        collapsedSections = {},
        sectionHits = {},
        scrollbar = Scrollbar and Scrollbar.create({
            thumbBg = colors.cyan,
            thumbFg = colors.black,
        }) or nil,
        lastScrollBounds = nil,  -- сохраняем для hit-test между draw'ами
    }

    function self.setSpeaker(speaker)
        self.speaker = speaker
    end

    function self.refreshSpeaker()
        self.speaker = findSpeaker(self.soundConfig.speakerSide)
        return self.speaker ~= nil
    end

    function self.playSound(soundId)
        if not self.soundConfig.enabled then
            return false
        end

        local sound = self.soundConfig.sounds[soundId]
        if not sound then
            sound = self.soundConfig.sounds.menu
        end

        if not sound or not sound.name then
            return false
        end

        if not self.speaker then
            self.refreshSpeaker()
        end

        if not self.speaker then
            return false
        end

        local volume = self.soundConfig.volume
        if type(sound.volume) == "number" then
            volume = volume * sound.volume
        end

        if volume < 0 then
            volume = 0
        elseif volume > 1 then
            volume = 1
        end

        local ok = pcall(self.speaker.playSound, sound.name, volume, sound.pitch)
        return ok == true
    end

    function self.setSoundVolume(volume)
        if type(volume) ~= "number" then
            return self.soundConfig.volume
        end

        if volume < 0 then
            volume = 0
        elseif volume > 1 then
            volume = 1
        end

        self.soundConfig.volume = volume
        return self.soundConfig.volume
    end

    function self.changeSoundVolume(delta)
        local step = delta or self.soundConfig.volumeStep or 0.1
        return self.setSoundVolume(self.soundConfig.volume + step)
    end

    function self.getSoundVolume()
        return self.soundConfig.volume
    end

    function self.setThemeIndex(themeIndex)
        if type(themeIndex) == "number" and THEMES[themeIndex] then
            self.themeIndex = themeIndex
        end
    end

    function self.setViewIndex(viewIndex)
        if type(viewIndex) == "number" and self.views[viewIndex] then
            self.viewIndex = viewIndex
        end
    end

    function self.getSettings()
        local columns = {}

        for _, column in ipairs(self.columnDefinitions) do
            columns[column.id] = column.required or self.columns[column.id] ~= false
        end

        local collapsedSections = {}
        for key, value in pairs(self.collapsedSections) do
            if value == true then
                collapsedSections[key] = true
            end
        end

        return {
            viewModeVersion = 2,
            themeIndex = self.themeIndex,
            viewIndex = self.viewIndex,
            compact = self.compact,
            buttonStyle = self.buttonStyle,
            showTopControls = self.showTopControls,
            soundVolume = self.soundConfig.volume,
            columns = columns,
            collapsedSections = collapsedSections,
        }
    end

    function self.setButtonStyle(buttonStyle)
        if buttonStyle == "short" then
            self.buttonStyle = "short"
        else
            self.buttonStyle = "full"
        end
    end

    function self.toggleButtonStyle()
        if self.buttonStyle == "short" then
            self.buttonStyle = "full"
        else
            self.buttonStyle = "short"
        end

        return self.buttonStyle
    end

    function self.setShowTopControls(showTopControls)
        self.showTopControls = showTopControls ~= false
    end

    function self.toggleTopControls()
        self.showTopControls = not self.showTopControls
        return self.showTopControls
    end

    function self.setColumns(columns)
        if type(columns) ~= "table" then
            return
        end

        for _, column in ipairs(self.columnDefinitions) do
            if not column.required and type(columns[column.id]) == "boolean" then
                self.columns[column.id] = columns[column.id]
            end
        end
    end

    function self.toggleColumn(columnId)
        for _, column in ipairs(self.columnDefinitions) do
            if column.id == columnId and not column.required then
                self.columns[columnId] = not self.columns[columnId]
                return self.columns[columnId]
            end
        end

        return true
    end

    function self.getTheme()
        return THEMES[self.themeIndex]
    end

    function self.setThemeByIndex(themeIndex)
        if type(themeIndex) == "number" and THEMES[themeIndex] then
            self.themeIndex = themeIndex
        end

        self.modal = nil
        return self.getTheme().name
    end

    function self.openThemeMenu()
        self.modal = "themes"
    end

    function self.openSettingsMenu()
        self.modal = "settings"
        self.settingsScroll = 0
    end

    function self.openComputersMenu()
        self.modal = "computers"
        self.rebootTarget = nil
    end

    function self.openRebootConfirm(computerId)
        self.modal = "confirm_reboot"
        self.rebootTarget = computerId
    end

    function self.openStopConfirm()
        self.modal = "confirm_stop"
    end

    function self.closeModal()
        self.modal = nil
        self.rebootTarget = nil
    end

    function self.scrollSettings(delta)
        self.settingsScroll = self.settingsScroll + delta

        if self.settingsScroll < 0 then
            self.settingsScroll = 0
        end
    end

    function self.getView()
        local view = self.views[self.viewIndex]
        if view then
            return view.label
        end

        return "--"
    end

    function self.getViewDefinition()
        return self.views[self.viewIndex] or self.views[1]
    end

    function self.nextView()
        self.viewIndex = self.viewIndex + 1
        self.scrollOffset = 0
        self.pageIndex = 1

        if self.viewIndex > #self.views then
            self.viewIndex = 1
        end

        return self.getView()
    end

    function self.page(delta)
        local pageCount = #(self.config.groups or self.config.sections or {})
        if pageCount < 1 then
            pageCount = 1
        end

        self.pageIndex = self.pageIndex + delta
        self.scrollOffset = 0

        if self.pageIndex < 1 then
            self.pageIndex = pageCount
        elseif self.pageIndex > pageCount then
            self.pageIndex = 1
        end
    end

    function self.toggleCompact()
        self.compact = not self.compact
        return self.compact
    end

    function self.setCompact(compact)
        self.compact = compact == true
    end

    function self.getListRows(sections)
        return buildListRows(sections, self.compact, self.collapsedSections)
    end

    function self.toggleSectionCollapse(key)
        if type(key) ~= "string" and type(key) ~= "number" then
            return false
        end

        if self.collapsedSections[key] then
            self.collapsedSections[key] = nil
            return false
        end

        self.collapsedSections[key] = true
        self.scrollOffset = 0
        return true
    end

    function self.isSectionCollapsed(key)
        return self.collapsedSections[key] == true
    end

    function self.setCollapsedSections(map)
        self.collapsedSections = {}
        if type(map) ~= "table" then
            return
        end

        for key, value in pairs(map) do
            if value == true then
                self.collapsedSections[key] = true
            end
        end
    end

    function self.scroll(delta)
        self.scrollOffset = self.scrollOffset + delta

        if self.scrollOffset < 0 then
            self.scrollOffset = 0
        end
    end

    -- Возвращает true если клик попал в scrollbar и был обработан.
    -- Должно вызываться приложением в onEvent перед hitTest.
    function self.handleScrollbarClick(x, y)
        if not self.scrollbar then return false end
        local b = self.lastScrollBounds
        if not b then return false end
        self.scrollbar:setBounds(b.x, b.topY, b.bottomY)
        self.scrollbar:setContent(b.visibleRows, b.contentLen)
        self.scrollbar:setScroll(self.scrollOffset)
        if self.scrollbar:onClick(x, y) then
            self.scrollOffset = self.scrollbar.scroll
            return true
        end
        return false
    end

    function self.handleScrollbarDrag(x, y)
        if not self.scrollbar then return false end
        local b = self.lastScrollBounds
        if not b then return false end
        self.scrollbar:setBounds(b.x, b.topY, b.bottomY)
        self.scrollbar:setContent(b.visibleRows, b.contentLen)
        self.scrollbar:setScroll(self.scrollOffset)
        if self.scrollbar:onDrag(x, y) then
            self.scrollOffset = self.scrollbar.scroll
            return true
        end
        return false
    end

    function self.setMessage(message)
        self.message = message or ""
    end

    function self.draw(state, uptime, rsStock, controllerStatus, history)
        local data = {}

        if type(state) == "table" and (state.sections or state.groups or state.rows or state.state) then
            data = state
            state = data.state or {}
            uptime = data.uptime or {}
            rsStock = data.rsStock or data.stock or {}
            controllerStatus = data.controllerStatus or {}
            history = data.history or {}

            if type(data.message) == "string" then
                self.message = data.message
            end
        end

        uptime = uptime or {}
        rsStock = rsStock or {}
        controllerStatus = controllerStatus or {}
        history = history or {}

        local sections = getSections(data, self.config)
        local theme = self.getTheme()
        local width, height = self.monitor.getSize()

        if width < 14 or height < 7 then
            self.monitor.setBackgroundColor(theme.pageBg)
            self.monitor.clear()
            fillLine(self.monitor, 1, theme.headerBg)
            writeAt(self.monitor, 1, 1, string.sub(self.config.title or "FACTORY", 1, width), theme.headerFg, theme.headerBg)
            if self.hooks and type(self.hooks.drawMinimal) == "function" then
                pcall(self.hooks.drawMinimal, { monitor = self.monitor, ui = self, theme = theme, width = width, height = height, data = data })
            elseif height >= 3 then
                writeAt(self.monitor, 1, 2, string.sub("Screen too small", 1, width), theme.mutedFg, theme.pageBg)
            end
            self.buttons = {}
            self.topButtons = {}
            self.modalButtons = {}
            self.cellButtons = {}
            return
        end

        local buttonY = height - 3
        local contentTop = 3
        local contentBottom = buttonY - 2
        local visibleColumns = buildVisibleColumns(self.columns, self.columnDefinitions)
        -- Резервируем правую колонку под scrollbar — даже если он не виден
        -- (когда maxScroll=0), это даёт стабильный layout без рывков.
        local layoutWidth = (self.scrollbar and width - 1) or width
        local columnLayout, firstColumnX = buildColumnLayout(layoutWidth, visibleColumns)
        local nameWidth = firstColumnX - 4
        local view = self.getView()
        local viewDefinition = self.getViewDefinition()
        local viewType = viewDefinition and viewDefinition.type or string.lower(view)
        local compact = self.compact
        local maxScroll = 0
        local drawContext = {
            monitor = self.monitor,
            ui = self,
            config = self.config,
            data = data,
            state = state,
            uptime = uptime,
            rsStock = rsStock,
            controllerStatus = controllerStatus,
            history = history,
            sections = sections,
            theme = theme,
            width = width,
            height = height,
            contentTop = contentTop,
            contentBottom = contentBottom,
            buttonY = buttonY,
            columns = visibleColumns,
            columnLayout = columnLayout,
            hooks = self.hooks,
            fillLine = fillLine,
            writeAt = writeAt,
            writeClipped = writeClipped,
            drawCell = drawCell,
            drawButton = drawButton,
            drawEmptyState = function(message, iconChar, accentColor)
                drawEmptyState(self.monitor, theme, 1, contentTop, width, contentBottom - contentTop + 1,
                    message, iconChar, accentColor)
            end,
            addButton = function(button)
                table.insert(self.buttons, button)
                drawButton(self.monitor, button)
            end,
            addCellButton = function(button)
                table.insert(self.cellButtons, button)
                drawButton(self.monitor, button)
            end,
            addRowHit = function(y, id)
                self.deviceRows[y] = id
            end,
        }
        drawContext.view = viewDefinition
        drawContext.viewType = viewType

        if nameWidth < MIN_NAME_WIDTH then
            nameWidth = MIN_NAME_WIDTH
        end

        self.deviceRows = {}
        self.buttons = {}
        self.topButtons = {}
        self.modalButtons = {}
        self.cellButtons = {}
        self.sectionHits = {}

        self.monitor.setBackgroundColor(theme.pageBg)
        self.monitor.setTextColor(theme.rowFg)
        self.monitor.clear()

        fillLine(self.monitor, 1, theme.headerBg)
        local title = self.config.title or "FACTORY"
        local titleLabel = " " .. title .. " "
        if self.modal == "settings" then
            titleLabel = " *" .. title .. "* "
        end

        local titleX = math.floor((width - #titleLabel) / 2) + 1
        local titleButton = {
            id = "settings",
            x = titleX,
            y = TOP_BUTTON_Y,
            width = #titleLabel,
            label = titleLabel,
            fg = colors.black,
            bg = colors.white,
        }
        drawButton(self.monitor, titleButton)
        table.insert(self.topButtons, titleButton)

        if self.showTopControls then
            local compactLabel = " D "
            if compact then
                compactLabel = " D*"
            end

            local viewLabel = " V:" .. view .. " "
            local themeLabel = "[T:" .. theme.name .. "]"
            if self.modal == "themes" then
                themeLabel = "[T:*" .. theme.name .. "]"
            end

            if self.buttonStyle == "short" then
                viewLabel = " V "
                themeLabel = " T "
            end

            local topGap = 1
            local computersLabel = " C "
            local topWidth = #viewLabel + #themeLabel + topGap

            if self.enableCompact then
                topWidth = topWidth + #compactLabel + topGap
            end
            if self.enableComputersMenu then
                topWidth = topWidth + #computersLabel + topGap
            end

            local nextTopX = width - topWidth + 1

            appendFixedButton(self.topButtons, width, 1, "scale_down", " - ", colors.white, colors.gray)
            appendFixedButton(self.topButtons, width, 5, "scale_up", " + ", colors.white, colors.gray)
            nextTopX = appendTopButton(self.topButtons, width, nextTopX, "view", viewLabel, colors.black, colors.yellow)

            if self.enableCompact then
                nextTopX = appendTopButton(self.topButtons, width, nextTopX, "compact", compactLabel, colors.black,
                    colors.lime)
            end
            nextTopX = appendTopButton(self.topButtons, width, nextTopX, "theme", themeLabel, colors.black, colors
                .yellow)
            if self.enableComputersMenu then
                appendTopButton(self.topButtons, width, nextTopX, "computers", computersLabel, colors.black, colors
                    .lightBlue)
            end
        end

        self.topButtons = drawButtons(self.monitor, self.topButtons, width)

        local function drawSection(y, title, key, collapsed, onCount, total, bulkActionsEnabled)
            fillLine(self.monitor, y, theme.sectionBg)
            local indicator = string.char(31)
            if collapsed then
                indicator = string.char(16)
            end
            writeAt(self.monitor, 1, y, indicator, theme.headerFg, theme.headerBg)
            writeAt(self.monitor, 2, y, " " .. title .. " ", theme.sectionFg, theme.sectionBg)
            if key ~= nil then
                self.sectionHits[y] = key
            end

            if bulkActionsEnabled ~= false and total and total > 0 and key ~= nil then
                local screenWidth = width
                local btnWidth = 4
                local onBtnX = screenWidth - (btnWidth * 2)
                local offBtnX = screenWidth - btnWidth + 1
                local minRoomAfterTitle = #title + 4 + 8

                if onBtnX > minRoomAfterTitle then
                    local onBtn = {
                        id = "section_on_" .. tostring(key),
                        x = onBtnX,
                        y = y,
                        width = btnWidth,
                        label = " ON ",
                        fg = colors.black,
                        bg = colors.green,
                    }
                    local offBtn = {
                        id = "section_off_" .. tostring(key),
                        x = offBtnX,
                        y = y,
                        width = btnWidth,
                        label = " OFF",
                        fg = colors.white,
                        bg = colors.red,
                    }

                    drawButton(self.monitor, onBtn)
                    drawButton(self.monitor, offBtn)
                    table.insert(self.buttons, onBtn)
                    table.insert(self.buttons, offBtn)

                    local badgeText = " " .. tostring(onCount) .. "/" .. tostring(total) .. " "
                    local badgeX = onBtnX - #badgeText - 1
                    if badgeX > #title + 4 then
                        local badgeBg, badgeFg
                        if onCount == 0 then
                            badgeBg = colors.gray
                            badgeFg = colors.white
                        elseif onCount == total then
                            badgeBg = colors.lime
                            badgeFg = colors.black
                        else
                            badgeBg = colors.yellow
                            badgeFg = colors.black
                        end
                        writeAt(self.monitor, badgeX, y, badgeText, badgeFg, badgeBg)
                    end
                end
            end
        end

        local function drawColumns(y)
            fillLine(self.monitor, y, theme.columnBg)

            for _, column in ipairs(visibleColumns) do
                local columnInfo = columnLayout[column.id]
                drawCell(self.monitor, columnInfo.x, y, columnInfo.width, columnInfo.title, theme.columnFg,
                    theme.columnBg)
            end
        end

        local function drawDevice(y, device, rowIndex)
            local rowBg = theme.rowA
            if rowIndex % 2 == 0 then
                rowBg = theme.rowB
            end

            if self.hooks and type(self.hooks.drawRow) == "function" then
                local ok, handled = pcall(self.hooks.drawRow, drawContext, y, device, rowIndex, rowBg)
                if ok and handled then
                    if device.id then
                        self.deviceRows[y] = device.id
                    end
                    return
                end
            end

            fillLine(self.monitor, y, rowBg)
            local indicatorFg = state[device.id] and colors.lime or theme.lineFg
            writeAt(self.monitor, 1, y, "|", indicatorFg, rowBg)

            local controllerId = device.controller
            if controllerId ~= nil then
                local ctrlColor = colors.gray
                local ctrlInfo = controllerStatus and controllerStatus[controllerId]
                if ctrlInfo and ctrlInfo.lastSeen then
                    local now = os.epoch and math.floor(os.epoch("utc") / 1000) or math.floor(os.clock())
                    local age = now - ctrlInfo.lastSeen
                    if age <= 20 then
                        ctrlColor = colors.lime
                    elseif age <= 60 then
                        ctrlColor = colors.orange
                    else
                        ctrlColor = colors.red
                    end
                end
                writeAt(self.monitor, 2, y, string.char(7), ctrlColor, rowBg)
            end

            local labelX = 3
            local label = device.label or device.name or device.id or ""
            if device.indent == 1 then
                labelX = 5
                label = "- " .. label
            end

            writeClipped(self.monitor, labelX, y, label, nameWidth - (labelX - 3), theme.rowFg, rowBg)

            for _, column in ipairs(visibleColumns) do
                local columnInfo = columnLayout[column.id]

                if column.kind == "button" and device.id then
                    local buttonLabel = getColumnValue(column, device, uptime[device.id], rsStock, controllerStatus,
                        history, drawContext)
                    local button = {
                        id = (column.buttonPrefix or ("cell_" .. column.id .. "_")) .. device.id,
                        x = columnInfo.x,
                        y = y,
                        width = columnInfo.width,
                        label = buttonLabel,
                        fg = column.buttonFg or colors.black,
                        bg = column.buttonBg or colors.lightGray,
                    }

                    writeAt(self.monitor, columnInfo.x - 1, y, "|", theme.lineFg, rowBg)
                    table.insert(self.cellButtons, button)
                    drawButton(self.monitor, button)
                elseif column.id == "state" and column.kind ~= "text" then
                    writeAt(self.monitor, columnInfo.x - 1, y, "|", theme.lineFg, rowBg)
                    drawStatus(self.monitor, columnInfo.x, y, columnInfo.width, state[device.id], device.onLabel, device.offLabel)
                else
                    writeAt(self.monitor, columnInfo.x - 1, y, "|", theme.lineFg, rowBg)
                    writeClipped(
                        self.monitor,
                        columnInfo.x,
                        y,
                        getColumnValue(column, device, uptime[device.id], rsStock, controllerStatus, history,
                            drawContext),
                        columnInfo.width,
                        theme.mutedFg,
                        rowBg
                    )
                end
            end
            if device.id then
                self.deviceRows[y] = device.id
            end
        end

        local function drawCharts(y, device, rowIndex)
            local rowBg = theme.rowA
            if rowIndex % 2 == 0 then
                rowBg = theme.rowB
            end

            fillLine(self.monitor, y, rowBg)
            fillLine(self.monitor, y + 1, rowBg)

            local label = device.label or device.name or device.id or ""
            writeAt(self.monitor, 2, y, label, theme.rowFg, rowBg)

            local rate = getColumnValue({ id = "rate" }, device, uptime[device.id], rsStock, controllerStatus, history,
                drawContext)
            local stock = getColumnValue({ id = "stock" }, device, uptime[device.id], rsStock, controllerStatus, history,
                drawContext)
            writeAt(self.monitor, width - #rate - 1, y, rate, theme.mutedFg, rowBg)
            writeAt(self.monitor, width - #rate - #stock - 3, y, stock, theme.rowFg, rowBg)

            -- Отрисовка мини-графика
            local chartX = 2
            local chartY = y + 1
            local chartWidth = width - 4

            if device.rsStockKey and history and history[device.rsStockKey] and #history[device.rsStockKey] >= 2 then
                local h = history[device.rsStockKey]
                local minVal = h[1].count
                local maxVal = h[1].count

                for _, p in ipairs(h) do
                    if p.count < minVal then minVal = p.count end
                    if p.count > maxVal then maxVal = p.count end
                end

                local range = maxVal - minVal
                if range == 0 then range = 1 end

                local pointsToShow = #h
                if pointsToShow > chartWidth then pointsToShow = chartWidth end

                for i = 1, pointsToShow do
                    local p = h[#h - pointsToShow + i]
                    local barHeight = math.floor(((p.count - minVal) / range) * 1) -- Пока в 1 строку
                    local color = colors.gray
                    if i == pointsToShow then color = colors.white end

                    self.monitor.setCursorPos(chartX + i - 1, chartY)
                    if p.count > h[math.max(1, #h - pointsToShow + i - 1)].count then
                        self.monitor.setBackgroundColor(colors.green)
                    elseif p.count < h[math.max(1, #h - pointsToShow + i - 1)].count then
                        self.monitor.setBackgroundColor(colors.red)
                    else
                        self.monitor.setBackgroundColor(colors.gray)
                    end
                    self.monitor.write(" ")
                end
            else
                writeAt(self.monitor, chartX, chartY, "No history data yet...", colors.gray, rowBg)
            end

            if device.id then
                self.deviceRows[y] = device.id
                self.deviceRows[y + 1] = device.id
            end
        end

        local function drawRows(rows, startIndex)
            local y = contentTop
            local rowIndex = 0

            for index = startIndex, #rows do
                if y > contentBottom then
                    break
                end

                local row = rows[index]

                if row.type == "section" then
                    local onCount, total = 0, 0
                    if row.group then
                        for _, device in ipairs(getSectionRows(row.group)) do
                            if device.id then
                                total = total + 1
                                if state[device.id] then
                                    onCount = onCount + 1
                                end
                            end
                        end
                    end
                    local bulkActionsEnabled = not (row.group and row.group.disableBulkActions == true)
                    drawSection(y, row.title, row.key, row.collapsed, onCount, total, bulkActionsEnabled)
                    y = y + 1
                elseif row.type == "columns" then
                    drawColumns(y)
                    y = y + 1
                elseif row.type == "device" then
                    rowIndex = rowIndex + 1
                    drawDevice(y, row.device, rowIndex)
                    y = y + 1
                elseif row.type == "blank" then
                    fillLine(self.monitor, y, theme.pageBg)
                    y = y + 1
                end
            end
        end

        local customRendered = false
        if viewDefinition and type(viewDefinition.renderer) == "function" then
            local ok, rendered = pcall(viewDefinition.renderer, drawContext)
            customRendered = ok and rendered == true
        elseif self.hooks and type(self.hooks.drawView) == "function" then
            local ok, rendered = pcall(self.hooks.drawView, drawContext, viewType)
            customRendered = ok and rendered == true
        end

        if not customRendered then
            if viewType == "list" then
                local rows = self.getListRows(sections)
                local visibleRows = contentBottom - contentTop + 1
                maxScroll = #rows - visibleRows
                self.scrollOffset = clampScroll(self.scrollOffset, maxScroll)

                drawRows(rows, self.scrollOffset + 1)
            elseif viewType == "charts" then
                local allDevices = {}
                for _, group in ipairs(sections) do
                    for _, device in ipairs(getSectionRows(group)) do
                        if device.rsStockKey or device.chart then
                            table.insert(allDevices, device)
                        end
                    end
                end

                local visibleRows = math.floor((contentBottom - contentTop + 1) / 2)
                maxScroll = #allDevices - visibleRows
                self.scrollOffset = clampScroll(self.scrollOffset, maxScroll)

                local y = contentTop
                for i = self.scrollOffset + 1, #allDevices do
                    if y + 1 > contentBottom then break end
                    drawCharts(y, allDevices[i], i)
                    y = y + 2
                end
            elseif viewType == "table" then
                if self.pageIndex > #sections then
                    self.pageIndex = 1
                end

                local group = sections[self.pageIndex]
                local y = contentTop

                if group then
                    local groupRows = getSectionRows(group)
                    local pageKey = sectionKey(group, self.pageIndex)
                    local pageCollapsed = self.collapsedSections[pageKey] == true
                    local pageOnCount, pageTotal = 0, 0
                    for _, device in ipairs(groupRows) do
                        if device.id then
                            pageTotal = pageTotal + 1
                            if state[device.id] then
                                pageOnCount = pageOnCount + 1
                            end
                        end
                    end
                    drawSection(y,
                        (group.title or group.label or "") .. " " .. tostring(self.pageIndex) .. "/" ..
                        tostring(#sections),
                        pageKey,
                        pageCollapsed,
                        pageOnCount,
                        pageTotal,
                        not (group.disableBulkActions == true))
                    y = y + 1

                    if pageCollapsed then
                        groupRows = {}
                    end

                    if not compact then
                        drawColumns(y)
                        y = y + 1
                    end

                    local visibleRows = contentBottom - y + 1
                    local startDevice = 1

                    maxScroll = #groupRows - visibleRows
                    self.scrollOffset = clampScroll(self.scrollOffset, maxScroll)

                    startDevice = self.scrollOffset + 1

                    local rowIndex = 0
                    for index = startDevice, #groupRows do
                        if y > contentBottom then
                            break
                        end

                        rowIndex = rowIndex + 1
                        drawDevice(y, groupRows[index], rowIndex)
                        y = y + 1
                    end
                end
            end
        end

        local selectedActionButtons = self.actionButtons[self.buttonStyle] or self.actionButtons.full or {}
        for _, button in ipairs(selectedActionButtons) do
            table.insert(self.buttons, {
                id = button.id,
                x = button.x,
                y = buttonY,
                width = button.width,
                label = button.label,
                fg = button.fg,
                bg = button.bg,
            })
        end

        local navButtons = {}

        if viewType == "table" then
            table.insert(navButtons, { id = "page_prev", width = 4, label = "<<" })
            table.insert(navButtons, { id = "page_next", width = 4, label = ">>" })
        end

        if viewType == "list" or viewType == "table" or viewType == "charts" then
            table.insert(navButtons, { id = "scroll_up", width = 4, label = "UP" })
            table.insert(navButtons, { id = "scroll_down", width = 4, label = "DN" })
        end

        local navWidth = 0
        for _, button in ipairs(navButtons) do
            navWidth = navWidth + button.width + 1
        end

        local navX = width - navWidth + 2
        local minNavX = 27

        if navX < minNavX then
            navX = minNavX
        end

        for _, button in ipairs(navButtons) do
            table.insert(self.buttons, {
                id = button.id,
                x = navX,
                y = buttonY,
                width = button.width,
                label = button.label,
                fg = colors.white,
                bg = colors.gray,
            })
            navX = navX + button.width + 1
        end

        self.buttons = drawButtons(self.monitor, self.buttons, width)

        if self.message and self.message ~= "" then
            local accent = " " .. string.char(16) .. " "
            local body = " " .. self.message .. " "
            local maxBodyLen = width - #accent - 16
            if maxBodyLen < 4 then
                maxBodyLen = width - #accent - 2
            end
            if #body > maxBodyLen then
                body = string.sub(body, 1, maxBodyLen)
            end
            writeAt(self.monitor, 2, height - 1, accent, theme.headerFg, theme.headerBg)
            writeAt(self.monitor, 2 + #accent, height - 1, body, theme.columnFg, theme.columnBg)
        end

        -- Вертикальный скроллбар на правой кромке content area.
        -- Колонка зарезервирована всегда (buildColumnLayout с width-1),
        -- поэтому всегда рисуем track. Когда нечего скроллить — стрелки
        -- тускнеют, thumb не виден.
        if self.scrollbar and viewType ~= "dash" then
            local visibleRows = contentBottom - contentTop + 1
            local contentLen = visibleRows + math.max(0, maxScroll)
            self.scrollbar:setBounds(width, contentTop, contentBottom)
            self.scrollbar:setContent(visibleRows, contentLen)
            self.scrollbar:setScroll(self.scrollOffset)
            self.scrollbar:draw(self.monitor)
            self.lastScrollBounds = {
                x = width, topY = contentTop, bottomY = contentBottom,
                contentLen = contentLen, visibleRows = visibleRows,
            }
        else
            self.lastScrollBounds = nil
        end

        local function drawModalBox(title, boxWidth, boxHeight)
            local boxX = math.floor((width - boxWidth) / 2) + 1
            local boxY = math.floor((height - boxHeight) / 2) + 1

            for y = boxY, boxY + boxHeight - 1 do
                self.monitor.setCursorPos(boxX, y)
                self.monitor.setBackgroundColor(colors.black)
                self.monitor.write(string.rep(" ", boxWidth))
            end

            writeAt(self.monitor, boxX, boxY, "+" .. string.rep("-", boxWidth - 2) .. "+", colors.white, colors.black)

            for y = boxY + 1, boxY + boxHeight - 2 do
                writeAt(self.monitor, boxX, y, "|", colors.white, colors.black)
                writeAt(self.monitor, boxX + boxWidth - 1, y, "|", colors.white, colors.black)
            end

            writeAt(self.monitor, boxX, boxY + boxHeight - 1, "+" .. string.rep("-", boxWidth - 2) .. "+", colors.white,
                colors.black)
            drawCell(self.monitor, boxX + 1, boxY + 1, boxWidth - 2, title, colors.black, colors.white)
            addButton(self.modalButtons, "modal_close", boxX + boxWidth - 4, boxY, 4, " X ", colors.white, colors.red)
            drawButton(self.monitor, self.modalButtons[#self.modalButtons])

            return boxX, boxY
        end

        if self.modal == "themes" then
            local columnWidth = 16
            local columns = 2
            local boxWidth = (columnWidth * columns) + 4
            local rows = math.ceil(#THEMES / columns)
            local boxHeight = rows + 4
            local boxX, boxY = drawModalBox("THEMES", boxWidth, boxHeight)

            for index, themeOption in ipairs(THEMES) do
                local column = (index - 1) % columns
                local row = math.floor((index - 1) / columns)
                local button = {
                    id = "theme_select_" .. tostring(index),
                    x = boxX + 2 + (column * columnWidth),
                    y = boxY + row + 3,
                    width = columnWidth - 1,
                    label = " " .. themeOption.name .. " ",
                    fg = themeOption.themeButtonFg,
                    bg = themeOption.themeButtonBg,
                }

                if index == self.themeIndex then
                    button.label = string.char(16) .. " " .. themeOption.name .. " "
                end

                table.insert(self.modalButtons, button)
                drawButton(self.monitor, button)

                local chipX = button.x + button.width - 3
                if chipX > button.x + #button.label then
                    self.monitor.setCursorPos(chipX, button.y)
                    self.monitor.setBackgroundColor(themeOption.headerBg)
                    self.monitor.write(" ")
                    self.monitor.setBackgroundColor(themeOption.sectionBg)
                    self.monitor.write(" ")
                    self.monitor.setBackgroundColor(themeOption.rowB or themeOption.rowA)
                    self.monitor.write(" ")
                end
            end
        elseif self.modal == "settings" then
            local boxWidth = 48
            local boxHeight = height - 4

            if boxWidth > width - 2 then
                boxWidth = width - 2
            end

            if boxHeight > height - 2 then
                boxHeight = height - 2
            end

            if boxHeight < 9 then
                boxHeight = height - 2
            end

            local boxX, boxY = drawModalBox("SETTINGS", boxWidth, boxHeight)
            local styleLabel = " Buttons FULL "
            local topControlsLabel = " Top Bar ON "
            local compactButtonLabel = " Compact OFF "
            local soundLevel = self.soundConfig.volume
            if soundLevel < 0 then
                soundLevel = 0
            elseif soundLevel > 1 then
                soundLevel = 1
            end

            local soundPercent = math.floor((soundLevel * 100) + 0.5)
            local scaleLabel = tostring(self.config.monitorTextScale or "?") .. "x"

            if self.buttonStyle == "short" then
                styleLabel = " Buttons SHORT "
            end

            if not self.showTopControls then
                topControlsLabel = " Top Bar OFF "
            end

            if self.compact then
                compactButtonLabel = " Compact ON "
            end

            local settingsButtons = {}
            local contentX = boxX + 2
            local contentWidth = boxWidth - 7
            local panelX = 1
            local panelWidth = contentWidth - 2
            local scrollbarX = boxX + boxWidth - 3
            local splitWidth = math.floor((panelWidth - 1) / 2)
            local row = 1
            local sectionCount = 0

            local function addItem(item)
                item.row = item.row or row
                table.insert(settingsButtons, item)
            end

            local function addSection(title)
                if sectionCount > 0 then
                    addItem({ kind = "gap", width = contentWidth })
                    row = row + 1
                end

                addItem({ label = "  " .. title .. " ", kind = "section", width = contentWidth })
                row = row + 1
                sectionCount = sectionCount + 1
            end

            local function addButtonRow(id, label)
                addItem({ id = id, label = label, width = panelWidth, xOffset = panelX })
                row = row + 1
            end

            addSection("DISPLAY")
            addItem({ id = "scale_down", label = " - ", width = 5, xOffset = panelX, bg = colors.gray, fg = colors.white })
            addItem({
                label = " Scale " .. scaleLabel .. " ",
                kind = "info",
                width = panelWidth - 12,
                xOffset = panelX + 6,
                bg = colors.lightGray,
                fg = colors.black,
            })
            addItem({ id = "scale_up", label = " + ", width = 5, xOffset = panelX + panelWidth - 5, bg = colors.gray, fg = colors.white })
            row = row + 1
            if self.enableCompact then
                addItem({ id = "view", label = " View " .. view .. " ", width = splitWidth, xOffset = panelX, bg = colors.yellow, fg = colors.black })
                addItem({ id = "compact", label = compactButtonLabel, width = panelWidth - splitWidth - 1, xOffset = panelX + splitWidth + 1, bg = colors.lime, fg = colors.black })
            else
                addItem({ id = "view", label = " View " .. view .. " ", width = panelWidth, xOffset = panelX, bg = colors.yellow, fg = colors.black })
            end
            row = row + 1
            addItem({ id = "theme", label = " Theme " .. theme.name .. " ", width = splitWidth, xOffset = panelX, bg = colors.orange, fg = colors.black })
            addItem({ id = "toggle_button_style", label = styleLabel, width = panelWidth - splitWidth - 1, xOffset = panelX + splitWidth + 1, bg = colors.lightBlue, fg = colors.black })
            row = row + 1
            addButtonRow("toggle_top_controls", topControlsLabel)

            addSection("SOUND")
            addItem({ id = "sound_volume_down", label = " - ", width = 5, xOffset = panelX, bg = colors.gray, fg = colors.white })
            addItem({
                id = "sound_volume",
                label = " Volume " .. tostring(soundPercent) .. "% ",
                kind = "meter",
                value = soundLevel,
                width = panelWidth - 12,
                xOffset = panelX + 6,
            })
            addItem({ id = "sound_volume_up", label = " + ", width = 5, xOffset = panelX + panelWidth - 5, bg = colors.gray, fg = colors.white })
            row = row + 1

            addSection("SYSTEM")
            if self.enableComputersMenu then
                addButtonRow("computers", " Computers / reboot ")
            end
            addButtonRow("reboot_self", " Reboot Computer " .. tostring(os.getComputerID()) .. " ")

            addSection("COLUMNS")

            local columnChipWidth = panelWidth
            local columnChipCount = 1
            if panelWidth >= 34 then
                columnChipCount = 2
                columnChipWidth = math.floor((panelWidth - 1) / 2)
            end

            local columnChipIndex = 0
            for _, column in ipairs(self.columnDefinitions) do
                if not column.required then
                    local visible = self.columns[column.id] ~= false
                    local label = " " .. column.title .. " OFF "
                    local buttonBg = colors.gray
                    local buttonFg = colors.white

                    if visible then
                        label = " " .. column.title .. " ON "
                        buttonBg = colors.green
                        buttonFg = colors.black
                    end

                    addItem({
                        id = "toggle_column_" .. column.id,
                        label = label,
                        width = columnChipWidth,
                        xOffset = panelX + ((columnChipIndex % columnChipCount) * (columnChipWidth + 1)),
                        bg = buttonBg,
                        fg = buttonFg,
                    })
                    columnChipIndex = columnChipIndex + 1
                    if columnChipIndex % columnChipCount == 0 then
                        row = row + 1
                    end
                end
            end

            if columnChipIndex % columnChipCount ~= 0 then
                row = row + 1
            end

            local firstRow = 1 + self.settingsScroll
            local visibleRows = boxHeight - 5
            local maxSettingsRow = 0

            for _, button in ipairs(settingsButtons) do
                if button.row > maxSettingsRow then
                    maxSettingsRow = button.row
                end
            end

            local maxScroll = maxSettingsRow - visibleRows

            if maxScroll < 0 then
                maxScroll = 0
            end

            if self.settingsScroll > maxScroll then
                self.settingsScroll = maxScroll
                firstRow = 1 + self.settingsScroll
            end

            for _, button in ipairs(settingsButtons) do
                local visibleRow = button.row - firstRow + 1

                if visibleRow >= 1 and visibleRow <= visibleRows then
                    button.x = contentX + (button.xOffset or 0)
                    button.y = boxY + 2 + visibleRow
                    button.width = button.width or contentWidth

                    if button.kind == "section" then
                        drawCell(self.monitor, button.x, button.y, button.width, button.label, colors.white, colors.gray)
                    elseif button.kind == "gap" then
                        self.monitor.setCursorPos(button.x, button.y)
                        self.monitor.setBackgroundColor(colors.black)
                        self.monitor.write(string.rep(" ", button.width))
                    elseif button.kind == "info" then
                        drawCell(self.monitor, button.x, button.y, button.width, button.label, button.fg, button.bg)
                    elseif button.kind == "meter" then
                        local value = button.value or 0
                        local fillWidth = math.floor((button.width * value) + 0.5)

                        if fillWidth < 0 then
                            fillWidth = 0
                        elseif fillWidth > button.width then
                            fillWidth = button.width
                        end

                        self.monitor.setCursorPos(button.x, button.y)
                        self.monitor.setBackgroundColor(colors.gray)
                        self.monitor.write(string.rep(" ", button.width))

                        if fillWidth > 0 then
                            self.monitor.setCursorPos(button.x, button.y)
                            self.monitor.setBackgroundColor(colors.lightBlue)
                            self.monitor.write(string.rep(" ", fillWidth))
                        end

                        local meterLabel = button.label or ""
                        local labelWidth = #meterLabel
                        local labelX = button.x + math.floor((button.width - labelWidth) / 2)

                        if labelX < button.x then
                            labelX = button.x
                        end

                        for index = 1, labelWidth do
                            local charX = labelX + index - 1

                            if charX >= button.x and charX < button.x + button.width then
                                local charBg = colors.gray
                                if charX < button.x + fillWidth then
                                    charBg = colors.lightBlue
                                end

                                writeAt(self.monitor, charX, button.y, string.sub(meterLabel, index, index),
                                    colors.black, charBg)
                            end
                        end

                        table.insert(self.modalButtons, button)
                    else
                        button.fg = button.fg or colors.black
                        button.bg = button.bg or colors.yellow
                        table.insert(self.modalButtons, button)
                        drawButton(self.monitor, button)
                    end
                end
            end

            local scrollLabel = tostring(self.settingsScroll + 1) .. "/" .. tostring(maxScroll + 1)
            writeClipped(self.monitor, contentX, boxY + boxHeight - 2, scrollLabel, contentWidth, colors.lightGray,
                colors.black)

            for y = boxY + 2, boxY + boxHeight - 3 do
                writeAt(self.monitor, scrollbarX - 1, y, "|", colors.gray, colors.black)
            end

            local upButton = {
                id = "settings_scroll_up",
                x = scrollbarX,
                y = boxY + 3,
                width = 3,
                label = " ^ ",
                fg = colors.white,
                bg = colors.gray,
            }
            local downButton = {
                id = "settings_scroll_down",
                x = scrollbarX,
                y = boxY + boxHeight - 4,
                width = 3,
                label = " v ",
                fg = colors.white,
                bg = colors.gray,
            }

            if self.settingsScroll > 0 then
                table.insert(self.modalButtons, upButton)
                drawButton(self.monitor, upButton)
            end

            if self.settingsScroll < maxScroll then
                table.insert(self.modalButtons, downButton)
                drawButton(self.monitor, downButton)
            end
        elseif self.modal == "confirm_stop" then
            local boxWidth = 34
            local boxHeight = 8
            local boxX, boxY = drawModalBox("EMERGENCY STOP", boxWidth, boxHeight)

            writeAt(self.monitor, boxX + 2, boxY + 3, "Turn all saved states OFF?", colors.white, colors.black)

            local confirmButton = {
                id = "confirm_stop",
                x = boxX + 3,
                y = boxY + 5,
                width = 12,
                label = " CONFIRM ",
                fg = colors.white,
                bg = colors.red,
            }
            local cancelButton = {
                id = "cancel_stop",
                x = boxX + boxWidth - 14,
                y = boxY + 5,
                width = 11,
                label = " CANCEL ",
                fg = colors.black,
                bg = colors.lightGray,
            }

            table.insert(self.modalButtons, confirmButton)
            table.insert(self.modalButtons, cancelButton)
            drawButton(self.monitor, confirmButton)
            drawButton(self.monitor, cancelButton)
        elseif self.modal == "confirm_reboot" then
            local boxWidth = 36
            local boxHeight = 8
            local boxX, boxY = drawModalBox("REBOOT COMPUTER", boxWidth, boxHeight)
            local computerId = self.rebootTarget

            writeAt(self.monitor, boxX + 2, boxY + 3, "Reboot computer #" .. tostring(computerId) .. "?", colors.white,
                colors.black)

            local confirmButton = {
                id = "confirm_reboot_" .. tostring(computerId),
                x = boxX + 3,
                y = boxY + 5,
                width = 12,
                label = " REBOOT ",
                fg = colors.white,
                bg = colors.red,
            }
            local cancelButton = {
                id = "cancel_reboot",
                x = boxX + boxWidth - 14,
                y = boxY + 5,
                width = 11,
                label = " CANCEL ",
                fg = colors.black,
                bg = colors.lightGray,
            }

            table.insert(self.modalButtons, confirmButton)
            table.insert(self.modalButtons, cancelButton)
            drawButton(self.monitor, confirmButton)
            drawButton(self.monitor, cancelButton)
        elseif self.modal == "computers" then
            local boxWidth = 34
            local computerCount = #(self.config.computers or {})
            local boxHeight = computerCount + 4

            if boxHeight < 7 then
                boxHeight = 7
            end

            local boxX, boxY = drawModalBox("COMPUTERS", boxWidth, boxHeight)

            if computerCount == 0 then
                writeAt(self.monitor, boxX + 2, boxY + 3, "No computers configured", colors.lightGray, colors.black)
            else
                for index, computer in ipairs(self.config.computers) do
                    local label = " #" .. tostring(computer.id) .. " " .. computer.label .. " REBOOT "
                    local button = {
                        id = "reboot_computer_" .. tostring(computer.id),
                        x = boxX + 2,
                        y = boxY + 2 + index,
                        width = boxWidth - 4,
                        label = label,
                        fg = colors.white,
                        bg = colors.red,
                    }

                    table.insert(self.modalButtons, button)
                    drawButton(self.monitor, button)
                end
            end
        end
    end

    function self.hitTest(x, y)
        for _, button in ipairs(self.modalButtons) do
            if buttonContains(button, x, y) then
                if button.kind == "meter" then
                    local value = 0
                    if button.width > 1 then
                        value = (x - button.x) / (button.width - 1)
                    end

                    if value < 0 then
                        value = 0
                    elseif value > 1 then
                        value = 1
                    end

                    return "meter", button.id, value
                end

                return "button", button.id
            end
        end

        if self.modal then
            return nil, nil
        end

        for _, button in ipairs(self.cellButtons) do
            if buttonContains(button, x, y) then
                return "button", button.id
            end
        end

        for _, button in ipairs(self.buttons) do
            if buttonContains(button, x, y) then
                return "button", button.id
            end
        end

        if self.deviceRows[y] then
            return "device", self.deviceRows[y]
        end

        if self.sectionHits[y] ~= nil then
            return "section", self.sectionHits[y]
        end

        for _, button in ipairs(self.topButtons) do
            if buttonContains(button, x, y) then
                return "button", button.id
            end
        end

        return nil, nil
    end

    return self
end

Ui.State = dofile(UI_ROOT .. "/state.lua")
Ui.drawEmptyState = drawEmptyState

return Ui
