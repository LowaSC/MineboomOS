-- Экран блокировки. Показывает часы и имя пользователя, но рабочий стол
-- возвращает только после ввода PIN этого пользователя: запущенные приложения
-- при этом сохраняются. Кнопка Logout (или исчерпанные попытки) закрывает
-- сессию и уводит на экран входа.
local Clock = dofile("/os/lib/clock.lua")
local Login = dofile("/os/lib/pocketos/login.lua")

local LockScreen = {}
LockScreen.MAX_ATTEMPTS = 5
LockScreen.LOGOUT_LABEL = "[Logout]"

-- Состояние ввода. Создаётся при каждой блокировке.
function LockScreen.initialState()
    return {pin = "", error = "", attempts = 0}
end

-- opts: Clock.optsFromDesktop(desktop) — режим/смещение времени.
local function getTimeStr(opts)
    return Clock.clockStr(opts)
end

local function getDateStr(opts)
    local c = Clock.calendar(opts)
    if not c.hasDate then
        if c.mode == "mc" and c.mcDay then return "MC Day " .. tostring(c.mcDay) end
        return ""
    end
    return (Clock.DAYS[c.wday] or "") .. " " .. tostring(c.day) .. " " .. (Clock.MONTHS[c.mon] or "")
end

-- Раскладка сверху вниз: часы, дата, имя, PIN, клавиатура, статус, Logout.
-- На карманном компьютере (26x20) занимает весь экран, на мониторах
-- центрируется по вертикали.
local function geom(W, AH)
    local total = 18
    local top = math.max(1, math.floor((AH - total) / 2) + 1)
    return {
        clockY  = top,
        dateY   = top + 1,
        nameY   = top + 3,
        pinY    = top + 4,
        kpadX   = math.floor((W - Login.KEYPAD_W) / 2) + 1,
        kpadY   = top + 6,
        statusY = top + 6 + Login.KEYPAD_H + 1,
        logoutY = top + 6 + Login.KEYPAD_H + 3,
        logoutX = math.floor((W - #LockScreen.LOGOUT_LABEL) / 2) + 1,
    }
end

local function centered(screen, W, y, text, fg)
    screen.setCursorPos(math.floor((W - #text) / 2) + 1, y)
    screen.setTextColor(fg)
    screen.write(text)
end

function LockScreen.render(screen, W, AH, currentUser, clockOpts, networkStatus, state, theme)
    state = state or LockScreen.initialState()
    screen.setBackgroundColor(colors.black)
    screen.clear()

    local g = geom(W, AH)

    -- Часы вразрядку, чтобы читались издалека
    local timeStr = getTimeStr(clockOpts)
    local big = ""
    for i = 1, #timeStr do big = big .. string.sub(timeStr, i, i) .. " " end
    centered(screen, W, g.clockY, string.sub(big, 1, -2), colors.white)

    local dateStr = getDateStr(clockOpts)
    if dateStr ~= "" then centered(screen, W, g.dateY, dateStr, colors.lightGray) end

    local name = currentUser and currentUser.name or "Unknown"
    centered(screen, W, g.nameY, string.sub(name, 1, W), colors.white)

    local dots = string.rep("*", math.min(#state.pin, W - 5))
    centered(screen, W, g.pinY, "PIN: " .. dots, #state.pin > 0 and colors.white or colors.gray)

    Login.drawKeypad(screen, g.kpadX, g.kpadY, theme)
    screen.setBackgroundColor(colors.black)

    if state.error and state.error ~= "" then
        centered(screen, W, g.statusY, string.sub(state.error, 1, W), colors.red)
    elseif networkStatus and networkStatus.remote and not networkStatus.online then
        centered(screen, W, g.statusY, string.sub("Offline mode", 1, W), colors.orange or colors.yellow)
    else
        centered(screen, W, g.statusY, "Enter PIN to unlock", colors.gray)
    end

    if g.logoutY <= AH then
        screen.setCursorPos(g.logoutX, g.logoutY)
        screen.setBackgroundColor(colors.gray)
        screen.setTextColor(colors.white)
        screen.write(LockScreen.LOGOUT_LABEL)
        screen.setBackgroundColor(colors.black)
    end
end

-- Hit-тест: ("digit", n) / "backspace" / "ok" / "logout" / nil.
-- Касание мимо кнопок ничего не делает: экран больше не снимается тапом.
function LockScreen.hit(x, y, W, AH)
    local g = geom(W, AH)
    if y == g.logoutY and x >= g.logoutX and x < g.logoutX + #LockScreen.LOGOUT_LABEL then
        return "logout"
    end
    return Login.keypadHit(x, y, g.kpadX, g.kpadY)
end

return LockScreen
