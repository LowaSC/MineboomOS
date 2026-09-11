-- Экран входа в систему. Не является приложением — вызывается из init.lua.
-- Рендерит на переданном screen, обрабатывает клики.
local Login = {}

-- Раскладка числовой клавиатуры: 3x4 кнопки (7 8 9 / 4 5 6 / 1 2 3 / X 0 OK)
local KEYPAD = {
    {7, 8, 9},
    {4, 5, 6},
    {1, 2, 3},
    {"X", 0, "OK"},
}

local BTN_W = 3
local BTN_H = 1

-- Версия ОС берётся из манифеста (единый источник правды), чтобы её не
-- приходилось править вручную в нескольких местах. Читаем один раз и кэшируем.
local _osVersion
local function osVersion()
    if _osVersion then return _osVersion end
    local ok, mf = pcall(dofile, "/os/manifest.lua")
    if ok and type(mf) == "table" and mf.version then
        _osVersion = tostring(mf.version)
    else
        _osVersion = "?"
    end
    return _osVersion
end

local function padC(s, w)
    s = tostring(s or "")
    if #s >= w then return string.sub(s, 1, w) end
    local pad = w - #s
    local l = math.floor(pad / 2)
    local r = pad - l
    return string.rep(" ", l) .. s .. string.rep(" ", r)
end

-- Возвращает начальный state для экрана входа.
-- users: список {id, name, ...}; session: {userId=...} или nil;
-- lastUserId: id последнего входившего (показываем его, если сессии нет).
function Login.initialState(users, session, lastUserId)
    local idx = 1
    local wantId = (session and session.userId) or lastUserId
    if wantId then
        for i, u in ipairs(users) do
            if u.id == wantId then idx = i; break end
        end
    end
    return {
        users      = users,
        userIdx    = idx,
        password   = "",
        remember   = session ~= nil,
        error      = "",
        mode       = "login",   -- "login" | "register"
        -- поля для режима регистрации
        regStep    = 1,         -- 1=имя (выбор), 2=пароль, 3=подтверждение
        regName    = "",
        regPass    = "",
        regConfirm = "",
        regError   = "",
    }
end

-- Вычисляет геометрию экрана входа.
local function geom(W, AH)
    local halfW   = math.floor(W / 2)
    local rightX  = halfW + 2
    local rightW  = W - halfW - 1

    -- Позиция клавиатуры: 4 ряда кнопок, каждая BTN_W+1 символ шириной.
    -- Центрируем по правой половине.
    local kpadW = 3 * (BTN_W + 1) - 1  -- 11
    local kpadX = rightX + math.floor((rightW - kpadW) / 2)
    local kpadY = math.floor(AH / 2) - 1  -- немного выше центра

    return {
        halfW  = halfW,
        rightX = rightX,
        rightW = rightW,
        kpadX  = kpadX,
        kpadY  = kpadY,
    }
end

-- Ширина и высота клавиатуры в символах: их используют и логин, и экран
-- блокировки, чтобы разместить её на своей раскладке.
Login.KEYPAD_W = 3 * (BTN_W + 1) - 1
Login.KEYPAD_H = #KEYPAD * (BTN_H + 1) - 1

-- Рисует клавиатуру с левым верхним углом (kpadX, kpadY).
function Login.drawKeypad(screen, kpadX, kpadY, theme)
    theme = theme or {}
    local ac = theme.accentBg or colors.cyan
    for row, keys in ipairs(KEYPAD) do
        local y = kpadY + (row - 1) * (BTN_H + 1)
        for col, k in ipairs(keys) do
            local x = kpadX + (col - 1) * (BTN_W + 1)
            local kbg = (k == "OK") and colors.green
                     or (k == "X")  and colors.red
                     or ac
            local kfg = (kbg == colors.red or kbg == colors.green)
                        and colors.white or colors.black
            screen.setCursorPos(x, y)
            screen.setBackgroundColor(kbg)
            screen.setTextColor(kfg)
            screen.write(padC(tostring(k), BTN_W))
        end
    end
end

