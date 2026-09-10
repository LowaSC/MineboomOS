-- Клиент магазина приложений: выбор источника и HTTP-загрузка каталога/файлов.
--
-- Источник хранится строкой в /.appstore_source (по образцу /.mineboom_source
-- у апдейтера ОС) и бывает трёх видов:
--   "rednet:19"                            -- игровой сервер магазина по Rednet
--   "http://server.example/apps"            -- HTTP catalog server
--   "http://<внешний-хост>/..."            -- интернет, механизм идентичен загрузке ОС
--
-- Rednet-транспорт здесь намеренно НЕ реализован: он событийный (ctx.send +
-- rednet_message), и синхронный rednet.receive сломал бы цикл событий PocketOS.
-- Приложение Apps ветвится само по Store.parse(source).kind.
local Loader    = dofile("/os/lib/loader.lua")
local FsUtil    = dofile("/os/lib/fsutil.lua")
local HttpFetch = dofile("/os/lib/httpfetch.lua")

local Store = {}
Store.SOURCE_FILE  = "/.appstore_source"
Store.HTTP_TIMEOUT = 10

-- index.gen.lua пишется ролью app_server и содержит checksum'ы; index.lua —
-- исходный каталог, который правится руками (тогда сравниваем по version).
Store.INDEX_FILES = {"apps/index.gen.lua", "apps/index.lua"}

-- ── Источник ─────────────────────────────────────────────────────────────────

function Store.readSource()
    if not FsUtil.exists(Store.SOURCE_FILE) then return nil end
    local source = FsUtil.readFile(Store.SOURCE_FILE)
    if type(source) ~= "string" then return nil end
    source = string.gsub(source, "%s+$", "")
    if source == "" then return nil end
    return source
end

function Store.defaultSource(cfg)
    local saved = Store.readSource()
    if saved then return saved end
    if cfg and cfg.storeComputer then return Store.sourceForMode("rednet", cfg) end
    return Store.sourceForMode("internet", cfg)
end

function Store.writeSource(source)
    if not source or source == "" then return false, "source is empty" end
    return FsUtil.atomicWrite(Store.SOURCE_FILE, source)
end

-- "rednet:19" -> {kind="rednet", id=19};  "http://..." -> {kind="http", url=...}
function Store.parse(source)
    if type(source) ~= "string" or source == "" then
        return nil, "store source is empty"
    end
    local id = string.match(source, "^rednet:(%d+)$")
    if id then return {kind = "rednet", id = tonumber(id)} end
    if source == "rednet" then return {kind = "rednet"} end
    if string.find(source, "^https?://") then
        return {kind = "http", url = source}
    end
    return nil, "unsupported store source: " .. source
end

-- Подставляет номер сервера магазина в URL-шаблон. Благодаря {id} номер живёт
-- ровно в одном месте конфига (storeComputer) — в новом мире, где у компьютеров
-- другие ID, править нужно одно число, а не число и URL.
function Store.expandUrl(url, cfg)
    if type(url) ~= "string" or url == "" then return nil, "URL is empty" end
    if not string.find(url, "{id}", 1, true) then return url end

    local id = cfg and cfg.storeComputer
    if not id then return nil, "Store computer is not configured" end
    return (string.gsub(url, "{id}", tostring(id)))
end

-- Режимы для UI-переключателя: "rednet" | "local" | "internet".
function Store.sourceForMode(mode, cfg)
    if mode == "rednet" then
        local id = cfg and cfg.storeComputer
        if id then return "rednet:" .. tostring(id) end
        return nil, "Store computer is not configured"
    elseif mode == "local" then
        local url = cfg and cfg.storeSourceUrl
        if not url or url == "" then return nil, "Local store URL is not configured" end
        return Store.expandUrl(url, cfg)
    elseif mode == "internet" then
        local url = cfg and cfg.storeSourceUrlInternet
        if not url or url == "" then return nil, "Internet store URL is not configured" end
        return Store.expandUrl(url, cfg)
    end
    return nil, "Unknown store mode: " .. tostring(mode)
