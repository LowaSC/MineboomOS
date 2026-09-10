-- Экран блокировки / скринсейвер.
local Clock = dofile("/os/lib/clock.lua")

local LockScreen = {}

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

function LockScreen.render(screen, W, AH, currentUser, clockOpts, networkStatus)
    screen.setBackgroundColor(colors.black)
    screen.clear()

    local cx = math.floor(W / 2)
    local cy = math.floor(AH / 2)

    -- Большие часы
    local timeStr = getTimeStr(clockOpts)
    screen.setCursorPos(cx - math.floor(#timeStr * 2), cy - 2)
    screen.setBackgroundColor(colors.black)
    screen.setTextColor(colors.white)
    -- Крупный шрифт — просто пишем с пробелами между символами
    local big = ""
    for i = 1, #timeStr do
        big = big .. string.sub(timeStr, i, i) .. " "
    end
    big = string.sub(big, 1, -2)
    screen.setCursorPos(math.floor((W - #big) / 2) + 1, cy - 2)
    screen.write(big)

    -- Дата
    local dateStr = getDateStr(clockOpts)
    if dateStr ~= "" then
        screen.setCursorPos(math.floor((W - #dateStr) / 2) + 1, cy)
        screen.setTextColor(colors.lightGray)
        screen.write(dateStr)
    end

    -- Имя пользователя
    local name = currentUser and currentUser.name or "Unknown"
    screen.setCursorPos(math.floor((W - #name) / 2) + 1, cy + 2)
    screen.setTextColor(colors.white)
    screen.write(name)

    -- Подсказка
    local hint = "[ tap to unlock ]"
    screen.setCursorPos(math.floor((W - #hint) / 2) + 1, cy + 4)
    screen.setTextColor(colors.gray)
    screen.write(hint)

    if networkStatus and networkStatus.remote and not networkStatus.online then
        local msg = "Offline mode - network unavailable"
        if networkStatus.detail and networkStatus.detail ~= "" then
            msg = msg .. ": " .. tostring(networkStatus.detail)
        end
        msg = string.sub(msg, 1, W)
        screen.setCursorPos(math.floor((W - #msg) / 2) + 1, AH)
        screen.setTextColor(colors.orange or colors.yellow)
        screen.write(msg)
    end
end

function LockScreen.hit(x, y, W, AH)
    return "unlock"
end

return LockScreen
