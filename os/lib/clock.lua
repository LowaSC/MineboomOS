-- Единый источник времени для всех экранов MineboomOS.
-- Раньше время считалось в нескольких местах по-разному (taskbar/dashboard через
-- os.epoch, lockscreen через os.time) — отсюда рассинхрон. Теперь всё идёт сюда.
--
-- Два режима (выбор в Settings, хранится в desktop.timeMode):
--   "real" — реальное время. CC отдаёт os.epoch("utc") в UTC, поэтому к нему
--            прибавляется смещение пояса (desktop.tzOffset, по умолчанию +3).
--   "mc"   — внутриигровое время Minecraft (os.time("ingame")), даты нет, вместо
--            неё номер игрового дня.
-- Формат часов хранится в desktop.clockFormat: "24h" или "12h".
local Clock = {}

-- Смещение часового пояса по умолчанию (часы). Сервер отдаёт UTC, а мы в UTC+3.
Clock.DEFAULT_TZ_OFFSET = 3

local DAYS   = {"Sun","Mon","Tue","Wed","Thu","Fri","Sat"}
local MONTHS = {"Jan","Feb","Mar","Apr","May","Jun","Jul","Aug","Sep","Oct","Nov","Dec"}
Clock.DAYS   = DAYS
Clock.MONTHS = MONTHS

-- Извлекает опции времени из таблицы desktop (или из переданного opts напрямую).
function Clock.optsFromDesktop(d)
    d = d or {}
    return {
        mode   = d.timeMode or "real",
        offset = d.tzOffset or Clock.DEFAULT_TZ_OFFSET,
        format = d.clockFormat or "24h",
    }
end

local function norm(opts)
    opts = opts or {}
    return opts.mode or "real", opts.offset or Clock.DEFAULT_TZ_OFFSET, opts.format or "24h"
end

-- Возвращает таблицу с полями времени:
--   {hh, mm, mode, hasDate, [day, wday, mon, year], [mcDay]}
function Clock.calendar(opts)
    local mode, offset = norm(opts)

    if mode == "mc" then
        local t = 0
        pcall(function() t = os.time("ingame") end)
        local day = 0
        pcall(function() day = os.day("ingame") end)
        return {
            hh = math.floor(t) % 24,
            mm = math.floor((t * 60) % 60),
            mode = "mc", hasDate = false, mcDay = day,
        }
    end

    local sec = 0
    if os.epoch then sec = math.floor(os.epoch("utc") / 1000) end
    sec = sec + math.floor(offset * 3600)

    if os.date then
        local ok, d = pcall(os.date, "!*t", sec)
        if ok and type(d) == "table" then
            return {
                hh = d.hour or 0, mm = d.min or 0,
                day = d.day, wday = d.wday, mon = d.month, year = d.year,
                mode = "real", hasDate = true,
            }
        end
    end

    return {
        hh = math.floor(sec / 3600) % 24,
        mm = math.floor(sec / 60) % 60,
        mode = "real", hasDate = false,
    }
end

local function displayHour(hh, fmt)
    if fmt ~= "12h" then return hh end
    local h = hh % 12
    if h == 0 then h = 12 end
    return h
end

-- "HH:MM" / "H:MM".
function Clock.clockStr(opts)
    local _, _, fmt = norm(opts)
    local c = Clock.calendar(opts)
    if fmt == "12h" then
        return string.format("%d:%02d", displayHour(c.hh, fmt), c.mm)
    end
    return string.format("%02d:%02d", displayHour(c.hh, fmt), c.mm)
end

return Clock
