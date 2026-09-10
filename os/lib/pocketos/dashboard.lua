-- Dashboard PocketOS: рабочий стол с большими часами и плитками
-- последних использованных приложений. Wallpaper рисуется фоном.
-- Init.lua пушит запущенные приложения в desktop.recentApps, а dashboard
-- получает их в dctx и рисует как цветные кафельные плитки.
local Clock = dofile("/os/lib/clock.lua")

local Dashboard = {}

local DAYS   = Clock.DAYS
local MONTHS = Clock.MONTHS

local function dateString(c)
    -- В режиме Minecraft даты нет — показываем номер игрового дня.
    if not c.hasDate then
        if c.mode == "mc" and c.mcDay then return "MC Day " .. tostring(c.mcDay) end
        return ""
    end
    return string.format("%s %s %02d",
        DAYS[c.wday] or "?", MONTHS[c.mon] or "?", c.day or 1)
end

-- Большие цифры 5x3 для часов.
local BIG = {
    ["0"] = {"###","# #","# #","# #","###"},
    ["1"] = {"  #","  #","  #","  #","  #"},
    ["2"] = {"###","  #","###","#  ","###"},
    ["3"] = {"###","  #","###","  #","###"},
    ["4"] = {"# #","# #","###","  #","  #"},
    ["5"] = {"###","#  ","###","  #","###"},
    ["6"] = {"###","#  ","###","# #","###"},
    ["7"] = {"###","  #","  #","  #","  #"},
    ["8"] = {"###","# #","###","# #","###"},
    ["9"] = {"###","# #","###","  #","###"},
    [":"] = {"   "," # ","   "," # ","   "},
    [" "] = {"   ","   ","   ","   ","   "},
}

local function bigClockWidth(text)
    local w = 0
    for i = 1, #text do
        local ch = string.sub(text, i, i)
        local g  = BIG[ch] or BIG[" "]
        w = w + #g[1]
        if i < #text then w = w + 1 end
    end
    return w
end

local function drawBigClock(workArea, x, y, text, fg, bg)
    local cx = x
    for i = 1, #text do
        local ch = string.sub(text, i, i)
        local g  = BIG[ch] or BIG[" "]
        for row = 1, 5 do
            workArea.setCursorPos(cx, y + row - 1)
            workArea.setBackgroundColor(bg)
            workArea.setTextColor(fg)
            workArea.write(g[row])
        end
        cx = cx + #g[1] + 1
    end
end

-- ── Wallpaper ────────────────────────────────────────────────────────────────

local function fillBg(workArea, W, AH, bg)
    workArea.setBackgroundColor(bg)
    for y = 1, AH do
        workArea.setCursorPos(1, y)
        workArea.write(string.rep(" ", W))
    end
end

local function drawDots(workArea, W, AH, bg, fg)
    workArea.setBackgroundColor(bg)
    workArea.setTextColor(fg)
    for y = 2, AH - 1, 3 do
        for x = 3, W - 1, 5 do
            workArea.setCursorPos(x, y)
            workArea.write(".")
        end
    end
end

local function drawStars(workArea, W, AH, bg, fg)
    workArea.setBackgroundColor(bg)
    workArea.setTextColor(fg)
    -- Детерминированная "случайность" по хэшу: одинаковый узор каждый кадр.
    local function h(x, y) return ((x * 73 + y * 113) % 37) end
    for y = 1, AH do
        for x = 1, W do
            if h(x, y) == 0 then
                workArea.setCursorPos(x, y)
                workArea.write("*")
            end
        end
    end
end

local function drawGrid(workArea, W, AH, bg, fg)
    workArea.setBackgroundColor(bg)
    workArea.setTextColor(fg)
    for y = 2, AH, 2 do
        for x = 3, W, 4 do
            workArea.setCursorPos(x, y)
            workArea.write(".")
        end
    end
end

local function drawTilesPattern(workArea, W, AH, bg, fg)
    workArea.setBackgroundColor(bg)
    workArea.setTextColor(fg)
    for y = 1, AH, 3 do
        for x = 1, W, 6 do
            workArea.setCursorPos(x, y)
            workArea.write("+")
        end
    end
