-- Logs app: показывает /data/logs/system.log с фильтром по уровню,
-- модал-просмотром полной записи и кнопкой Clear.
local Loader    = dofile("/os/lib/loader.lua")
local Log       = Loader.require("/os/lib/log.lua")
local Scrollbar = dofile("/os/lib/scrollbar.lua")

local M = {}
M.id      = "logs"
M.name    = "Logs"
M.icon    = "Lg"
M.iconBg  = colors.yellow
M.iconFg  = colors.black
M.version = 4
M.system  = true
M.category = "system"

local LEVELS = {"all", "info", "warn", "error"}

-- ── helpers ──────────────────────────────────────────────────────────────────

local function padRight(s, n)
    s = tostring(s or "")
    if #s >= n then return string.sub(s, 1, n) end
    return s .. string.rep(" ", n - #s)
end

local function clip(s, n)
    s = tostring(s or "")
    if #s > n then return string.sub(s, 1, n) end
    return s
end

local function levelColor(level)
    if level == "error" then return colors.red end
    if level == "warn"  then return colors.orange end
    if level == "info"  then return colors.lime end
    if level == "debug" then return colors.lightGray end
    return colors.white
end

-- Разбивает текст на строки шириной w, разрывая по пробелам где можно.
local function wrap(text, w)
    local out = {}
    local s = tostring(text or "")
    if w < 1 then return {s} end
    while #s > w do
        -- ищем пробел в первых w символах, чтобы порвать аккуратно
        local cut = w
        for i = w, math.max(1, w - 12), -1 do
            if string.sub(s, i, i) == " " then cut = i; break end
        end
        table.insert(out, string.sub(s, 1, cut))
        s = string.sub(s, cut + 1)
        -- срезаем ведущий пробел после переноса
        while string.sub(s, 1, 1) == " " do s = string.sub(s, 2) end
    end
    if #s > 0 then table.insert(out, s) end
    if #out == 0 then table.insert(out, "") end
    return out
end

local function entryLevel(e)
    if not e then return "info" end
    return e.level or "info"
end

-- Текст для строки списка: предпочитаем структурированные поля,
-- иначе показываем сырую строку.
local function entryShort(e)
    if not e then return "" end
    if e.message and e.message ~= "" then return e.message end
    if e.raw then return e.raw end
    return ""
end

local function filtered(entries, level)
    if level == "all" then return entries end
    local out = {}
    for _, e in ipairs(entries) do
        if entryLevel(e) == level then table.insert(out, e) end
    end
    return out
end

local function nextLevel(current)
    for i, l in ipairs(LEVELS) do
        if l == current then return LEVELS[(i % #LEVELS) + 1] end
    end
    return "all"
end

-- ── lifecycle ────────────────────────────────────────────────────────────────

function M.init(win, ctx)
    Log.loadFromDisk()
    local st = {
        ctx       = ctx,
        win       = win,
        level     = "all",
        scroll    = 0,
        autoscroll = true,
        detail    = nil,         -- nil или таблица записи
        refreshTimer = os.startTimer(2),
        sb        = Scrollbar.create({
            thumbBg = colors.yellow,
            thumbFg = colors.black,
        }),
    }
    Log.subscribe(function() st.autoscroll = true end)
    return st
end

-- ── draw ─────────────────────────────────────────────────────────────────────

local function drawList(st, win, W, H)
    -- Header
    win.setCursorPos(1, 1)
    win.setBackgroundColor(colors.gray)
    win.setTextColor(colors.white)
    win.write(padRight(" LOGS  filter: " .. st.level, W - 8))
    win.setBackgroundColor(colors.red)
    win.setTextColor(colors.white)
    win.write(" CLEAR ")
    win.setBackgroundColor(colors.gray)
    win.write(" ")

    -- Резервируем правую колонку под scrollbar.
    local bodyW = W - 1
    local entries = filtered(Log.tail(Log.MAX_LINES), st.level)
    local visRows = H - 2
    if st.autoscroll then
        st.scroll = math.max(0, #entries - visRows)
        st.autoscroll = false
    end
    local first = math.max(1, st.scroll + 1)
    local last  = math.min(#entries, first + visRows - 1)

    local y = 2
    for i = first, last do
        local e = entries[i]
        win.setCursorPos(1, y)
        win.setBackgroundColor(colors.black)
        win.setTextColor(levelColor(entryLevel(e)))
        local tag = string.upper(string.sub(entryLevel(e), 1, 1))
        local prefix = "[" .. tag .. "] "
        win.write(padRight(prefix .. entryShort(e), bodyW))
        y = y + 1
    end

    if #entries == 0 then
        win.setCursorPos(1, 2)
        win.setBackgroundColor(colors.black)
        win.setTextColor(colors.gray)
        win.write(padRight("(no entries for filter " .. st.level .. ")", bodyW))
    end

    -- Scrollbar справа.
    st.sb:setBounds(W, 2, H - 1)
    st.sb:setContent(visRows, #entries)
    st.sb:setScroll(st.scroll)
    st.sb:draw(win)

    -- Footer
    win.setCursorPos(1, H)
    win.setBackgroundColor(colors.gray)
    win.setTextColor(colors.lightGray)
    local footer = string.format(" %d entries  [Tap row for detail]", #entries)
    win.write(padRight(footer, W))
end

local function drawDetail(st, win, W, H)
    local e = st.detail
    local lvl = entryLevel(e)

    -- Header
    win.setCursorPos(1, 1)
    win.setBackgroundColor(levelColor(lvl))
    win.setTextColor(colors.black)
    win.write(padRight(" " .. string.upper(lvl) .. "  " ..
                       (e.source or "-"), W - 7))
    win.setBackgroundColor(colors.red)
    win.setTextColor(colors.white)
    win.write(" BACK ")
    win.setBackgroundColor(levelColor(lvl))
    win.write(" ")

    -- Тело: полный текст сообщения, перенесённый по ширине.
    win.setBackgroundColor(colors.black)
    local text = (e.message and e.message ~= "" and e.message) or e.raw or ""
    local lines = wrap(text, W - 1)
    local y = 3
    win.setCursorPos(1, y)
    win.setTextColor(colors.white)
    for _, line in ipairs(lines) do
        if y > H - 1 then break end
        win.setCursorPos(1, y)
        win.setBackgroundColor(colors.black)
        win.setTextColor(levelColor(lvl))
        win.write(padRight(" " .. line, W))
        y = y + 1
    end

    -- Если есть сырая запись и она отличается, показываем её снизу справочно.
    if e.raw and e.raw ~= text and y < H - 1 then
        y = y + 1
        win.setCursorPos(1, y)
        win.setBackgroundColor(colors.black)
        win.setTextColor(colors.gray)
        win.write(padRight(" raw:", W))
        y = y + 1
        local rawLines = wrap(e.raw, W - 1)
        for _, line in ipairs(rawLines) do
            if y > H - 1 then break end
            win.setCursorPos(1, y)
            win.setBackgroundColor(colors.black)
            win.setTextColor(colors.lightGray)
            win.write(padRight(" " .. line, W))
            y = y + 1
        end
    end

    -- Footer
    win.setCursorPos(1, H)
    win.setBackgroundColor(colors.gray)
    win.setTextColor(colors.lightGray)
    win.write(padRight(" Tap BACK or anywhere to return", W))
end

function M.draw(st, win)
    local W, H = win.getSize()
    win.setBackgroundColor(colors.black)
    win.clear()

    if st.detail then
        drawDetail(st, win, W, H)
    else
        drawList(st, win, W, H)
    end
end

-- ── events ───────────────────────────────────────────────────────────────────

local function visibleAt(st, W, H, y)
    local entries = filtered(Log.tail(Log.MAX_LINES), st.level)
    local visRows = H - 2
    local first = math.max(1, st.scroll + 1)
    local idx = first + (y - 2)
    return entries[idx]
end

-- Синхронизация scrollbar bounds/content под текущий список.
local function syncSb(st)
    local W, H = st.win.getSize()
    local visRows = H - 2
    local entries = filtered(Log.tail(Log.MAX_LINES), st.level)
    st.sb:setBounds(W, 2, H - 1)
    st.sb:setContent(visRows, #entries)
    st.sb:setScroll(st.scroll)
end

function M.onEvent(st, event, p1, p2, p3, p4)
    if event == "mouse_click" or event == "monitor_touch" then
        local W, H = st.win.getSize()
        local x, y = p2, p3

        -- В режиме detail любой клик возвращает в список.
        if st.detail then
            st.detail = nil
            return st, true
        end

        if y == 1 then
            if x >= W - 7 and x <= W - 1 then
                Log.clear()
                st.scroll = 0
                st.ctx.notify("Logs cleared", nil, {level = "success", source = "logs"})
                return st, true
            end
            -- Клик по левой части header — циклически меняем фильтр.
            st.level = nextLevel(st.level)
            st.scroll = 0
            st.autoscroll = true
            return st, true
        end

        -- Scrollbar
        syncSb(st)
        if st.sb:onClick(x, y) then
            st.scroll = st.sb.scroll
            st.autoscroll = false
            return st, true
        end

        -- Тап по строке списка — открываем детальный просмотр.
        if y >= 2 and y <= H - 1 then
            local entry = visibleAt(st, W, H, y)
            if entry then
                st.detail = entry
                return st, true
            end
        end

        return st, false
    end

    if event == "mouse_drag" then
        if st.detail then return st, false end
        syncSb(st)
        if st.sb:onDrag(p2, p3) then
            st.scroll = st.sb.scroll
            st.autoscroll = false
            return st, true
        end
        return st, false
    end

    if event == "mouse_scroll" then
        if st.detail then return st, false end
        syncSb(st)
        st.sb:scrollBy(p1)
        st.scroll = st.sb.scroll
        st.autoscroll = false
        return st, true
    end

    if event == "key" then
        if p1 == keys.escape and st.detail then
            st.detail = nil
            return st, true
        end
    end

    if event == "timer" and p1 == st.refreshTimer then
        st.refreshTimer = os.startTimer(2)
        return st, true
    end

    return st, false
end

return M
