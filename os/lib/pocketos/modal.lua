-- Модальные окна PocketOS в стиле factory control:
-- header bar + body + footer с кнопкой Close.
-- Поддерживаемые типы: "volume", "scale", "theme", "wallpaper", "modem", "tray".
local Modal = {}

-- ── Геометрия ─────────────────────────────────────────────────────────────────

-- Возвращает позицию и размер модального окна.
-- Размеры зависят от типа: списки выше, регуляторы — ниже.
function Modal.layout(modal, W, AH)
    local mw, mh
    if modal.kind == "volume" or modal.kind == "scale" then
        mw = math.min(W - 4, 22); mh = 7
    elseif modal.kind == "tray" then
        mw = math.min(W - 2, 22); mh = 11
    elseif modal.kind == "notifications" then
        mw = math.min(W - 2, 24); mh = math.min(AH - 2, 15)
    else  -- theme / wallpaper / modem
        mw = math.min(W - 4, 22); mh = math.min(AH - 2, 13)
    end
    local mx = math.floor((W  - mw) / 2) + 1
    local my = math.floor((AH - mh) / 2) + 1
    return mx, my, mw, mh
end

-- ── Хелперы отрисовки ─────────────────────────────────────────────────────────

local function fillRow(win, x, y, w, bg, fg, text)
    win.setBackgroundColor(bg)
    win.setTextColor(fg)
    win.setCursorPos(x, y)
    win.write(string.rep(" ", w))
    if text then
        win.setCursorPos(x + math.floor((w - #text) / 2), y)
        win.write(text)
    end
end

-- Рамка-шапка модала: заголовок сверху, поле тела, footer с Close.
local function drawFrame(win, mx, my, mw, mh, title, theme, withClose)
    local hb = theme.headerBg or colors.blue
    local hf = theme.headerFg or colors.white
    local mb = theme.sectionBg or colors.gray
    local mf = theme.sectionFg or colors.white
    local fb = theme.columnBg or colors.lightGray
    local ff = theme.columnFg or colors.black

    -- Заголовок
    fillRow(win, mx, my, mw, hb, hf, " " .. title .. " ")

    -- Тело
    win.setBackgroundColor(mb)
    win.setTextColor(mf)
    local bodyBot = withClose and (my + mh - 2) or (my + mh - 1)
    for y = my + 1, bodyBot do
        win.setCursorPos(mx, y)
        win.write(string.rep(" ", mw))
    end

    -- Footer с кнопкой Close
    if withClose then
        fillRow(win, mx, my + mh - 1, mw, fb, ff, " Close ")
    end
    return mb, mf
end

-- ── volume / scale (общий слайдер) ────────────────────────────────────────────

local SLIDER_INSET = 2

local function sliderConfig(modal)
    if modal.kind == "volume" then
        return {title = "VOLUME", min = 0, max = 1, step = 0.1, fmt = function(v) return string.format("%d%%", math.floor(v * 100 + 0.5)) end}
    else  -- scale
        return {title = "SCALE",  min = 0.5, max = 5, step = 0.5, fmt = function(v) return string.format("%.1f", v) end}
    end
end

local function drawSlider(win, modal, mx, my, mw, mh, theme)
    local cfg = sliderConfig(modal)
    drawFrame(win, mx, my, mw, mh, cfg.title, theme, true)

    local mb = theme.sectionBg or colors.gray
    local cb = theme.columnBg  or colors.lightGray
    local cf = theme.columnFg  or colors.black
    local ac = theme.accentBg  or colors.cyan

    local barRow = my + 2
    local btnRow = my + 4
    local barW   = mw - 4
    local v      = modal.value or cfg.min
    local frac   = (v - cfg.min) / (cfg.max - cfg.min)
    if frac < 0 then frac = 0 elseif frac > 1 then frac = 1 end
    local filled = math.floor(barW * frac + 0.5)

    -- Полоса
    win.setCursorPos(mx + SLIDER_INSET, barRow)
    for i = 1, barW do
        win.setBackgroundColor(i <= filled and ac or cb)
        win.write(" ")
    end

    -- Минус слева, плюс справа, значение по центру
    win.setBackgroundColor(cb); win.setTextColor(cf)
    win.setCursorPos(mx + SLIDER_INSET, btnRow);          win.write(" - ")
    win.setCursorPos(mx + mw - SLIDER_INSET - 3, btnRow); win.write(" + ")

    win.setBackgroundColor(mb)
    win.setTextColor(theme.sectionFg or colors.white)
    local lbl = cfg.fmt(v)
    win.setCursorPos(mx + math.floor((mw - #lbl) / 2), btnRow)
    win.write(lbl)
end

-- Hit-test для slider-модала. Возвращает "minus" | "plus" | "close" | nil.
local function hitSlider(modal, x, y, mx, my, mw, mh)
    local btnRow = my + 4
    if y == btnRow then
        if x >= mx + SLIDER_INSET and x <= mx + SLIDER_INSET + 2 then return "minus" end
        if x >= mx + mw - SLIDER_INSET - 3 and x <= mx + mw - SLIDER_INSET - 1 then return "plus" end
    end
    if y == my + mh - 1 then return "close" end
    return nil
end

-- ── list (theme / wallpaper) ──────────────────────────────────────────────────

local function listItems(modal, shellThemes, wallpapers)
    if modal.kind == "theme" then
        local items = {}
        for i, t in ipairs(shellThemes or {}) do
            items[i] = (t and t.name) or ("Theme " .. i)
        end
        return items
    elseif modal.kind == "wallpaper" then
        return wallpapers or {}
    elseif modal.kind == "modem" then
        return modal.items or {"back", "front", "left", "right", "top", "bottom"}
    end
    return {}
end

local function drawList(win, modal, mx, my, mw, mh, theme, items)
    local title
    if modal.kind == "theme" then title = "THEME"
    elseif modal.kind == "wallpaper" then title = "WALLPAPER"
    else title = "MODEM SIDE" end
    drawFrame(win, mx, my, mw, mh, title, theme, true)

    local mb = theme.sectionBg or colors.gray
    local mf = theme.sectionFg or colors.white
    local ac = theme.accentBg  or colors.cyan
    local af = colors.black

    local rows   = mh - 3   -- строки тела минус Close
    local scroll = modal.scroll or 0
    local sel    = modal.selected or 1

    for i = 1, rows do
        local idx = scroll + i
        local item = items[idx]
        local y = my + i
        win.setCursorPos(mx + 1, y)
        if item then
            local isSel = (idx == sel)
            win.setBackgroundColor(isSel and ac or mb)
            win.setTextColor(isSel and af or mf)
            local label = "  " .. item
            local pad   = string.sub(label .. string.rep(" ", mw - 2), 1, mw - 2)
            win.write(pad)
        else
            win.setBackgroundColor(mb)
            win.write(string.rep(" ", mw - 2))
        end
    end

    -- Индикатор прокрутки
    if #items > rows then
        win.setTextColor(theme.mutedFg or colors.lightGray)
        win.setBackgroundColor(mb)
        if scroll > 0 then
            win.setCursorPos(mx + mw - 2, my + 1); win.write("^")
        end
        if scroll + rows < #items then
            win.setCursorPos(mx + mw - 2, my + rows); win.write("v")
        end
    end
end

local function hitList(modal, x, y, mx, my, mw, mh, items)
    if y == my + mh - 1 then return "close", nil end
    local row    = y - my
    local rows   = mh - 3
    if row < 1 or row > rows then return nil, nil end
    local scroll = modal.scroll or 0
    local idx    = scroll + row
    if items[idx] then return "select", idx end
    return nil, nil
end

-- ── tray (быстрая панель: громкость + scale) ──────────────────────────────────

local function drawTray(win, modal, mx, my, mw, mh, theme, hasScale)
    drawFrame(win, mx, my, mw, mh, "QUICK", theme, true)

    local mb = theme.sectionBg or colors.gray
    local mf = theme.sectionFg or colors.white
    local cb = theme.columnBg  or colors.lightGray
    local cf = theme.columnFg  or colors.black
    local ac = theme.accentBg  or colors.cyan

    local barW = mw - 4

    -- Громкость
    win.setBackgroundColor(mb); win.setTextColor(mf)
    win.setCursorPos(mx + 2, my + 1); win.write("Volume")
    local v = modal.volume or 1
    local f = math.floor(barW * v + 0.5)
    win.setCursorPos(mx + 2, my + 2)
    for i = 1, barW do
        win.setBackgroundColor(i <= f and ac or cb); win.write(" ")
    end
    win.setBackgroundColor(cb); win.setTextColor(cf)
    win.setCursorPos(mx + 2,           my + 3); win.write(" - ")
    win.setCursorPos(mx + mw - 5,      my + 3); win.write(" + ")
    win.setBackgroundColor(mb); win.setTextColor(mf)
    local vlbl = string.format("%d%%", math.floor(v * 100 + 0.5))
    win.setCursorPos(mx + math.floor((mw - #vlbl) / 2), my + 3); win.write(vlbl)

    -- Scale
    if hasScale then
        win.setBackgroundColor(mb); win.setTextColor(mf)
        win.setCursorPos(mx + 2, my + 5); win.write("Scale")
        local s = modal.scale or 1
        local sf = (s - 0.5) / (5 - 0.5)
        if sf < 0 then sf = 0 elseif sf > 1 then sf = 1 end
        local ff = math.floor(barW * sf + 0.5)
        win.setCursorPos(mx + 2, my + 6)
        for i = 1, barW do
            win.setBackgroundColor(i <= ff and ac or cb); win.write(" ")
        end
        win.setBackgroundColor(cb); win.setTextColor(cf)
        win.setCursorPos(mx + 2,      my + 7); win.write(" - ")
        win.setCursorPos(mx + mw - 5, my + 7); win.write(" + ")
        win.setBackgroundColor(mb); win.setTextColor(mf)
        local slbl = string.format("%.1f", s)
        win.setCursorPos(mx + math.floor((mw - #slbl) / 2), my + 7); win.write(slbl)
    else
        win.setBackgroundColor(mb); win.setTextColor(theme.mutedFg or colors.lightGray)
        win.setCursorPos(mx + 2, my + 5); win.write("Scale: no monitor")
    end

    -- Кнопка Reboot
    win.setBackgroundColor(colors.red); win.setTextColor(colors.white)
    win.setCursorPos(mx + 2, my + mh - 3)
    win.write(string.rep(" ", mw - 4))
    local rlbl = "Reboot"
    win.setCursorPos(mx + math.floor((mw - #rlbl) / 2), my + mh - 3)
    win.write(rlbl)
end

local function hitTray(modal, x, y, mx, my, mw, mh, hasScale)
    if y == my + 3 then  -- громкость
        if x >= mx + 2 and x <= mx + 4              then return "vol_minus" end
        if x >= mx + mw - 5 and x <= mx + mw - 3    then return "vol_plus"  end
    end
    if hasScale and y == my + 7 then  -- scale
        if x >= mx + 2 and x <= mx + 4              then return "scale_minus" end
        if x >= mx + mw - 5 and x <= mx + mw - 3    then return "scale_plus"  end
    end
    if y == my + mh - 3 and x >= mx + 2 and x <= mx + mw - 3 then
        return "reboot"
    end
    if y == my + mh - 1 then return "close" end
    return nil
end

-- ── notifications ─────────────────────────────────────────────────────────────

local function drawNotifications(win, modal, mx, my, mw, mh, theme)
    -- Рисуем рамку без встроенного Close — footer рисуем вручную.
    drawFrame(win, mx, my, mw, mh, "NOTIFICATIONS", theme, false)

    local mb    = theme.sectionBg or colors.gray
    local rf    = theme.rowFg     or colors.white
    local muted = theme.mutedFg   or colors.lightGray
    local fb    = theme.columnBg  or colors.lightGray
    local ff    = theme.columnFg  or colors.black

    local items  = modal.items or {}
    local rows   = mh - 3
    local scroll = modal.scroll or 0

    if #items == 0 then
        win.setCursorPos(mx + 1, my + 2)
        win.setBackgroundColor(mb)
        win.setTextColor(muted)
        win.write("No notifications yet.")
    else
        for i = 1, rows do
            local idx = #items - scroll - (i - 1)
            if idx >= 1 then
                local entry = items[idx]
                local ey = my + i
                local fg = rf
                if     entry.level == "error"   then fg = colors.red
                elseif entry.level == "warn"    then fg = colors.orange
                elseif entry.level == "success" then fg = colors.lime
                end
                win.setCursorPos(mx + 1, ey)
                win.setBackgroundColor(mb)
                win.setTextColor(fg)
                local label = (entry.read and "  " or "* ") .. (entry.title or "")
                if #label > mw - 2 then label = string.sub(label, 1, mw - 2) end
                local pad = mw - 2 - #label
                if pad < 0 then pad = 0 end
                win.write(label .. string.rep(" ", pad))
            end
        end

        if #items > rows then
            win.setBackgroundColor(mb)
            win.setTextColor(muted)
            if scroll > 0 then
                win.setCursorPos(mx + mw - 2, my + rows); win.write("v")
            end
            if scroll + rows < #items then
                win.setCursorPos(mx + mw - 2, my + 1); win.write("^")
            end
        end
    end

    -- Footer: [Clear] слева, [Close] справа.
    local clearW = 7  -- "[Clear]"
    local closeW = 7  -- "[Close]"
    local fy = my + mh - 1
    win.setCursorPos(mx, fy)
    win.setBackgroundColor(colors.orange)
    win.setTextColor(colors.black)
    win.write("[Clear]")
    win.setBackgroundColor(fb)
    win.setTextColor(ff)
    local midW = mw - clearW - closeW
    if midW > 0 then win.write(string.rep(" ", midW)) end
    win.write("[Close]")
end

local function hitNotifications(modal, x, y, mx, my, mw, mh)
    if y == my + mh - 1 then
        -- Footer: [Clear] = mx..mx+6, [Close] = mx+mw-7..mx+mw-1
        if x >= mx and x <= mx + 6 then return "clear_all", nil end
        return "close", nil
    end
    local row = y - my
    local rows = mh - 3
    if row < 1 or row > rows then return nil end
    local items = modal.items or {}
    local idx = #items - (modal.scroll or 0) - (row - 1)
    if items[idx] then return "select", idx end
    return nil
end

-- ── Публичное API ─────────────────────────────────────────────────────────────

function Modal.draw(modal, win, W, AH, theme, opts)
    opts = opts or {}
    local mx, my, mw, mh = Modal.layout(modal, W, AH)
    if modal.kind == "volume" or modal.kind == "scale" then
        drawSlider(win, modal, mx, my, mw, mh, theme)
    elseif modal.kind == "theme" or modal.kind == "wallpaper" or modal.kind == "modem" then
        local items = listItems(modal, opts.themes, opts.wallpapers)
        drawList(win, modal, mx, my, mw, mh, theme, items)
    elseif modal.kind == "tray" then
        drawTray(win, modal, mx, my, mw, mh, theme, opts.hasScale)
    elseif modal.kind == "notifications" then
        drawNotifications(win, modal, mx, my, mw, mh, theme)
    end
end

function Modal.hit(modal, x, y, W, AH, opts)
    opts = opts or {}
    local mx, my, mw, mh = Modal.layout(modal, W, AH)
    -- Клик мимо модала — закрыть
    if x < mx or x > mx + mw - 1 or y < my or y > my + mh - 1 then
        return "outside"
    end
    if modal.kind == "volume" or modal.kind == "scale" then
        return hitSlider(modal, x, y, mx, my, mw, mh)
    elseif modal.kind == "theme" or modal.kind == "wallpaper" or modal.kind == "modem" then
        local items = listItems(modal, opts.themes, opts.wallpapers)
        local k, d  = hitList(modal, x, y, mx, my, mw, mh, items)
        return k, d
    elseif modal.kind == "tray" then
        return hitTray(modal, x, y, mx, my, mw, mh, opts.hasScale)
    elseif modal.kind == "notifications" then
        return hitNotifications(modal, x, y, mx, my, mw, mh)
    end
    return nil
end

function Modal.scroll(modal, dir, opts)
    opts = opts or {}
    if modal.kind == "theme" or modal.kind == "wallpaper" or modal.kind == "modem" then
        local items = listItems(modal, opts.themes, opts.wallpapers)
        local mw, mh = select(3, Modal.layout(modal, opts.W or 26, opts.AH or 19))
        local rows = mh - 3
        local maxScroll = math.max(0, #items - rows)
        modal.scroll = math.max(0, math.min(maxScroll, (modal.scroll or 0) + dir))
        return true
    elseif modal.kind == "notifications" then
        local items = modal.items or {}
        local _, _, mw, mh = Modal.layout(modal, opts.W or 26, opts.AH or 19)
        local rows = mh - 3
        local maxScroll = math.max(0, #items - rows)
        modal.scroll = math.max(0, math.min(maxScroll, (modal.scroll or 0) + dir))
        return true
    end
    return false
end

return Modal
