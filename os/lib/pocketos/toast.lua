-- Toast notifications для PocketOS.
-- Toast — короткое сообщение, появляющееся над таскбаром на несколько секунд.
-- Очередь FIFO: новые тосты вытесняют старые после показа.
local Toast = {}

Toast.DEFAULT_TTL = 3         -- секунды
Toast.MAX_QUEUE   = 5

local _queue = {}              -- {{text, level, expiresAt}, ...}

local function epochSeconds()
    if os.epoch then return os.epoch("utc") / 1000 end
    return os.clock()
end

local function levelColors(level, theme)
    if level == "error"   then return colors.red,     colors.white  end
    if level == "warn"    then return colors.orange,  colors.black  end
    if level == "success" then return colors.lime,    colors.black  end
    -- default = info
    return theme.accentBg or colors.cyan, colors.black
end

-- Добавляет toast в очередь. Возвращает true если очередь нужно перерисовать.
function Toast.push(text, opts)
    opts = opts or {}
    local now = epochSeconds()
    local ttl = opts.ttl or Toast.DEFAULT_TTL
    table.insert(_queue, {
        text      = tostring(text or ""),
        level     = opts.level or "info",
        expiresAt = now + ttl,
    })
    while #_queue > Toast.MAX_QUEUE do table.remove(_queue, 1) end
    return true
end

-- Удаляет истёкшие тосты. Возвращает true если очередь изменилась.
function Toast.prune()
    local now = epochSeconds()
    local changed = false
    for i = #_queue, 1, -1 do
        if _queue[i].expiresAt <= now then
            table.remove(_queue, i)
            changed = true
        end
    end
    return changed
end

-- Самый свежий активный тост или nil.
function Toast.current()
    local now = epochSeconds()
    for i = #_queue, 1, -1 do
        if _queue[i].expiresAt > now then return _queue[i] end
    end
    return nil
end

-- Через сколько секунд истечёт текущий тост (для os.startTimer).
function Toast.nextExpiry()
    local now = epochSeconds()
    local soonest = nil
    for _, t in ipairs(_queue) do
        if t.expiresAt > now then
            if soonest == nil or t.expiresAt < soonest then
                soonest = t.expiresAt
            end
        end
    end
    if soonest == nil then return nil end
    return math.max(0.1, soonest - now)
end

-- Рисует текущий тост (если есть) в одну строку поверх над таскбаром.
-- Возвращает true если что-то нарисовано.
function Toast.draw(workArea, theme, W, AH)
    local t = Toast.current()
    if not t then return false end

    local bg, fg = levelColors(t.level, theme)
    local y = AH
    local text = t.text
    if #text > W - 2 then text = string.sub(text, 1, W - 2) end
    local pad = math.max(0, W - #text - 2)
    local leftPad = math.floor(pad / 2)
    local rightPad = pad - leftPad

    workArea.setCursorPos(1, y)
    workArea.setBackgroundColor(bg)
    workArea.setTextColor(fg)
    workArea.write(string.rep(" ", leftPad + 1) .. text .. string.rep(" ", rightPad + 1))
    return true
end

function Toast.clear()
    _queue = {}
end

return Toast