-- Hit-тест клавиатуры: ("digit", n) / "backspace" / "ok" / nil.
function Login.keypadHit(x, y, kpadX, kpadY)
    for row, keys in ipairs(KEYPAD) do
        local ky = kpadY + (row - 1) * (BTN_H + 1)
        if y == ky then
            for col, k in ipairs(keys) do
                local kx = kpadX + (col - 1) * (BTN_W + 1)
                if x >= kx and x < kx + BTN_W then
                    if k == "X"  then return "backspace" end
                    if k == "OK" then return "ok" end
                    return "digit", k
                end
            end
        end
    end
    return nil
end

local function drawKeypad(screen, g, theme)
    Login.drawKeypad(screen, g.kpadX, g.kpadY, theme)
end

function Login.render(screen, W, AH, state, theme)
    theme = theme or {}
    local hb  = theme.headerBg or colors.blue
    local hf  = theme.headerFg or colors.white
    local bg  = theme.pageBg   or colors.black
    local ac  = theme.accentBg or colors.cyan
    local sf  = theme.rowFg    or colors.white   -- текст на тёмном pageBg
    local mf  = theme.mutedFg  or colors.lightGray

    screen.setBackgroundColor(bg)
    screen.clear()

    local g = geom(W, AH)

    -- ── Левая панель: лого ОС ───────────────────────────────────────────────
    local logoY = math.floor(AH / 2) - 2
    screen.setCursorPos(math.floor((g.halfW - 11) / 2) + 1, logoY)
    screen.setBackgroundColor(hb)
    screen.setTextColor(hf)
    screen.write(" MineboomOS ")

    local ver = string.sub("v" .. osVersion(), 1, g.halfW)
    screen.setCursorPos(math.floor((g.halfW - #ver) / 2) + 1, logoY + 2)
    screen.setBackgroundColor(bg)
    screen.setTextColor(mf)
    screen.write(ver)

    if state.networkStatus and state.networkStatus.remote and not state.networkStatus.online then
        local msg = "Offline mode"
        screen.setCursorPos(math.floor((g.halfW - #msg) / 2) + 1, logoY + 4)
        screen.setTextColor(colors.orange or colors.yellow)
        screen.write(msg)
    end
    if state.networkStatus and state.networkStatus.remote then
        screen.setCursorPos(1, AH - 2)
        screen.setBackgroundColor(bg); screen.setTextColor(mf)
        screen.write(("Shared accounts"):sub(1, g.halfW))
    end
    if state.allowLocalLogin then
        screen.setCursorPos(1, AH)
        screen.setBackgroundColor(colors.gray); screen.setTextColor(colors.white)
        screen.write(("[Local login]"):sub(1, g.halfW))
    end

    -- Разделитель
    screen.setBackgroundColor(bg)
    screen.setTextColor(colors.gray)
    for y = 1, AH do
        screen.setCursorPos(g.halfW + 1, y)
        screen.write("|")
    end

    if state.mode == "register" then
        Login.renderRegister(screen, W, AH, state, theme, g)
        return
    end

    -- ── Правая панель: вход ─────────────────────────────────────────────────
    local users = state.users or {}
    local u = users[state.userIdx]
    local userName = u and u.name or "---"

    -- Заголовок
    local headerY = g.kpadY - 5
    if headerY < 2 then headerY = 2 end

    screen.setCursorPos(g.rightX, headerY)
    screen.setBackgroundColor(bg)
    screen.setTextColor(sf)
    screen.write("User:")

    -- Пикер пользователя
    local pickerY = headerY + 1
    local totalW  = g.rightW - 2
    screen.setCursorPos(g.rightX, pickerY)
    screen.setBackgroundColor(ac)
    screen.setTextColor(colors.black)
    screen.write("<")
    screen.setBackgroundColor(bg)
    screen.setTextColor(sf)
    local nameW = totalW - 2
    local name  = string.sub(userName, 1, nameW)
    name = name .. string.rep(" ", nameW - #name)
    screen.write(name)
    screen.setBackgroundColor(ac)
    screen.setTextColor(colors.black)
    screen.write(">")

    -- Пароль (точки)
    local passY  = pickerY + 2
    screen.setCursorPos(g.rightX, passY)
    screen.setBackgroundColor(bg)
    screen.setTextColor(mf)
    screen.write("Pass: ")
    screen.setTextColor(sf)
    local dots = string.rep("*", math.min(#state.password, g.rightW - 6))
    screen.write(dots)

    -- Ошибка
    if state.error and state.error ~= "" then
        screen.setCursorPos(g.rightX, passY + 1)
        screen.setBackgroundColor(bg)
        screen.setTextColor(colors.red)
        local errStr = string.sub(state.error, 1, g.rightW)
        screen.write(errStr)
    end

    -- Клавиатура
    drawKeypad(screen, g, theme)

    -- Remember me
    local remY = g.kpadY + #KEYPAD * 2 + 1
    screen.setCursorPos(g.rightX, remY)
    screen.setBackgroundColor(bg)
    screen.setTextColor(mf)
    local remBox = state.remember and "[x]" or "[ ]"
    screen.write(remBox .. " Remember me")
end

function Login.renderRegister(screen, W, AH, state, theme, g)
    local bg = theme.pageBg  or colors.black
    local sf = theme.rowFg   or colors.white   -- текст на тёмном pageBg
    local mf = theme.mutedFg or colors.lightGray
    local ac = theme.accentBg or colors.cyan

    local rx = g.rightX

    screen.setCursorPos(rx, 2)
    screen.setBackgroundColor(bg)
    screen.setTextColor(sf)
    screen.write("New user")

    -- Шаг 1: имя
    local step1Y = 4
    screen.setCursorPos(rx, step1Y)
    screen.setTextColor(state.regStep == 1 and sf or mf)
    screen.write("Name: " .. (state.regName ~= "" and state.regName or "_"))

    -- Шаг 2: пароль
    local step2Y = step1Y + 2
    if state.regStep >= 2 then
        screen.setCursorPos(rx, step2Y)
        screen.setTextColor(state.regStep == 2 and sf or mf)
        screen.write("Pass: " .. string.rep("*", #state.regPass))
    end

    -- Шаг 3: подтверждение
    local step3Y = step2Y + 2
    if state.regStep >= 3 then
        screen.setCursorPos(rx, step3Y)
        screen.setTextColor(state.regStep == 3 and sf or mf)
        screen.write("Confirm: " .. string.rep("*", #state.regConfirm))
    end

    -- Ошибка
    if state.regError ~= "" then
        local errY = step3Y + 2
        screen.setCursorPos(rx, errY)
        screen.setTextColor(colors.red)
        screen.write(string.sub(state.regError, 1, g.rightW))
    end

    drawKeypad(screen, g, theme)

    -- Шаг 1: ввод имени — показываем цифровую клавиатуру для цифр
    -- но имя лучше вводить через char. Покажем подсказку.
    local hintY = g.kpadY - 1
    screen.setCursorPos(rx, hintY)
    screen.setBackgroundColor(bg)
    screen.setTextColor(mf)
    if state.regStep == 1 then
        screen.write("Type name, then OK")
    else
        screen.write("Enter digits, OK=next")
    end

    -- Кнопка отмены
    local canY = g.kpadY + #KEYPAD * 2 + 1
    if canY <= AH then
        screen.setCursorPos(rx, canY)
        screen.setBackgroundColor(colors.gray)
        screen.setTextColor(colors.white)
        screen.write("[Cancel]")
    end
end

-- Hit-тест клавиатуры. Возвращает ("digit",n) / ("backspace") / ("ok") /
-- ("user_prev") / ("user_next") / ("remember") / ("register") / ("cancel") / nil
function Login.hit(x, y, W, AH, state)
    local g = geom(W, AH)
    if state.allowLocalLogin and y == AH and x >= 1 and x <= math.min(13, g.halfW) then
        return "local_login"
    end

    -- Пикер пользователя (только в режиме login)
    if state.mode == "login" then
        local pickerY = (g.kpadY - 5 < 2 and 2 or g.kpadY - 5) + 1
        if y == pickerY then
            if x == g.rightX then return "user_prev" end
            if x == g.rightX + g.rightW - 3 then return "user_next" end
        end

        -- Remember
        local remY = g.kpadY + #KEYPAD * 2 + 1
        if y == remY and x >= g.rightX then return "remember" end
    else
        -- Cancel
        local canY = g.kpadY + #KEYPAD * 2 + 1
        if y == canY and x >= g.rightX and x < g.rightX + 8 then return "cancel" end
    end

    -- Клавиатура
    return Login.keypadHit(x, y, g.kpadX, g.kpadY)
end

return Login
