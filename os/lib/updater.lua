local FsUtil    = dofile("/os/lib/fsutil.lua")
local Loader    = dofile("/os/lib/loader.lua")
local HttpFetch = dofile("/os/lib/httpfetch.lua")

local Updater = {}
Updater.SOURCE_FILE         = "/.mineboom_source"
Updater.LOCAL_MANIFEST_FILE = "/.mineboom_manifest"
Updater.REMOVED_APPS_FILE   = "/data/apps_removed.db"
Updater.STAGING_PREFIX      = "/.os_tmp"
Updater.HTTP_TIMEOUT        = 10

local CORE_APPS = {
    apps = true,
    logs = true,
    os_update = true,
    settings = true,
    terminal = true,
}

local function hasHttp()
    return HttpFetch.available()
end

local function fetch(url)
    return HttpFetch.get(url, Updater.HTTP_TIMEOUT)
end

-- Пути в манифесте абсолютные (/os/lib/foo.lua), а базовый URL уже указывает на
-- корень ОС — поэтому ведущий /os/ отбрасываем.
local function joinUrl(baseUrl, path)
    return HttpFetch.join(baseUrl, (string.gsub(path, "^/os/", "")))
end

local function loadRemovedApps()
    if not FsUtil.exists(Updater.REMOVED_APPS_FILE) then return {} end
    local data = FsUtil.readFile(Updater.REMOVED_APPS_FILE)
    if type(data) ~= "string" then return {} end
    local t = Loader.loadTableSandbox(data, "apps_removed")
    return type(t) == "table" and t or {}
end

local function removedAppId(path, removed)
    local id = string.match(path or "", "^/os/apps/([%w_-]+)%.lua$")
    if not id or CORE_APPS[id] then return nil end
    if removed and removed[id] then return id end
    return nil
end

function Updater.readSource()
    if not FsUtil.exists(Updater.SOURCE_FILE) then return nil end
    local source = FsUtil.readFile(Updater.SOURCE_FILE)
    if type(source) ~= "string" then return nil end
    source = string.gsub(source, "%s+$", "")
    if source == "" then return nil end
    return source
end

function Updater.writeSource(source)
    if not source or source == "" then return false, "source is empty" end
    return FsUtil.atomicWrite(Updater.SOURCE_FILE, source)
end

