-- Settings: список с категориями, прокрутка, live-значения.
local M = {}
M.id       = "settings"
M.name     = "Settings"
M.icon     = "Se"
M.iconBg   = colors.lightGray
M.iconFg   = colors.black
M.version  = 7
M.system   = true
M.category = "system"

local Scrollbar = dofile("/os/lib/scrollbar.lua")

local function loadShell() return dofile("/os/lib/pocketos/shell.lua") end

-- ── Константы ────────────────────────────────────────────────────────────────

local MODEM_SIDES = {"back","front","left","right","top","bottom"}

local LOCK_OPTS = {
    {label="Never",  value=0},
    {label="1 min",  value=60},
    {label="5 min",  value=300},
    {label="10 min", value=600},
    {label="30 min", value=1800},
}

local function lockLabel(v)
    for _, o in ipairs(LOCK_OPTS) do if o.value == v then return o.label end end
    return tostring(v) .. "s"
end

local function lockCycle(v, dir)
    for i, o in ipairs(LOCK_OPTS) do
        if o.value == v then
            return LOCK_OPTS[((i - 1 + dir) % #LOCK_OPTS) + 1].value
        end
    end
    return 600
end

-- ── Числовая клавиатура (смена пароля) ──────────────────────────────────────

local KEYPAD = {{7,8,9},{4,5,6},{1,2,3},{"X",0,"OK"}}
local BTN_W  = 3

local function padBtn(k)
    local s = tostring(k)
    local p = BTN_W - #s
    return string.rep(" ", math.floor(p/2)) .. s .. string.rep(" ", p - math.floor(p/2))
end

local function drawKeypad(win, x0, y0, theme)
    local ac = theme.accentBg or colors.cyan
    for row, keys in ipairs(KEYPAD) do
        local y = y0 + (row - 1) * 2
        for col, k in ipairs(keys) do
            local x  = x0 + (col - 1) * (BTN_W + 1)
            local bg = (k == "OK") and colors.green or (k == "X") and colors.red or ac
            local fg = (bg == colors.red or bg == colors.green) and colors.white or colors.black
            win.setCursorPos(x, y)
            win.setBackgroundColor(bg); win.setTextColor(fg)
            win.write(padBtn(k))
        end
    end
end

local function kpadHit(x, y, x0, y0)
    for row, keys in ipairs(KEYPAD) do
        if y == y0 + (row - 1) * 2 then
            for col, k in ipairs(keys) do
                local kx = x0 + (col - 1) * (BTN_W + 1)
                if x >= kx and x < kx + BTN_W then
                    if k == "X"  then return "backspace" end
                    if k == "OK" then return "ok" end
                    return "digit", k
                end
            end
        end
    end
end

local function isDigitChar(ch)
    return type(ch) == "string" and string.match(ch, "^%d$") ~= nil
end

local function isEnterKey(k)
    return k == keys.enter or k == keys.space or (keys.numPadEnter and k == keys.numPadEnter)
end

local function changePassAction(st, action, data)
    if action == "digit" then
        if st.passStep == 1 then st.passNew = st.passNew .. tostring(data)
        else st.passConfirm = st.passConfirm .. tostring(data) end
        st.passError = ""
    elseif action == "backspace" then
        if st.passStep == 1 and #st.passNew > 0 then
            st.passNew = string.sub(st.passNew, 1, -2)
        elseif st.passStep == 2 and #st.passConfirm > 0 then
            st.passConfirm = string.sub(st.passConfirm, 1, -2)
        end
    elseif action == "ok" then
        if st.passStep == 1 then
            if #st.passNew == 0 then st.passError = "Enter new password"
            else st.passStep = 2 end
        else
            if st.passNew ~= st.passConfirm then
                st.passError   = "Passwords differ"
                st.passConfirm = ""
            else
                local Users = st.ctx.users or dofile("/os/lib/users.lua")
                local u = st.ctx.currentUser
                if u then
                    local db = Users.load()
                    Users.updatePassword(db, u.id, st.passNew)
                    Users.save(db)
                    u.passHash = Users.hashPassword(st.passNew)
                end
                st.subMode = nil
                st.ctx.toast("Password updated", {level = "success"})
            end
        end
    end
end

-- ── Построение списка строк ──────────────────────────────────────────────────
-- Каждая строка: {type, id, icon, name, getValue, action, color}

local function buildRows(st)
    local ctx = st.ctx
    local d   = ctx.desktop
    local u   = ctx.currentUser
    local rows = {}

    local function cat(text)
        table.insert(rows, {type="cat", text=text})
    end
    local function item(id, icon, name, fn, action)
        table.insert(rows, {type="item", id=id, icon=icon, name=name, getValue=fn, action=action})
    end
    local function tog(id, icon, name, fn, action)
        table.insert(rows, {type="toggle", id=id, icon=icon, name=name, getValue=fn, action=action})
    end
    local function act(id, icon, name, action, color)
        table.insert(rows, {type="action", id=id, icon=icon, name=name, action=action, color=color})
    end

    -- Внешний вид
    cat("Appearance")
    item("theme",    "Th", "Theme",
         function() local t = st.Shell.getThemes()[d.themeIndex or 1]; return (t and t.name) or "Theme 1" end,
         "modal_theme")
    item("wallpaper","Wp", "Wallpaper",
         function() return d.pattern or "solid" end,
         "modal_wallpaper")
    if ctx.hasScale then
        item("scale", "Sc", "Text Scale",
             function() return string.format("%.1f", d.textScale or 1) end,
             "modal_scale")
    end
    tog("clock_fmt", "Cl", "Clock",
        function() return (d.clockFormat == "12h") and "12h" or "24h" end,
        "toggle_clock")
    tog("time_mode", "Tm", "Time",
        function() return (d.timeMode == "mc") and "Minecraft" or "Real" end,
        "toggle_time_mode")
    -- Смещение пояса показываем только для реального времени (для MC нет смысла).
    if (d.timeMode or "real") ~= "mc" then
        item("tz_offset", "Tz", "UTC offset",
             function()
                 local off = d.tzOffset or 3
                 return (off >= 0 and "+" or "") .. tostring(off)
             end,
             "cycle_tz")
    end

    -- Дисплей
    cat("Display")
    item("display", "Di", "Screen",
         function() return (d.display or "external") == "internal" and "Internal" or "Monitor" end,
         "switch_display")
    item("modem", "Md", "Modem",
         function() return d.modemSide or ctx.config.modemSide or "unset" end,
         "modal_modem")

    -- Звук
    cat("Sound")
    item("volume", "Vo", "Volume",
         function() return string.format("%d%%", math.floor((d.volume or 1) * 100 + 0.5)) end,
         "modal_volume")
    tog("sound_fx", "Fx", "Sound FX",
        function() return (d.soundEnabled ~= false) and "On" or "Off" end,
        "toggle_sound")

    -- Аккаунт
    if u then
        cat("Account")
        item("autolock", "Lk", "Auto-lock",
             function() return lockLabel(u.lockTimeout or 600) end,
             "lock_timeout")
        item("password", "Pw", "Password",
             function() return "Change >" end,
             "change_pass")
        act("logout", "Lo", "Logout", "logout", colors.red)
    end

    -- Система
    cat("System")
    if u and u.isAdmin then
        act("connections", "Co", "Connections", "launch_connections", colors.blue)
    end
    act("lock_now",  "Lk", "Lock Now",  "lock_now",         colors.orange or colors.yellow)
    act("os_update", "Up", "OS Update", "launch_os_update",  colors.blue)
    act("about",     "Ab", "About",     "about",             nil)

    return rows
end

-- ── Отрисовка: главный список ────────────────────────────────────────────────

local HDR_H = 1  -- строка заголовка

local function drawList(st, win, W, H, theme)
    local bg  = theme.pageBg   or colors.black
    local hb  = theme.headerBg or colors.blue
    local hf  = theme.headerFg or colors.white
    local ac  = theme.accentBg or colors.cyan
    local rf  = theme.rowFg    or colors.white
    local mf  = theme.mutedFg  or colors.lightGray

    local contW = W - 1  -- 1 колонка для скроллбара

    win.setBackgroundColor(bg); win.clear()

    -- Заголовок
    win.setCursorPos(1, 1); win.setBackgroundColor(hb); win.setTextColor(hf)
    win.write(string.rep(" ", W))
    win.setCursorPos(1, 1); win.write(" SETTINGS")

    local rows  = st.rows
    local visH  = H - HDR_H
    local first = st.scroll + 1
    local last  = math.min(#rows, first + visH - 1)

    for i = first, last do
        local row = rows[i]
        local y   = HDR_H + (i - first) + 1
        win.setCursorPos(1, y)

        if row.type == "cat" then
            win.setBackgroundColor(ac); win.setTextColor(colors.black)
            local t = " " .. string.upper(row.text)
            win.write(t .. string.rep(" ", contW - #t))

        elseif row.type == "item" or row.type == "toggle" then
            win.setBackgroundColor(bg)
            -- Иконка
            win.setBackgroundColor(ac); win.setTextColor(colors.black)
            win.write("[" .. (row.icon or "??") .. "]")
            win.setBackgroundColor(bg)
            -- Имя
            local val    = row.getValue and row.getValue() or ""
            local arrow  = row.type == "item" and " >" or ""
            local valStr = val .. arrow
            -- Ширина имени = contW - 4(icon) - 1(пробел) - len(val) - 1(пробел)
            local nameW  = math.max(1, contW - 6 - #valStr)
            local name   = row.name or ""
            if #name > nameW then name = string.sub(name, 1, nameW) end
            win.setTextColor(rf)
            win.write(" " .. name .. string.rep(" ", nameW - #name) .. " ")
            win.setTextColor(mf)
            win.write(valStr)

        elseif row.type == "action" then
            local abg = row.color or bg
            local afg = (abg == bg) and rf or colors.white
            win.setBackgroundColor(abg); win.setTextColor(afg)
            local t = "    " .. (row.name or "")
            win.write(t .. string.rep(" ", contW - #t))
        end
    end

    -- Пустые строки
    for y = HDR_H + (last - first + 1) + 1, H do
        win.setCursorPos(1, y); win.setBackgroundColor(bg)
        win.write(string.rep(" ", contW))
    end

    -- Скроллбар
    st.sb:setBounds(W, HDR_H + 1, H)
    st.sb:setContent(visH, #rows)
    st.sb:setScroll(st.scroll)
    st.sb:draw(win)
end

-- ── Отрисовка: About ─────────────────────────────────────────────────────────

local function drawAbout(st, win, W, H, theme)
    local bg = theme.pageBg   or colors.black
    local hb = theme.headerBg or colors.blue
    local hf = theme.headerFg or colors.white
    local rf = theme.rowFg    or colors.white
    local mf = theme.mutedFg  or colors.lightGray
    local ac = theme.accentBg or colors.cyan

    win.setBackgroundColor(bg); win.clear()
    win.setCursorPos(1, 1); win.setBackgroundColor(hb); win.setTextColor(hf)
    win.write(string.rep(" ", W))
    win.setCursorPos(1, 1); win.write(" ABOUT")
    win.setCursorPos(W - 5, 1); win.setBackgroundColor(colors.gray); win.setTextColor(colors.white)
    win.write("[Back]")

    local cfg = st.ctx.config
    local y   = 3

    local function line(label, val)
        if y > H then return end
        local valStr  = tostring(val or "—")
        local lineLen = 2 + #label + 1 + #valStr  -- indent + label + space + value
        win.setCursorPos(2, y); win.setBackgroundColor(bg)
        win.setTextColor(mf); win.write(label .. " ")
        if lineLen <= W then
            win.setTextColor(rf); win.write(valStr)
            y = y + 1
        else
            -- Значение не влезает — переносим на следующую строку с отступом.
            y = y + 1
            if y <= H then
                local maxV = W - 4
                if #valStr > maxV then valStr = string.sub(valStr, 1, maxV) end
                win.setCursorPos(4, y); win.setTextColor(rf); win.write(valStr)
                y = y + 1
            end
        end
    end

    win.setCursorPos(2, y); win.setBackgroundColor(bg); win.setTextColor(rf)
    win.setBackgroundColor(ac); win.setTextColor(colors.black)
    win.write(" MineboomOS ")
    y = y + 2; win.setBackgroundColor(bg)

    -- Читаем манифест напрямую с диска, минуя кеш Loader.require,
    -- чтобы после обновления OS версия сразу отражала реальное состояние.
    local liveMf = nil
    pcall(function() liveMf = dofile("/os/manifest.lua") end)
    local liveVer     = (type(liveMf) == "table" and liveMf.version)  or cfg.osVersion or "unknown"
    local liveChan    = (type(liveMf) == "table" and liveMf.channel)  or "?"

    line("Version:", liveVer)
    line("Channel:", liveChan)
    line("Computer:", "#" .. tostring(cfg.computerId or "?"))
    line("Label:",    cfg.computerLabel or "—")
    y = y + 1

    local ok, n = pcall(fs.getFreeSpace, "/")
    local freeStr = (ok and type(n) == "number") and (math.floor(n/1024) .. " KB") or "—"
    line("Free space:", freeStr)

    if cfg.userServerId then line("User server:", "#" .. cfg.userServerId) end
    if cfg.storeComputer then line("App store:",   "#" .. cfg.storeComputer) end
    if cfg.hubComputer   then line("Hub:",         "#" .. cfg.hubComputer)   end
end

-- ── Отрисовка: смена пароля ──────────────────────────────────────────────────

local function drawChangePass(st, win, W, H, theme)
    local bg = theme.pageBg   or colors.black
    local hb = theme.headerBg or colors.blue
    local hf = theme.headerFg or colors.white
    local rf = theme.rowFg    or colors.white
    local mf = theme.mutedFg  or colors.lightGray

    win.setBackgroundColor(bg); win.clear()
    win.setCursorPos(1, 1); win.setBackgroundColor(hb); win.setTextColor(hf)
    win.write(string.rep(" ", W))
    win.setCursorPos(1, 1); win.write(" CHANGE PASSWORD")
    win.setCursorPos(W - 5, 1); win.setBackgroundColor(colors.gray); win.setTextColor(colors.white)
    win.write("[Back]")

    local y = 3
    win.setCursorPos(2, y); win.setBackgroundColor(bg)
    win.setTextColor(st.passStep == 1 and rf or mf)
    win.write("New:     " .. string.rep("*", #st.passNew)); y = y + 1

    if st.passStep >= 2 then
        win.setCursorPos(2, y)
        win.setTextColor(st.passStep == 2 and rf or mf)
        win.write("Confirm: " .. string.rep("*", #st.passConfirm)); y = y + 1
    end

    if st.passError ~= "" then
        win.setCursorPos(2, y); win.setTextColor(colors.red)
        win.write(st.passError); y = y + 1
    end

    local kx = math.floor((W - 11) / 2) + 1
    drawKeypad(win, kx, y + 1, theme)
end

-- ── init / draw ──────────────────────────────────────────────────────────────

function M.init(win, ctx)
    return {
        win         = win,
        ctx         = ctx,
        Shell       = loadShell(),
        scroll      = 0,
        subMode     = nil,   -- nil | "about" | "change_pass"
        rows        = {},
        passStep    = 1,
        passNew     = "",
        passConfirm = "",
        passError   = "",
        sb = Scrollbar.create({thumbBg = colors.lightGray, thumbFg = colors.black}),
    }
end

function M.draw(st, win)
    local W, H  = win.getSize()
    local theme = st.Shell.getTheme(st.ctx.desktop.themeIndex)
    -- Обновляем список каждый кадр — значения берутся live из desktop/currentUser
    st.rows = buildRows(st)

    if st.subMode == "about" then
        drawAbout(st, win, W, H, theme)
    elseif st.subMode == "change_pass" then
        drawChangePass(st, win, W, H, theme)
    else
        drawList(st, win, W, H, theme)
    end
end

-- ── Действия по строке ───────────────────────────────────────────────────────

local function applyAction(st, action)
    local d = st.ctx.desktop
    local u = st.ctx.currentUser

    if action == "modal_theme" then
        os.queueEvent("pocketos_event", "open_modal",
            {kind = "theme", scroll = 0, selected = d.themeIndex or 1})
    elseif action == "modal_wallpaper" then
        local idx = 1
        for i, w in ipairs(st.ctx.wallpapers or {}) do
            if w == d.pattern then idx = i; break end
        end
        os.queueEvent("pocketos_event", "open_modal",
            {kind = "wallpaper", scroll = 0, selected = idx})
    elseif action == "modal_volume" then
        os.queueEvent("pocketos_event", "open_modal",
            {kind = "volume", value = d.volume or 1})
    elseif action == "modal_scale" then
        os.queueEvent("pocketos_event", "open_modal",
            {kind = "scale", value = d.textScale or 1})
    elseif action == "modal_modem" then
        local cur = d.modemSide or st.ctx.config.modemSide
        local idx = 1
        for i, s in ipairs(MODEM_SIDES) do if s == cur then idx = i; break end end
        os.queueEvent("pocketos_event", "open_modal",
            {kind = "modem", scroll = 0, selected = idx, items = MODEM_SIDES})
    elseif action == "switch_display" then
        local newMode = (d.display or "external") == "external" and "internal" or "external"
        d.display = newMode
        st.ctx.saveDesktop()
        os.queueEvent("pocketos_event", "switch_display", newMode)
    elseif action == "toggle_clock" then
        d.clockFormat = (d.clockFormat == "12h") and "24h" or "12h"
        st.ctx.saveDesktop()
    elseif action == "toggle_time_mode" then
        d.timeMode = (d.timeMode == "mc") and "real" or "mc"
        st.ctx.saveDesktop()
    elseif action == "cycle_tz" then
        -- Перебор смещения от -12 до +14 по часу, по кругу.
        local off = (d.tzOffset or 3) + 1
        if off > 14 then off = -12 end
        d.tzOffset = off
        st.ctx.saveDesktop()
    elseif action == "toggle_sound" then
        d.soundEnabled = not (d.soundEnabled ~= false)
        st.ctx.saveDesktop()
    elseif action == "lock_timeout" then
        if u then
            local newT = lockCycle(u.lockTimeout or 600, 1)
            os.queueEvent("pocketos_event", "set_lock_timeout", newT)
            u.lockTimeout = newT  -- optimistic update для live display
        end
    elseif action == "change_pass" then
        st.subMode    = "change_pass"
        st.passStep   = 1
        st.passNew    = ""
        st.passConfirm = ""
        st.passError  = ""
    elseif action == "logout" then
        os.queueEvent("pocketos_event", "logout")
    elseif action == "lock_now" then
        if st.ctx.lockDevice then st.ctx.lockDevice() end
    elseif action == "launch_os_update" then
        os.queueEvent("pocketos_event", "launch_app", "os_update")
    elseif action == "launch_connections" then
        os.queueEvent("pocketos_event", "launch_app", "connections")
    elseif action == "about" then
        st.subMode = "about"
    end
end

-- ── onEvent ──────────────────────────────────────────────────────────────────

function M.onEvent(st, event, p1, p2, p3)
    local W, H = st.win.getSize()

    if event == "mouse_click" or event == "monitor_touch" then
        local x, y = p2, p3

        -- Sub-screen: About
        if st.subMode == "about" then
            if y == 1 and x >= W - 5 then st.subMode = nil end
            return st, true
        end

        -- Sub-screen: Change password
        if st.subMode == "change_pass" then
            if y == 1 and x >= W - 5 then st.subMode = nil; return st, true end

            local baseY = 3
            if st.passStep >= 2    then baseY = baseY + 1 end
            if st.passError ~= ""  then baseY = baseY + 1 end
            local kx = math.floor((W - 11) / 2) + 1
            local ky = baseY + 1

            local ka, kd = kpadHit(x, y, kx, ky)
            if ka then
                changePassAction(st, ka, kd)
            end
            return st, true
        end

        -- Скроллбар
        if st.sb:onClick(x, y) then
            st.scroll = st.sb.scroll
            return st, true
        end

        -- Строки списка
        if y > HDR_H then
            local idx = st.scroll + (y - HDR_H)
            local row = st.rows[idx]
            if row and (row.type == "item" or row.type == "toggle" or row.type == "action") then
                applyAction(st, row.action)
                return st, true
            end
        end
    end

    if event == "mouse_scroll" then
        local maxScroll = math.max(0, #st.rows - (H - HDR_H))
        st.scroll = math.max(0, math.min(maxScroll, st.scroll + p1))
        return st, true
    end

    if st.subMode == "change_pass" and event == "char" and isDigitChar(p1) then
        changePassAction(st, "digit", p1)
        return st, true
    end

    if st.subMode == "change_pass" and event == "key" then
        if p1 == keys.backspace then
            changePassAction(st, "backspace")
            return st, true
        elseif isEnterKey(p1) then
            changePassAction(st, "ok")
            return st, true
        elseif p1 == keys.escape then
            st.subMode = nil
            return st, true
        end
    end

    return st, false
end

return M
