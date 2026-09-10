local Loader = dofile("/os/lib/loader.lua")

local Registry = {}
Registry.HTTP_TIMEOUT = 10
Registry.BOOT_TIMEOUT = 4   -- ограниченное ожидание реестра на старте (сек)

local function hasHttp()
    return type(http) == "table" and type(http.get) == "function" and type(http.post) == "function"
end

local function trimSlash(url)
    return string.gsub(tostring(url or ""), "/$", "")
end

-- Парсим ответ реестра в песочнице — никакого fs/http изнутри Lua-данных.
local function loadLuaTable(source, chunkName)
    return Loader.loadTableSandbox(source, chunkName or "registry")
end

-- Асинхронный HTTP с ограниченным ожиданием. В отличие от http.get (который
-- блокирует до HTTP_TIMEOUT=10с), http.request не морозит загрузку: ждём
-- событие http_success/http_failure или таймер. Реестр на старте опционален —
-- по таймауту/ошибке/нажатию клавиши boot продолжает с локальным конфигом.
-- opts = { url, method = "GET"|"POST", body, headers, timeout, allowSkip }
local function awaitHttp(opts)
    if not hasHttp() then return nil, "HTTP API is disabled" end
    local url = opts.url
    local ok, err
    if opts.method == "POST" then
        ok, err = pcall(http.request, {url = url, method = "POST",
                                       body = opts.body, headers = opts.headers})
    else
        ok, err = pcall(http.request, url)
    end
    if not ok then return nil, "http.request crashed: " .. tostring(err) end

    -- Только один запрос в полёте на старте, поэтому матчим по типу события.
    local timer = os.startTimer(opts.timeout or Registry.BOOT_TIMEOUT)
    while true do
        local ev, p1, p2 = os.pullEvent()
        if ev == "http_success" then
            return p2                                  -- handle
        elseif ev == "http_failure" then
            return nil, tostring(p2 or "request failed")
        elseif ev == "timer" and p1 == timer then
            return nil, "timeout"
        elseif opts.allowSkip and (ev == "key" or ev == "char") then
            return nil, "skipped"
        end
    end
end

local function encodeJson(value)
    if textutils and textutils.serializeJSON then
        return textutils.serializeJSON(value)
    end
    error("JSON serialization is not available")
end

local function decodeJson(value)
    if textutils and textutils.unserializeJSON then
        return textutils.unserializeJSON(value)
    end
    return nil
end

function Registry.config(computers)
    local cfg = computers and computers.registry or {}
    return {
        url = cfg.url or (computers and computers.registryUrl),
        autoRegister = cfg.autoRegister ~= false,
        defaultRole = cfg.defaultRole or "pocketos",
    }
end

-- opts = { timeout, allowSkip } — опционально, для bounded-ожидания на старте.
function Registry.fetch(computers, opts)
    opts = opts or {}
    local cfg = Registry.config(computers)
    if not hasHttp() then return nil, "HTTP API is disabled" end
    if not cfg.url or cfg.url == "" then return nil, "registry URL is not configured" end

    local handle, err = awaitHttp({
        url       = trimSlash(cfg.url) .. "/api/computers",
        timeout   = opts.timeout,
        allowSkip = opts.allowSkip,
    })
    if not handle then return nil, err or "registry request failed" end

    local body = handle.readAll()
    handle.close()
    return loadLuaTable(body, "remote_registry")
end

function Registry.merge(computers, remote)
    if type(remote) ~= "table" then return computers end
    for id, cfg in pairs(remote) do
        if type(id) == "number" and type(cfg) == "table" then
            computers[id] = cfg
        end
    end
    return computers
end

-- opts = { timeout, allowSkip, role } — bounded-ожидание на старте плюс роль,
-- выбранная при установке (иначе машина регистрируется как defaultRole).
function Registry.register(computers, id, opts)
    opts = opts or {}
    local cfg = Registry.config(computers)
    if not cfg.autoRegister then return false, "auto registration is disabled" end
    if not hasHttp() then return false, "HTTP API is disabled" end
    if not cfg.url or cfg.url == "" then return false, "registry URL is not configured" end

    local payload = encodeJson({
        id = id,
        label = "Computer " .. tostring(id),
        role = opts.role or cfg.defaultRole,
    })

    local handle, err = awaitHttp({
        url       = trimSlash(cfg.url) .. "/api/register",
        method    = "POST",
        body      = payload,
        headers   = {["Content-Type"] = "application/json"},
        timeout   = opts.timeout,
        allowSkip = opts.allowSkip,
    })
    if not handle then return false, err or "registration request failed" end

    local body = handle.readAll()
    handle.close()

    local decoded = decodeJson(body)
    if type(decoded) == "table" and decoded.ok == true then
        return true, decoded
    end
    return false, body
end

return Registry
