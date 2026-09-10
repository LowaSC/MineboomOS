-- Лог-сервис MineboomOS. Пишет строки в /data/logs/system.log с ротацией.
-- Можно использовать как ctx.log("info"|"warn"|"error", message).
local FsUtil = dofile("/os/lib/fsutil.lua")

local Log = {}

Log.LOG_DIR       = "/data/logs"
Log.LOG_FILE      = Log.LOG_DIR .. "/system.log"
Log.LOG_FILE_OLD  = Log.LOG_DIR .. "/system.log.1"
Log.MAX_BYTES     = 32768                  -- ~32 KB на файл, дальше rotate
Log.MAX_LINES     = 200                    -- сколько последних строк держим в памяти

local _buffer  = {}                        -- кольцевой буфер последних записей
local _listeners = {}                      -- подписчики на новые записи

local LEVEL_RANK = {debug = 0, info = 1, warn = 2, error = 3}

local function epochSeconds()
    if os.epoch then return math.floor(os.epoch("utc") / 1000) end
    return math.floor(os.clock())
end

local function fmtTime(ts)
    -- Лёгкое форматирование: HH:MM:SS из эпохи.
    return string.format("%02d:%02d:%02d",
        math.floor(ts / 3600) % 24,
        math.floor(ts / 60)   % 60,
        ts % 60)
end

local function rotateIfNeeded()
    if not fs.exists(Log.LOG_FILE) then return end
    local size = fs.getSize(Log.LOG_FILE)
    if size < Log.MAX_BYTES then return end
    if fs.exists(Log.LOG_FILE_OLD) then fs.delete(Log.LOG_FILE_OLD) end
    pcall(fs.move, Log.LOG_FILE, Log.LOG_FILE_OLD)
end

local function appendLine(line)
    FsUtil.ensureDir(Log.LOG_DIR)
    rotateIfNeeded()
    local handle = fs.open(Log.LOG_FILE, "a")
    if not handle then return end
    handle.writeLine(line)
    handle.close()
end

local function pushBuffer(entry)
    table.insert(_buffer, entry)
    while #_buffer > Log.MAX_LINES do table.remove(_buffer, 1) end
end

local function dispatch(entry)
    for _, fn in ipairs(_listeners) do
        pcall(fn, entry)
    end
end

-- Запись произвольного уровня.
function Log.write(level, message, source)
    level = tostring(level or "info")
    if LEVEL_RANK[level] == nil then level = "info" end
    local entry = {
        ts      = epochSeconds(),
        level   = level,
        source  = source,
        message = tostring(message or ""),
    }
    local line = string.format("%s [%s]%s %s",
        fmtTime(entry.ts),
        string.upper(level),
        source and (" " .. source) or "",
        entry.message)

    appendLine(line)
    pushBuffer(entry)
    dispatch(entry)
end

function Log.debug(msg, src) Log.write("debug", msg, src) end
function Log.info (msg, src) Log.write("info",  msg, src) end
function Log.warn (msg, src) Log.write("warn",  msg, src) end
function Log.error(msg, src) Log.write("error", msg, src) end

-- Снимок последних записей (для UI Logs).
function Log.tail(limit)
    limit = limit or Log.MAX_LINES
    local out = {}
    local start = math.max(1, #_buffer - limit + 1)
    for i = start, #_buffer do out[#out + 1] = _buffer[i] end
    return out
end

function Log.clear()
    _buffer = {}
    if fs.exists(Log.LOG_FILE) then fs.delete(Log.LOG_FILE) end
    if fs.exists(Log.LOG_FILE_OLD) then fs.delete(Log.LOG_FILE_OLD) end
end

function Log.subscribe(fn)
    table.insert(_listeners, fn)
    return fn
end

function Log.unsubscribe(fn)
    for i = #_listeners, 1, -1 do
        if _listeners[i] == fn then table.remove(_listeners, i) end
    end
end

-- Парсит строку лога формата "HH:MM:SS [LEVEL] [source] message".
-- Возвращает структурированную запись с raw/level/source/message — это нужно,
-- чтобы фильтр в Logs приложении видел уровень исторических записей,
-- а не только тех, что появились в текущей сессии.
local function parseLogLine(line)
    local _, _, level, rest = string.find(line, "^%S+%s+%[(%a+)%]%s*(.*)$")
    if not level then
        return {raw = line}
    end
    local lvl = string.lower(level)
    if LEVEL_RANK[lvl] == nil then lvl = "info" end
    rest = rest or ""
    local source, message = string.match(rest, "^(%S+)%s+(.*)$")
    if not source then
        source, message = nil, rest
    end
    return {
        raw     = line,
        level   = lvl,
        source  = source,
        message = message or "",
    }
end

Log.parseLogLine = parseLogLine

-- Загружает существующий лог с диска в кольцевой буфер (один раз при старте ОС).
function Log.loadFromDisk()
    if not fs.exists(Log.LOG_FILE) then return end
    local handle = fs.open(Log.LOG_FILE, "r")
    if not handle then return end
    local lines = {}
    while true do
        local line = handle.readLine()
        if not line then break end
        table.insert(lines, line)
    end
    handle.close()
    local first = math.max(1, #lines - Log.MAX_LINES + 1)
    for i = first, #lines do
        table.insert(_buffer, parseLogLine(lines[i]))
    end
end

return Log