end

-- Определяет режим по строке источника (аналог detectChannel в os_update).
function Store.modeOf(source, cfg)
    if not source or source == "" then return "rednet" end
    if source == "rednet" or string.find(source, "^rednet:") then return "rednet" end

    -- Сравниваем с раскрытыми шаблонами: в конфиге лежит .../computer/{id},
    -- а в /.appstore_source — уже подставленный номер.
    local internet = Store.expandUrl(cfg and cfg.storeSourceUrlInternet, cfg)
    if internet and source == internet then return "internet" end
    local localUrl = Store.expandUrl(cfg and cfg.storeSourceUrl, cfg)
    if localUrl and source == localUrl then return "local" end

    -- Незнакомый адрес: локальным считаем только петлевой.
    if string.find(source, "^https?://127%.0%.0%.1") or string.find(source, "^https?://localhost") then
        return "local"
    end
    return "internet"
end

function Store.httpAvailable()
    return HttpFetch.available()
end

-- ── Контрольные суммы ────────────────────────────────────────────────────────

-- Тот же алгоритм, что у сервера магазина: индекс и клиент должны считать
-- одинаково, иначе установленное приложение вечно висит в статусе UPD.
function Store.checksum(s)
    if type(s) ~= "string" then return nil end
    local h = #s
    for i = 1, #s do
        h = (h * 31 + string.byte(s, i)) % 0x1000000
    end
    return h
end

function Store.fileChecksum(path)
    if not path or not fs.exists(path) then return nil end
    local data = FsUtil.readFile(path)
    if type(data) ~= "string" then return nil end
    return Store.checksum(data)
end

-- ── HTTP-загрузка ────────────────────────────────────────────────────────────

local function normalizeCatalog(catalog)
    local out = {}
    for _, entry in ipairs(catalog or {}) do
        if type(entry) == "table" and type(entry.id) == "string" then
            table.insert(out, entry)
        end
    end
    return out
end

-- Каталог по HTTP. Сначала index.gen.lua (с checksum'ами), затем index.lua.
function Store.fetchIndex(parsed)
    if not parsed or parsed.kind ~= "http" then
        return nil, "HTTP source is required"
    end
    if not HttpFetch.available() then
        return nil, "HTTP is not available on this computer"
    end

    local lastErr
    for _, name in ipairs(Store.INDEX_FILES) do
        local data, err = HttpFetch.get(HttpFetch.join(parsed.url, name), Store.HTTP_TIMEOUT)
        if data and data ~= "" then
            local catalog, perr = Loader.loadTableSandbox(data, "store_index")
            if catalog then return normalizeCatalog(catalog) end
            lastErr = perr
        else
            lastErr = err or "empty response"
        end
    end
    return nil, tostring(lastErr or "index not found")
end

-- Код приложения по HTTP. Возвращает (code, version) или (nil, err).
-- entry — запись каталога: нужны её file/devFile, которых нет в Rednet-индексе.
function Store.fetchApp(parsed, entry, channel)
    if not parsed or parsed.kind ~= "http" then
        return nil, "HTTP source is required"
    end
    if type(entry) ~= "table" or type(entry.id) ~= "string" then
        return nil, "catalog entry is required"
    end

    local file    = entry.file
    local version = entry.version
    if channel == "dev" and entry.devFile and entry.devFile ~= "" then
        file    = entry.devFile
        version = entry.devVersion or entry.version
    end
    -- Индекс без путей (например, отданный Rednet-сервером) — берём соглашение.
    if not file or file == "" then file = "apps/" .. entry.id .. ".lua" end

    local data, err = HttpFetch.get(HttpFetch.join(parsed.url, file), Store.HTTP_TIMEOUT)
    if not data then return nil, tostring(err) end
    if data == "" then return nil, "empty file for " .. entry.id end
    return data, version
end

return Store