-- Какие файлы нужны машине с этой ролью: ядро + набор роли.
-- Манифест старого формата (без core/roles) отдаёт плоский список — так
-- обновление на старую версию ОС остаётся возможным.
function Updater.filesFor(manifest, role)
    if type(manifest) ~= "table" then return {} end
    if type(manifest.core) ~= "table" or type(manifest.roles) ~= "table" then
        return manifest.files or {}
    end

    local out, seen = {}, {}
    local function append(list)
        if type(list) ~= "table" then return end
        for _, path in ipairs(list) do
            if not seen[path] then
                seen[path] = true
                out[#out + 1] = path
            end
        end
    end

    append(manifest.core)

    local roleFiles = role and manifest.roles[role]
    if roleFiles then
        append(roleFiles)
    else
        -- Роль этому манифесту незнакома (или не передана): ставим всё, как
        -- раньше. Лучше лишние файлы, чем машина без нужного модуля.
        for _, name in ipairs(manifest.roleOrder or {}) do append(manifest.roles[name]) end
        append(manifest.files)
    end
    return out
end

function Updater.status(manifest, role)
    return {
        mode = "central",
        name = manifest.name,
        channel = manifest.channel,
        version = manifest.version,
        files = #Updater.filesFor(manifest, role),
        http = hasHttp(),
    }
end

function Updater.fetchManifest(baseUrl)
    if not baseUrl or baseUrl == "" then
        return nil, "baseUrl is not configured"
    end

    local data, err = fetch(joinUrl(baseUrl, "/os/manifest.lua"))
    if not data then return nil, err end
    return Loader.loadTableSandbox(data, "remote_manifest")
end

function Updater.compatible(manifest)
    local features = type(manifest) == "table" and manifest.features or {}
    if type(features) ~= "table" then features = {} end
    if fs.exists("/data/system/device.db") and not features.standalone then
        return false, "Release lacks standalone support"
    end
    if fs.exists("/data/system/connections.db") and not features.connections then
        return false, "Release lacks shared-account settings"
    end
    return true
end

local function clearStaging()
    if fs.exists(Updater.STAGING_PREFIX) then
        pcall(fs.delete, Updater.STAGING_PREFIX)
    end
end

local function stagingPath(target)
    -- /os/lib/foo.lua -> /.os_tmp/lib/foo.lua  (избегаем коллизий с реальной ОС)
    local rel = string.gsub(target, "^/os/?", "")
    return Updater.STAGING_PREFIX .. "/" .. rel
end

-- Атомарное обновление: сначала скачиваем всё в /.os_tmp/, проверяем, что все
-- файлы получены, затем переносим один за другим (каждый перенос сам атомарен).
-- onProgress(done, total, path) — опциональный колбэк, вызывается перед
-- скачиванием каждого файла (для прогресса в UI). Может быть nil.
function Updater.updateFromHttp(baseUrl, manifest, onProgress, role)
    if not baseUrl or baseUrl == "" then
        return false, "baseUrl is not configured"
    end
    local compatible, compatibilityErr = Updater.compatible(manifest)
    if not compatible then return false, compatibilityErr end

    clearStaging()

    local files = Updater.filesFor(manifest, role)
    local total = #files
    local removed = loadRemovedApps()

    -- Фаза 1: скачать всё в staging
    for idx, path in ipairs(files) do
        if onProgress then pcall(onProgress, idx, total, path) end
        if removedAppId(path, removed) then
            if fs.exists(path) then pcall(fs.delete, path) end
        else
            local data, err = fetch(joinUrl(baseUrl, path))
            if not data then
                clearStaging()
                return false, "fetch " .. path .. ": " .. tostring(err)
            end

            local ok, writeErr = FsUtil.atomicWrite(stagingPath(path), data)
            if not ok then
                clearStaging()
                return false, "stage " .. path .. ": " .. tostring(writeErr)
            end
        end
    end

    -- Фаза 2: перенос staged -> live. Каждый отдельный перенос атомарен
    -- (FsUtil.atomicWrite пишет в .tmp + move). Сравниваем содержимое, чтобы
    -- не перезаписывать одинаковые файлы и не порождать лишний flicker.
    local updated = 0
    for _, path in ipairs(files) do
        if not removedAppId(path, removed) then
            local newData = FsUtil.readFile(stagingPath(path))
            if newData == nil then
                clearStaging()
                return false, "missing staged file " .. path
            end
            local current = FsUtil.readFile(path)
            if current ~= newData then
                local ok, writeErr = FsUtil.atomicWrite(path, newData)
                if not ok then
                    clearStaging()
                    return false, "install " .. path .. ": " .. tostring(writeErr)
                end
                updated = updated + 1
            end
        end
    end

    clearStaging()

    FsUtil.atomicWrite(Updater.LOCAL_MANIFEST_FILE, textutils.serialize({
        name      = manifest.name,
        channel   = manifest.channel,
        version   = manifest.version,
        files     = total,
        updatedAt = os.epoch and math.floor(os.epoch("utc") / 1000) or math.floor(os.clock()),
    }))

    if updated == 0 then
        return true, "already up to date"
    end
    return true, "updated " .. updated .. " of " .. total .. " files"
end

function Updater.updateConfigured(manifest, cfg, onProgress)
    local source = Updater.readSource() or (cfg and cfg.osSourceUrl)
    if not source then return false, "OS source is not configured" end

    local remoteManifest, err = Updater.fetchManifest(source)
    if not remoteManifest then
        return false, "manifest: " .. tostring(err)
    end

    return Updater.updateFromHttp(source, remoteManifest, onProgress, cfg and cfg.role)
end

return Updater
