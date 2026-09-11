-- Общий HTTP-клиент ОС. Выделен из updater.lua, чтобы апдейтер и магазин
-- приложений (store.lua) пользовались одной реализацией запроса и склейки URL.
--
-- ВАЖНО: http.get в CC:Tweaked блокирующий и съедает события. Вызывать только
-- из фоновых воркеров (ctx.spawn), никогда из draw/init.
local HttpFetch = {}

HttpFetch.DEFAULT_TIMEOUT = 10

function HttpFetch.available()
    return type(http) == "table" and type(http.get) == "function"
end

-- CC:Tweaked принимает таймаут только в табличной форме:
-- http.get({url = ..., timeout = ...}); позиционный 4-й аргумент игнорируется.
function HttpFetch.get(url, timeout)
    if not HttpFetch.available() then return nil, "HTTP API is disabled" end

    local ok, handle, err = pcall(http.get, {url = url, timeout = timeout or HttpFetch.DEFAULT_TIMEOUT})
    if not ok then
        -- Старая версия CC:Tweaked не принимает табличную форму — повторяем без неё.
        ok, handle, err = pcall(http.get, url)
        if not ok then return nil, "http.get crashed: " .. tostring(handle) end
    end
    if not handle then return nil, err or "http.get failed" end

    local data = handle.readAll()
    handle.close()
    return data
end

-- Склеивает базовый URL с относительным путём, схлопывая лишние слэши.
function HttpFetch.join(baseUrl, path)
    local cleanPath = string.gsub(tostring(path or ""), "^/", "")
    return string.gsub(tostring(baseUrl or ""), "/$", "") .. "/" .. cleanPath
end

return HttpFetch
