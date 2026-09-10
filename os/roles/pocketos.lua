local Updater = dofile("/os/lib/updater.lua")

local PocketRole = {}

local APPS_DIR = "/os/apps"
local REMOVED_APPS_FILE = "/data/apps_removed.db"
local DEFAULT_APPS = {"factory", "storage", "hub"}
local SYSTEM_APP_ORDER = {"files", "terminal", "apps", "settings", "logs", "os_update"}

local function copyConfig(base, overlay)
    local out = {}
    for k, v in pairs(base or {}) do out[k] = v end
    for k, v in pairs(overlay or {}) do out[k] = v end
    return out
end

local function ensureDir(path)
    if path and path ~= "" and not fs.exists(path) then fs.makeDir(path) end
end

local function loadApp(appId)
    local path = APPS_DIR .. "/" .. appId .. ".lua"
    if not fs.exists(path) then return nil, "missing " .. path end

    local ok, app = pcall(dofile, path)
    if not ok then return nil, app end
    if type(app) ~= "table" then return nil, "invalid app " .. path end
    return app
end

local function loadRemovedApps()
    if not fs.exists(REMOVED_APPS_FILE) then return {} end
    local handle = fs.open(REMOVED_APPS_FILE, "r")
    if not handle then return {} end
    local data = handle.readAll()
    handle.close()

    local env = {ipairs = ipairs, pairs = pairs, string = string, table = table}
    local fn
    if _VERSION == "Lua 5.1" then
        fn = loadstring(data, "apps_removed")
        if fn then setfenv(fn, env) end
    else
        fn = load(data, "apps_removed", "t", env)
    end
    if not fn then return {} end
    local ok, removed = pcall(fn)
    return ok and type(removed) == "table" and removed or {}
end

local function appendUnique(list, id, seen)
    if type(id) ~= "string" or id == "" or seen[id] then return end
    table.insert(list, id)
    seen[id] = true
end

local function discoverSystemApps(removed)
    local found = {}
    if not fs.exists(APPS_DIR) then return found end

    for _, file in ipairs(fs.list(APPS_DIR)) do
        if string.sub(file, -4) == ".lua" then
            local id = string.sub(file, 1, -5)
            local app = loadApp(id)
            if app and app.system == true and app.hidden ~= true and not removed[id] then
                found[id] = true
            end
        end
    end
    return found
end

local function discoverUserApps()
    -- Источник истины для установленного user-приложения — наличие файла в
    -- /os/apps (удаление аппа в Apps удаляет файл). НЕ фильтруем по
    -- /data/apps_removed.db: этот глобальный файл — легаси до многопользова-
    -- тельской системы, его больше никто не пишет (установка чистит per-user
    -- /data/users/<id>/apps_removed.db). Сверка с ним прятала переустановленные
    -- апы (snake/storage/rtc) после ребута, хотя их файлы лежат на диске.
    local found = {}
    if not fs.exists(APPS_DIR) then return found end

    for _, file in ipairs(fs.list(APPS_DIR)) do
        if string.sub(file, -4) == ".lua" then
            local id = string.sub(file, 1, -5)
            local app = loadApp(id)
            if app and app.system ~= true and app.hidden ~= true then
                table.insert(found, id)
            end
        end
    end
    table.sort(found)
    return found
end

local function appLaunchList(configured)
    local result, seen = {}, {}
    local removed = loadRemovedApps()
    -- Настроенные user-апы и автообнаруженные по файлам не фильтруем стале-
    -- глобальным removed (см. discoverUserApps). Он остаётся актуален только
    -- для системных апов, которые OTA может восстановить на диск.
    for _, id in ipairs(configured or DEFAULT_APPS) do
        appendUnique(result, id, seen)
    end

    for _, id in ipairs(discoverUserApps()) do
        appendUnique(result, id, seen)
    end

    local system = discoverSystemApps(removed)
    for _, id in ipairs(SYSTEM_APP_ORDER) do
        if system[id] then appendUnique(result, id, seen) end
        system[id] = nil
    end

    local rest = {}
    for id in pairs(system) do table.insert(rest, id) end
    table.sort(rest)
    for _, id in ipairs(rest) do appendUnique(result, id, seen) end

    return result
end

function PocketRole.run(ctx)
    ensureDir("/data")

    local cfg = copyConfig(ctx.computers.pocketosDefaults, ctx.computer.pocketos)
    local Connections = dofile("/os/lib/connections.lua")
    local configured, configErr = Connections.apply(cfg, ctx.manifest,
        Updater.readSource() or cfg.osSourceUrl)
    if not configured then error(configErr, 0) end
    if not cfg.userServerId then
        local FirstRun = dofile("/os/lib/first_run.lua")
        local ok, err = FirstRun.owner()
        if not ok then error("Owner setup failed: " .. tostring(err), 0) end
    end
    cfg.computerId = ctx.id
    cfg.computerLabel = ctx.computer.label
    -- Роль нужна апдейтеру: она решает, какой набор файлов манифеста качать.
    cfg.role = ctx.computer.role
    cfg.osRoot = "/os"
    cfg.dataRoot = "/data"
    cfg.osVersion = ctx.manifest and ctx.manifest.version

    if ctx.computer.updateMode == "startup" and (cfg.osSourceUrl or Updater.readSource()) then
        local ok, err = Updater.updateConfigured(ctx.manifest, cfg)
        if not ok then
            print("PocketOS update skipped: " .. tostring(err))
            -- Кидаем уведомление в Notify, чтобы оно появилось на dashboard
            -- сразу после старта оболочки.
            local okNotify, Notify = pcall(dofile, "/os/lib/notify.lua")
            if okNotify and type(Notify) == "table" then
                pcall(Notify.push, "Update failed", tostring(err),
                      {level = "warn", source = "updater"})
            end
            sleep(1)
        end
    end

    local PocketOS = dofile("/os/lib/pocketos/init.lua")
    local pos = PocketOS.create(cfg)
    for _, appId in ipairs(appLaunchList(ctx.computer.apps)) do
        local app, err = loadApp(appId)
        if app and app.hidden ~= true then
            pos:registerApp(app)
        elseif app and app.hidden == true then
            print("PocketOS app hidden: " .. tostring(appId))
        else
            print("PocketOS app skipped: " .. tostring(err))
        end
    end

    -- Фоновый сервис: принимает push-уведомления от других компьютеров
    pos:registerService({
        id = "push_notify",
        onEvent = function(svcCtx, event, p1, p2, p3)
            if event ~= "rednet_message" then return end
            if p3 ~= "pocket_notify" then return end
            if type(p2) ~= "table" or p2.type ~= "notify" then return end
            svcCtx.notify(
                p2.title or "Notification",
                p2.body,
                {level = p2.level or "info", source = p2.source or "remote"}
            )
        end,
    })

    pos:run()
end

return PocketRole
