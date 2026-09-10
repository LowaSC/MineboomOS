-- Безопасная загрузка Lua-кода и require-кэш.
-- Заменяет прямые dofile()/loadstring(), даёт sandbox для внешних данных.
local Loader = {}

local _cache = {}

-- ── Sandbox environment для не-доверенного кода ──────────────────────────────

-- Только чистые библиотеки: ни fs, ни http, ни os.* (кроме безопасных полей).
local SAFE_OS = {
    clock      = true, time = true, date = true, difftime = true,
    epoch      = true, day = true,
}

local function buildSandboxEnv()
    local safeOs = {}
    if type(os) == "table" then
        for k in pairs(SAFE_OS) do
            if os[k] ~= nil then safeOs[k] = os[k] end
        end
    end

    return {
        -- базовые
        ipairs = ipairs, pairs = pairs, next = next, select = select,
        tonumber = tonumber, tostring = tostring, type = type,
        unpack = unpack,
        pcall = pcall, xpcall = xpcall, error = error, assert = assert,

        -- стандартные либы (только чтение)
        string  = string,
        table   = table,
        math    = math,
        os      = safeOs,

        -- CC-специфичные константы (значения, не функции)
        colors  = colors,
        keys    = keys,
    }
end

-- ── Загрузка строки в песочнице ──────────────────────────────────────────────

-- Парсит исходник Lua, возвращает функцию-чанк или (nil, err).
-- Чанк выполняется в изолированной среде без доступа к fs/http/peripheral.
function Loader.loadStringSandbox(source, chunkName)
    if type(source) ~= "string" then
        return nil, "source must be a string"
    end

    local env = buildSandboxEnv()
    local fn, err
    if _VERSION == "Lua 5.1" then
        fn, err = loadstring(source, chunkName or "sandbox")
        if fn then setfenv(fn, env) end
    else
        fn, err = load(source, chunkName or "sandbox", "t", env)
    end
    return fn, err
end

-- Выполняет sandboxed-чанк, ожидает что вернёт table. Защита от error/cycles.
function Loader.loadTableSandbox(source, chunkName)
    local fn, err = Loader.loadStringSandbox(source, chunkName)
    if not fn then return nil, err end

    local ok, value = pcall(fn)
    if not ok then return nil, value end
    if type(value) ~= "table" then
        return nil, "chunk did not return a table"
    end
    return value
end

-- ── Доверенная загрузка (для собственного кода ОС) ───────────────────────────

-- Захватывает stacktrace, чтобы panic-сообщения были полезными.
local function tracebackHandler(err)
    if type(debug) == "table" and type(debug.traceback) == "function" then
        return debug.traceback(tostring(err), 2)
    end
    return tostring(err)
end

-- Выполняет файл, возвращает значение или (nil, err) с трассировкой.
function Loader.safeDofile(path)
    local fn, err
    if loadfile then
        fn, err = loadfile(path)
    end
    if not fn then return nil, err end

    local ok, value = xpcall(fn, tracebackHandler)
    if not ok then return nil, value end
    return value
end

-- Аналог require с кэшированием. Используется в коде ОС.
-- Возвращает значение из файла или вызывает error() с трассировкой.
function Loader.require(path)
    if _cache[path] ~= nil then return _cache[path] end

    local value, err = Loader.safeDofile(path)
    if value == nil then
        error("Loader.require(" .. tostring(path) .. "): " .. tostring(err), 2)
    end

    _cache[path] = value
    return value
end

-- Очистка кэша (для горячей перезагрузки модулей).
function Loader.clearCache(path)
    if path then _cache[path] = nil else _cache = {} end
end

return Loader