end

function Dashboard.drawWallpaper(workArea, W, AH, pattern, theme)
    local bg = theme.pageBg or colors.black
    local fg = colors.gray
    fillBg(workArea, W, AH, bg)
    if pattern == "dots"  then drawDots(workArea, W, AH, bg, fg)
    elseif pattern == "stars" then drawStars(workArea, W, AH, bg, fg)
    elseif pattern == "grid"  then drawGrid(workArea, W, AH, bg, fg)
    elseif pattern == "tiles" then drawTilesPattern(workArea, W, AH, bg, fg)
    end
end

-- ── Плитки ────────────────────────────────────────────────────────────────────

local function clip(s, n)
    s = tostring(s or "")
    if #s > n then return string.sub(s, 1, n) end
    return s
end

local function drawTile(workArea, x, y, w, h, def)
    local bg = def.iconBg or colors.lightGray
    local fg = def.iconFg or colors.black

    -- Заливка цветом приложения.
    workArea.setBackgroundColor(bg)
    for row = 0, h - 1 do
        workArea.setCursorPos(x, y + row)
        workArea.write(string.rep(" ", w))
    end

    -- Иконка 2 символа сверху по центру (если высота >= 2).
    local icon = def.icon or string.sub(def.name or def.id or "?", 1, 2)
    icon = tostring(icon)
    if #icon < 2 then icon = icon .. " " end
    icon = string.sub(icon, 1, 2)

    local iconRow = y + (h >= 3 and 0 or 0)
    local iconX   = x + math.max(0, math.floor((w - #icon) / 2))
    workArea.setBackgroundColor(bg)
    workArea.setTextColor(fg)
    workArea.setCursorPos(iconX, iconRow)
    workArea.write(icon)

    -- Имя по центру в нижней половине.
    if h >= 2 then
        local name = clip(def.name or def.id or "?", w - 1)
        local nameRow = y + h - 1
        local nameX   = x + math.max(0, math.floor((w - #name) / 2))
        workArea.setCursorPos(nameX, nameRow)
        workArea.write(name)
    end
end

-- ── Layout / hit storage ──────────────────────────────────────────────────────

-- Сохраняем последнюю раскладку плиток для hit-теста.
local _last = nil

local function planLayout(W, AH, recentCount)
    -- Берём адаптивно колонки и размер часов.
    local cols
    if W >= 60 then cols = 4
    elseif W >= 40 then cols = 3
    else cols = 2
    end

    -- Часы: занимают примерно 7 строк (большие 5 + дата + отступ).
    local big = (AH >= 12)
    local clockH = big and 7 or 3

    local tileStart = clockH + 2          -- 1 строка зазора после часов
    local statusH   = 1                    -- нижняя строка
    local tileArea  = AH - tileStart - statusH + 1
    if tileArea < 2 then tileArea = AH - tileStart + 1 end

    -- Плитки: 3 строки + 1 зазор, или 2 строки + 1 зазор.
    local tileH, gapY = 3, 1
    if tileArea < 4 then tileH, gapY = 2, 0 end
    local rows = math.max(1, math.floor((tileArea + gapY) / (tileH + gapY)))
    local maxTiles = cols * rows
    if recentCount > 0 then
        rows = math.min(rows, math.ceil(recentCount / cols))
    end

    local gapX = 1
    local tileW = math.floor((W - (cols - 1) * gapX) / cols)
    if tileW < 4 then tileW = 4 end

    return {
        cols = cols, rows = rows,
        tileW = tileW, tileH = tileH,
        gapX = gapX, gapY = gapY,
        tileStart = tileStart, clockH = clockH, big = big,
        maxTiles = maxTiles, statusH = statusH,
    }
end

-- ── Главный рендер ────────────────────────────────────────────────────────────

function Dashboard.draw(workArea, W, AH, theme, dctx)
    local bg = theme.pageBg or colors.black
    local mu = theme.mutedFg or colors.lightGray
    local accent = theme.accentBg or colors.cyan

    -- 1. Wallpaper.
    Dashboard.drawWallpaper(workArea, W, AH, dctx.wallpaper, theme)

    -- 2. Часы (режим/смещение из dctx.clockOpts).
    local cal = Clock.calendar(dctx.clockOpts)
    local timeStr = Clock.clockStr(dctx.clockOpts)
    local dateStr = dateString(cal)
    if cal.hasDate and cal.year then dateStr = dateStr .. " " .. cal.year end

    local recents = dctx.recentApps or {}
    local plan = planLayout(W, AH, #recents)

    if plan.big and bigClockWidth(timeStr) + 2 <= W then
        local tw  = bigClockWidth(timeStr)
        local cx  = math.max(1, math.floor((W - tw) / 2) + 1)
        drawBigClock(workArea, cx, 2, timeStr, accent, bg)
        local dx = math.max(1, math.floor((W - #dateStr) / 2) + 1)
        workArea.setBackgroundColor(bg)
        workArea.setTextColor(mu)
        workArea.setCursorPos(dx, 7)
        workArea.write(dateStr)
    else
        -- Компактные часы: только текст.
        local cx = math.max(1, math.floor((W - #timeStr) / 2) + 1)
        workArea.setBackgroundColor(bg)
        workArea.setTextColor(theme.headerFg or colors.white)
        workArea.setCursorPos(cx, 1)
        workArea.write(timeStr)
        local dx = math.max(1, math.floor((W - #dateStr) / 2) + 1)
        workArea.setCursorPos(dx, 2)
        workArea.setTextColor(mu)
        workArea.write(dateStr)
    end

    -- 3. Плитки последних приложений.
    local placed = {}
    local count = math.min(#recents, plan.maxTiles)
    for idx = 1, count do
        local row = math.floor((idx - 1) / plan.cols)
        local col = (idx - 1) % plan.cols
        local tx = 1 + col * (plan.tileW + plan.gapX)
        local ty = plan.tileStart + row * (plan.tileH + plan.gapY)
        drawTile(workArea, tx, ty, plan.tileW, plan.tileH, recents[idx])
        placed[idx] = {x = tx, y = ty, w = plan.tileW, h = plan.tileH, def = recents[idx]}
    end

    if count == 0 then
        local msg = "Tap [#] to open the launcher"
        local mx  = math.max(1, math.floor((W - #msg) / 2) + 1)
        local my  = plan.tileStart + 1
        workArea.setBackgroundColor(bg)
        workArea.setTextColor(mu)
        workArea.setCursorPos(mx, my)
        workArea.write(msg)
    end

    -- 4. Нижняя status-строка: уведомления + версия ОС.
    -- Сторону модема на рабочем столе не показываем (только в Settings).
    local parts = {}
    if dctx.unread and dctx.unread > 0 then
        table.insert(parts, dctx.unread .. " unread")
    end
    if dctx.networkStatus and dctx.networkStatus.remote and not dctx.networkStatus.online then
        table.insert(parts, "offline")
    end
    if dctx.osVersion then
        table.insert(parts, "v" .. tostring(dctx.osVersion))
    end
    local status = table.concat(parts, "  ")
    local sx = math.max(1, math.floor((W - #status) / 2) + 1)
    workArea.setBackgroundColor(bg)
    workArea.setTextColor(mu)
    workArea.setCursorPos(sx, AH)
    workArea.write(clip(status, W))

    -- Сохраняем для hit-теста.
    _last = {plan = plan, placed = placed, statusY = AH, clockH = plan.clockH}
end

-- Возвращает (kind, data) — совместимо с тем, как init.lua обрабатывает клик.
-- kind: "app" (data = app def), "status", "clock", или nil.
function Dashboard.hit(x, y, W, AH)
    if not _last then return nil end

    -- Клик по нижней статус-строке.
    if y == _last.statusY then return "status" end

    -- Плитка приложения.
    for _, box in ipairs(_last.placed) do
        if x >= box.x and x < box.x + box.w
           and y >= box.y and y < box.y + box.h then
            return "app", box.def
        end
    end

    -- Клик по часам (верхняя зона) — открыть tray.
    if y <= _last.clockH then return "clock" end

    return nil
end

return Dashboard
