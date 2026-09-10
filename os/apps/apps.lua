local Loader    = dofile("/os/lib/loader.lua")
local FsUtil    = dofile("/os/lib/fsutil.lua")
local AppMeta   = dofile("/os/lib/appmeta.lua")
local Scrollbar = dofile("/os/lib/scrollbar.lua")
local Users     = dofile("/os/lib/users.lua")
local Store     = dofile("/os/lib/store.lua")

local M = {}
M.id        = "apps"
M.name      = "Apps"
M.icon      = "Ap"
M.iconBg    = colors.lime
M.iconFg    = colors.black
M.version   = 10
M.system    = true
M.category  = "system"
M.protocols = {"pocket_store"}

local SYSTEM_IDS = {files = true, settings = true, os_update = true, apps = true, logs = true, admin = true}
local function dataPath(ctx, name)
    local root = (ctx and ctx.dataRoot) or "/data"
    return root .. "/" .. name
end
local APPS_DIR   = "/os/apps"
-- Шапка: вкладки + поиск + separator. Во вкладке Store между поиском и
-- separator'ом добавляется строка выбора источника, поэтому высота зависит от
-- режима — вкладка Manage не теряет строку списка на маленьких экранах.
local HDR_BASE   = 3
local SOURCE_ROW = 3
local SOURCE_BUTTONS = {
    {mode = "rednet",   label = " Rednet ", w = 8},
    {mode = "local",    label = " Local ",  w = 7},
    {mode = "internet", label = " Web ",    w = 5},
}

local function hdrRows(st)
    if st.mode == "store" then return HDR_BASE + 1 end
    return HDR_BASE
end
local HIDDEN_CATALOG_IDS = {}
local CATEGORY_LABEL = {
    automation = "Automation",
    network    = "Network",
    games      = "Games",
    system     = "System",
    other      = "Other",
}
local CATEGORY_ORDER = {"automation", "network", "games", "system", "other"}
local CATEGORY_FALLBACK = {
    factory = "automation",
    storage = "automation",
    rtc = "automation",
    hub = "network",
    apps = "system",
    admin = "system",
    files = "system",
    settings = "system",
    logs = "system",
    os_update = "system",
    terminal = "system",
    minesweeper = "games",
    snake = "games",
    ["2048"] = "games",
}
-- ── helpers ──────────────────────────────────────────────────────────────────

local function clamp(v, lo, hi) return math.max(lo, math.min(hi, v)) end

local function padR(s, n)
    s = tostring(s or "")
    if #s >= n then return string.sub(s, 1, n) end
    return s .. string.rep(" ", n - #s)
end

local function clip(s, n)
    s = tostring(s or "")
    if n <= 0 then return "" end
    if #s > n then return string.sub(s, 1, n) end
    return s
end

local function lower(s)
    return string.lower(tostring(s or ""))
end

local function iconText(app)
    local s = app.icon or string.sub(app.name or app.id or "?", 1, 2)
    s = tostring(s)
    if #s < 2 then s = s .. " " end
    return string.sub(s, 1, 2)
end

local function appCategory(app)
    local cat = app and app.category or nil
    if not cat or not CATEGORY_LABEL[cat] then cat = CATEGORY_FALLBACK[app and app.id] end
    if not cat or not CATEGORY_LABEL[cat] then cat = "other" end
    return cat
end

local function matchesSearch(app, query)
    local q = lower(query)
    if q == "" then return true end
    if string.find(lower(app.name), q, 1, true) then return true end
    if string.find(lower(app.id), q, 1, true) then return true end
    if string.find(lower(app.description), q, 1, true) then return true end
    if string.find(lower(appCategory(app)), q, 1, true) then return true end
    return false
end

local function loadMeta(ctx)
    local f = dataPath(ctx, "apps_meta.db")
    if not fs.exists(f) then return {} end
    local data = FsUtil.readFile(f)
    if type(data) ~= "string" then return {} end
    local t = Loader.loadTableSandbox(data, "apps_meta")
    return type(t) == "table" and t or {}
end

local function saveMeta(ctx, meta)
    FsUtil.ensureDir(ctx.dataRoot or "/data")
    FsUtil.atomicWrite(dataPath(ctx, "apps_meta.db"), "return " .. textutils.serialize(meta))
end

local function loadRemoved(ctx)
    local f = dataPath(ctx, "apps_removed.db")
    if not fs.exists(f) then return {} end
    local data = FsUtil.readFile(f)
    if type(data) ~= "string" then return {} end
    local t = Loader.loadTableSandbox(data, "apps_removed")
    return type(t) == "table" and t or {}
end

local function saveRemoved(ctx, removed)
    FsUtil.ensureDir(ctx.dataRoot or "/data")
    FsUtil.atomicWrite(dataPath(ctx, "apps_removed.db"), "return " .. textutils.serialize(removed))
end

local function loadChannelOverrides(ctx)
    local f = dataPath(ctx, "app_channels.db")
    if not fs.exists(f) then return {} end
    local data = FsUtil.readFile(f)
    if type(data) ~= "string" then return {} end
    local t = Loader.loadTableSandbox(data, "app_channels")
    return type(t) == "table" and t or {}
end

local function saveChannelOverrides(ctx, t)
    FsUtil.ensureDir(ctx.dataRoot or "/data")
    FsUtil.atomicWrite(dataPath(ctx, "app_channels.db"), "return " .. textutils.serialize(t))
end

local function appEffectiveChannel(id, overrides, globalCh)
    return overrides[id] or globalCh or "stable"
end

-- Есть ли у приложения dev-версия. Rednet-индекс отдаёт devChecksum, HTTP-индекс
-- (index.lua правится руками) — только devFile/devVersion.
local function hasDevChannel(app)
    if app.devChecksum ~= nil then return true end
    if app.devFile and app.devFile ~= "" then return true end
    return app.devVersion ~= nil
end

local function appPath(id)
    return APPS_DIR .. "/" .. id .. ".lua"
end

local function isInstalled(id)
    return fs.exists(appPath(id))
end

-- Алгоритм общий с сервером магазина — живёт в store.lua.
local function fileChecksum(path)
    return Store.fileChecksum(path)
end

local function readAppMeta(path)
    return AppMeta.read(path)
end

local function scanInstalled(ctx)
    local result = {}
    local removed = loadRemoved(ctx)
    if not fs.exists(APPS_DIR) then return result end
    for _, fname in ipairs(fs.list(APPS_DIR)) do
        if string.sub(fname, -4) == ".lua" then
            local id   = string.sub(fname, 1, -5)
            local path = APPS_DIR .. "/" .. fname
            local def  = readAppMeta(path)
            if removed[id] then
                -- A previous delete can survive a one-time restore by an older
                -- updater; keep the app hidden until it is installed again.
            elseif def and def.hidden == true then
                -- Legacy/compatibility app: keep the file, but do not expose it
                -- in the manager or desktop.
            else
                local name = (def and def.name) or id
                local sys  = SYSTEM_IDS[id] or (def and def.system == true) or false
                local ver  = def and def.version
                local cat  = def and def.category
                if cat and not CATEGORY_LABEL[cat] then cat = nil end
                if not cat and sys then cat = "system" end
                table.insert(result, {
                    id = id, name = name, system = sys, path = path, version = ver,
                    adminOnly = (def and def.adminOnly == true) or false,
                    category = cat,
                    icon = def and def.icon,
                    iconBg = def and def.iconBg,
                    iconFg = def and def.iconFg,
                })
            end
        end
    end
    -- Не-системные сначала (по алфавиту), системные последними (по алфавиту)
    table.sort(result, function(a, b)
        if a.system ~= b.system then return not a.system end
        return (a.name or a.id) < (b.name or b.id)
    end)
    return result
end

local function userCanSeeApp(ctx, appId)
    local u = ctx.currentUser
    if not u then return true end
    if u.isAdmin or u.allowedApps == nil then return true end
    for _, id in ipairs(u.allowedApps) do
        if id == appId then return true end
    end
    return false
end

local function displayInstalled(installed, showSystem, ctx)
    local isAdmin = ctx.currentUser and ctx.currentUser.isAdmin
    local result = {}
    for _, app in ipairs(installed or {}) do
        -- adminOnly-приложения (Terminal) видит только администратор.
        local visible = showSystem or not app.system
        if app.adminOnly and not isAdmin then visible = false end
        if visible and userCanSeeApp(ctx, app.id) then
            table.insert(result, app)
        end
    end
    return result
end

local function buildRows(apps, query, expanded)
    local buckets = {}
    local q = query or ""
    local searching = q ~= ""
    for _, app in ipairs(apps or {}) do
        if matchesSearch(app, q) then
            local cat = appCategory(app)
            buckets[cat] = buckets[cat] or {}
            table.insert(buckets[cat], app)
        end
    end
    for _, list in pairs(buckets) do
        table.sort(list, function(a, b)
            return (a.name or a.id) < (b.name or b.id)
        end)
    end
    local rows = {}
    for _, cat in ipairs(CATEGORY_ORDER) do
        local list = buckets[cat]
        if list and #list > 0 then
            local open = searching or expanded[cat] == true
            table.insert(rows, {
                type = "header",
                cat = cat,
                text = CATEGORY_LABEL[cat],
                count = #list,
                expanded = open,
            })
            if open then
                for _, app in ipairs(list) do
                    table.insert(rows, {type = "app", app = app})
                end
            end
        end
    end
    return rows
end

local function appStatus(id, app, channel, meta, removed, localChecksums)
    if removed and removed[id] then return "GET" end
    if not isInstalled(id) then return "GET" end
    local cs = (channel == "dev" and app.devChecksum ~= nil) and app.devChecksum or app.checksum
    if cs ~= nil then
        local lcs = localChecksums and localChecksums[id]
        return lcs == cs and "INST" or "UPD"
    end
    local catalogVer = (channel == "dev" and app.devVersion) or app.version
    local saved = meta[id]
    if saved and tostring(saved) == tostring(catalogVer) then return "INST" end
    return "UPD"
end

local function deleteInstalledApp(st, item)
    if not item or not item.path then return false, "No app selected" end
    if item.system then return false, (item.name or item.id) .. ": system app" end

    if fs.exists(item.path) then
        local ok, err = pcall(fs.delete, item.path)
        if not ok then return false, "Delete failed: " .. tostring(err) end
    end

    if fs.exists(item.path) then
        return false, "File still exists: " .. tostring(item.path)
    end

    st.meta[item.id] = nil
    saveMeta(st.ctx, st.meta)
    st.removed[item.id] = true
    saveRemoved(st.ctx, st.removed)
    os.queueEvent("pocketos_event", "unregister_app", item.id)
    return true, "Removed: " .. (item.name or item.id)
end

local function onCatalogReceived(st, apps)
    st.catalog = {}
    for _, app in ipairs(apps) do
        if app and not HIDDEN_CATALOG_IDS[app.id] and userCanSeeApp(st.ctx, app.id) then
            table.insert(st.catalog, app)
        end
    end
    st.localChecksums = {}
    for _, app in ipairs(st.catalog) do
        if app.checksum ~= nil or app.devChecksum ~= nil then
            st.localChecksums[app.id] = fileChecksum(appPath(app.id))
        end
    end
    local installed = 0
    local updates = 0
    for _, app in ipairs(st.catalog) do
        local ch = appEffectiveChannel(app.id, st.channelOverrides, st.globalChannel)
        local s = appStatus(app.id, app, ch, st.meta, st.removed, st.localChecksums)
        if s == "UPD" then updates = updates + 1 end
        if s ~= "GET" then installed = installed + 1 end
    end
    st.storeStatus = #st.catalog .. " in store, " .. installed .. " installed"
    if updates > 0 then
        st.storeStatus = st.storeStatus .. ", " .. updates .. " update(s)"
    end
end

-- ── Источник каталога ────────────────────────────────────────────────────────

local function isHttpSource(st)
    return st.parsedSource ~= nil and st.parsedSource.kind == "http"
end

local function rednetTarget(st)
    if st.parsedSource and st.parsedSource.kind == "rednet" and st.parsedSource.id then
        return st.parsedSource.id
    end
    return st.storeComputer
end

-- HTTP блокирует и съедает события, поэтому только через фонового воркера
-- (ctx.spawn): часы в таскбаре продолжают идти, клики не теряются.
-- ctx.spawn логирует падение воркера, но не знает про st.busy — без pcall
-- упавший запрос залипил бы вкладку Store в "занято" до перезапуска апва.
local function runStoreWorker(st, body)
    local ctx = st.ctx
    st.busy = true
    ctx.spawn(function()
        local ok, err = pcall(body)
        if not ok then
            st.storeStatus = "Store error: " .. tostring(err)
        end
        st.busy = false
        ctx.refresh()
    end, "app_store")
end

local function requestCatalogHttp(st)
    if st.busy then return end
    local parsed = st.parsedSource
    st.storeStatus = "Loading catalog..."
    runStoreWorker(st, function()
        local catalog, err = Store.fetchIndex(parsed)
        if catalog then
            onCatalogReceived(st, catalog)
        else
            st.catalog = {}
            st.storeStatus = "Store error: " .. tostring(err)
        end
    end)
end

local function requestCatalog(st)
    if isHttpSource(st) then
        requestCatalogHttp(st)
        return
    end
    local target = rednetTarget(st)
    if not target then
        st.storeStatus = "Store computer is not configured"
        return
    end
    st.ctx.send(target, {type = "store_request_index"}, st.storeProtocol)
    st.storeStatus = "Checking store..."
end

local function setSourceMode(st, mode)
    if mode == st.sourceMode then return end

    local source, err = Store.sourceForMode(mode, st.ctx.config)
    if not source then
        st.storeStatus = tostring(err)
        return
    end
    local parsed, perr = Store.parse(source)
    if not parsed then
        st.storeStatus = tostring(perr)
        return
    end
    if parsed.kind == "http" and not Store.httpAvailable() then
        st.storeStatus = "HTTP is not available on this computer"
        return
    end

    Store.writeSource(source)
    st.source       = source
    st.sourceMode   = mode
    st.parsedSource = parsed
    st.catalog      = {}
    st.storeScroll  = 0
    requestCatalog(st)
end

local function findChannelVersion(catalog, id, channel)
    for _, app in ipairs(catalog) do
        if app.id == id then
            if channel == "dev" and app.devVersion then return app.devVersion end
            return app.version
        end
    end
    return nil
end

local function onAppReceived(st, msg)
    if not Users.can(st.ctx.currentUser, "installApps") then
        st.storeStatus = "No permission to install apps"
        return
    end
    local id   = msg.id
    local code = msg.code
    if type(code) ~= "string" or #code == 0 then
        st.storeStatus = "Error: " .. (msg.error or ("empty code for " .. id))
        return
    end

    -- Базовая sanity-проверка: загружаем код в песочнице, чтобы хотя бы
    -- синтаксис был валидным до записи на диск.
    local fn, syntaxErr = Loader.loadStringSandbox(code, "store/" .. id)
    if not fn then
        st.storeStatus = "Error: bad code for " .. id .. ": " .. tostring(syntaxErr)
        return
    end

    local ok, writeErr = FsUtil.atomicWrite(appPath(id), code)
    if not ok then
        st.storeStatus = "Error writing " .. id .. ": " .. tostring(writeErr)
        return
    end

    local ch  = (st.pendingDownloads and st.pendingDownloads[id]) or st.globalChannel or "stable"
    local ver = (st.pendingUpdates and st.pendingUpdates[id])
             or findChannelVersion(st.catalog, id, ch)
    if ver then
        st.meta[id] = ver
        saveMeta(st.ctx, st.meta)
    end
    if st.pendingDownloads then st.pendingDownloads[id] = nil end
    if st.localChecksums then
        st.localChecksums[id] = fileChecksum(appPath(id))
    end
    if st.removed[id] then
        st.removed[id] = nil
        saveRemoved(st.ctx, st.removed)
    end

    os.queueEvent("pocketos_event", "register_app", appPath(id))

    if st.pendingUpdates and st.pendingUpdates[id] then
        st.pendingUpdates[id] = nil
        table.insert(st.updatedNames, msg.name or id)
        local remaining = 0
        for _ in pairs(st.pendingUpdates) do remaining = remaining + 1 end
        if remaining == 0 then
            st.storeStatus = "Updated: " .. table.concat(st.updatedNames, ", ")
            st.pendingUpdates = {}
            st.updatedNames   = {}
        end
    else
        st.storeStatus = "Installed: " .. (msg.name or id)
    end
end

-- Загрузка приложения по HTTP — тоже в фоновом воркере (см. requestCatalogHttp).
local function downloadHttp(st, app, channel)
    if st.busy then
        st.storeStatus = "Store is busy, try again"
        return
    end
    local parsed = st.parsedSource
    st.pendingDownloads[app.id] = channel
    st.storeStatus = "Downloading " .. (app.name or app.id) .. " [" .. channel .. "]..."
    runStoreWorker(st, function()
        local code, verOrErr = Store.fetchApp(parsed, app, channel)
        if code then
            onAppReceived(st, {
                id      = app.id,
                name    = app.name,
                code    = code,
                version = verOrErr,
                channel = channel,
            })
        else
            st.pendingDownloads[app.id] = nil
            st.storeStatus = "Error: " .. tostring(verOrErr)
        end
    end)
end

-- ── lifecycle ─────────────────────────────────────────────────────────────────

function M.init(win, ctx)
    local cfg = ctx.config or {}
    -- Сохранённый выбор пользователя важнее конфига; по умолчанию — Rednet,
    -- то есть поведение до появления HTTP-транспорта.
    local source = Store.defaultSource(cfg)
    local parsed = nil
    if source then parsed = Store.parse(source) end

    local st = {
        win           = win,
        ctx           = ctx,
        storeComputer = cfg.storeComputer,
        storeProtocol = cfg.storeProtocol,
        source        = source,
        sourceMode    = Store.modeOf(source, cfg),
        parsedSource  = parsed,
        busy          = false,
        mode          = "store",
        catalog       = {},
        storeScroll   = 0,
        storeQuery    = "",
        storeExpanded = {automation = true, games = true, network = true},
        storeStatus   = "Connecting...",
        refreshTimer  = os.startTimer(30),
        pendingUpdates = {},
        updatedNames  = {},
        globalChannel    = cfg.channel or "stable",
        channelOverrides = loadChannelOverrides(ctx),
        pendingDownloads = {},
        meta          = loadMeta(ctx),
        removed       = loadRemoved(ctx),
        localChecksums = {},
        installed     = {},
        manageScroll  = 0,
        manageQuery   = "",
        manageExpanded = {automation = true, games = true},
        manageStatus  = "",
        manageConfirm = 0,
        showSystem    = ctx.currentUser and ctx.currentUser.isAdmin or false,
        sb            = Scrollbar.create({
            thumbBg = colors.lime,
            thumbFg = colors.black,
        }),
    }
    -- A timer defers even the first worker until after app init has returned.
    st.initialTimer = os.startTimer(0)
    return st
end

-- ── drawing ───────────────────────────────────────────────────────────────────

local TAB_STORE_W  = 8   -- " Store  "
local TAB_MANAGE_W = 8   -- "Manage "
local SYS_BTN_W    = 6   -- " SYS  "

local function drawTabs(win, W, mode, showSystem)
    win.setCursorPos(1, 1)
    win.setBackgroundColor(mode == "store" and colors.lime or colors.gray)
    win.setTextColor(mode == "store" and colors.black or colors.lightGray)
    win.write(" Store  ")
    win.setBackgroundColor(mode == "manage" and colors.lime or colors.gray)
    win.setTextColor(mode == "manage" and colors.black or colors.lightGray)
    win.write("Manage  ")
    local fill = W - TAB_STORE_W - TAB_MANAGE_W - SYS_BTN_W
    win.setBackgroundColor(colors.black)
    win.setTextColor(colors.black)
    if fill > 0 then win.write(string.rep(" ", fill)) end
    if mode == "manage" then
        win.setBackgroundColor(showSystem and colors.cyan or colors.gray)
        win.setTextColor(showSystem and colors.black or colors.lightGray)
    else
        win.setBackgroundColor(colors.black)
        win.setTextColor(colors.black)
    end
    win.write(" SYS  ")
end

local function drawSearch(win, W, query)
    win.setCursorPos(1, 2)
    win.setBackgroundColor(colors.lightGray)
    win.setTextColor(colors.black)
    win.write(" /")
    win.write(padR(clip(query or "", W - 4), W - 4))
    win.setBackgroundColor(colors.red)
    win.setTextColor(colors.white)
    win.write(" x")
end

-- Строка выбора источника: Rednet (игровой сервер) / Local (HTTP) / Web (HTTP).
local function drawSourceBar(win, W, st)
    win.setCursorPos(1, SOURCE_ROW)
    local x = 1
    for _, btn in ipairs(SOURCE_BUTTONS) do
        if x + btn.w - 1 <= W then
            local active = (st.sourceMode == btn.mode)
            win.setBackgroundColor(active and colors.cyan or colors.gray)
            win.setTextColor(active and colors.black or colors.lightGray)
            win.write(btn.label)
            x = x + btn.w
        end
    end
    win.setBackgroundColor(colors.black)
    win.setTextColor(colors.gray)
    if x <= W then
        local rest = W - x + 1
        local hint = st.busy and "..." or ""
        win.write(clip(hint, rest) .. string.rep(" ", math.max(0, rest - #hint)))
    end
end

local function drawHeader(win, y, row, W)
    win.setCursorPos(1, y)
    win.setBackgroundColor(colors.gray)
    win.setTextColor(colors.white)
    local arrow = row.expanded and "v" or ">"
    local left = " " .. arrow .. " " .. row.text
    local count = "(" .. tostring(row.count) .. ")"
    win.write(padR(clip(left, W - #count - 2), W - #count - 2))
    win.setTextColor(colors.lightGray)
    win.write(count .. " ")
end

local function drawStoreApp(win, y, app, W, st)
    local contentW = W - 1
    local hasDev = hasDevChannel(app)
    local ch = appEffectiveChannel(app.id, st.channelOverrides, st.globalChannel)
    local s = appStatus(app.id, app, ch, st.meta, st.removed, st.localChecksums)
    local badge, badgeFg
    if s == "INST" then badge, badgeFg = " INST ", colors.lime
    elseif s == "UPD" then badge, badgeFg = " UPD  ", colors.yellow
    else badge, badgeFg = " GET  ", colors.cyan end
    local iconBg = app.iconBg or colors.lime
    local iconFg = app.iconFg or colors.black
    local chW   = hasDev and 3 or 0
    local nameW = math.max(1, contentW - 5 - chW - #badge)

    win.setCursorPos(1, y)
    win.setBackgroundColor(iconBg)
    win.setTextColor(iconFg)
    win.write(" " .. iconText(app) .. "  ")
    win.setBackgroundColor(colors.black)
    win.setTextColor(colors.white)
    win.write(padR(" " .. (app.name or app.id), nameW))
    if hasDev then
        win.setBackgroundColor(ch == "dev" and colors.yellow or colors.gray)
        win.setTextColor(ch == "dev" and colors.black or colors.lightGray)
        win.write(ch == "dev" and " D " or " S ")
    end
    win.setBackgroundColor(colors.black)
    win.setTextColor(badgeFg)
    win.write(badge)
end

local function drawManageApp(win, y, item, W, st, idx)
    local contentW = W - 1
    local conf = st.manageConfirm == idx
    local badge, badgeFg
    if item.system then badge, badgeFg = " SYS  ", colors.gray
    elseif conf then badge, badgeFg = " DEL  ", colors.white
    else badge, badgeFg = " DEL  ", colors.red end
    local iconBg = conf and colors.red or (item.iconBg or (item.system and colors.gray or colors.lime))
    local iconFg = item.iconFg or colors.black
    local nameW = math.max(1, contentW - 5 - #badge)

    win.setCursorPos(1, y)
    win.setBackgroundColor(iconBg)
    win.setTextColor(iconFg)
    win.write(" " .. iconText(item) .. "  ")
    win.setBackgroundColor(conf and colors.red or colors.black)
    win.setTextColor(colors.white)
    win.write(padR(" " .. (item.name or item.id), nameW))
    win.setTextColor(badgeFg)
    win.write(badge)
end

local function currentRows(st)
    if st.mode == "store" then
        return buildRows(st.catalog, st.storeQuery, st.storeExpanded)
    end
    return buildRows(displayInstalled(st.installed, st.showSystem, st.ctx), st.manageQuery, st.manageExpanded)
end

function M.draw(st, win)
    st.win = win
    local W, H = win.getSize()
    win.setBackgroundColor(colors.black)
    win.clear()

    local contentW = W - 1
    local query = (st.mode == "store") and st.storeQuery or st.manageQuery
    local scroll = (st.mode == "store") and st.storeScroll or st.manageScroll
    local rows = currentRows(st)
    local hdr = hdrRows(st)
    local visRows = math.max(1, H - 1 - hdr)

    drawTabs(win, W, st.mode, st.showSystem)
    drawSearch(win, W, query)
    if st.mode == "store" then drawSourceBar(win, W, st) end

    win.setCursorPos(1, hdr)
    win.setBackgroundColor(colors.black)
    win.setTextColor(colors.gray)
    win.write(string.rep("-", contentW))

    local y = hdr + 1
    local first = math.max(1, scroll + 1)
    local last = math.min(#rows, first + visRows - 1)
    for i = first, last do
        local row = rows[i]
        if row.type == "header" then
            drawHeader(win, y, row, contentW)
        elseif st.mode == "store" then
            drawStoreApp(win, y, row.app, W, st)
        else
            drawManageApp(win, y, row.app, W, st, i)
        end
        y = y + 1
    end

    if #rows == 0 then
        win.setCursorPos(1, hdr + 1)
        win.setBackgroundColor(colors.black)
        win.setTextColor(colors.gray)
        if query ~= "" then
            win.write(padR("No matches", contentW))
        elseif st.mode == "store" then
            win.write(padR("No apps in store", contentW))
        else
            win.write(padR("No apps installed", contentW))
        end
    end

    for yy = y, H - 1 do
        win.setCursorPos(1, yy)
        win.setBackgroundColor(colors.black)
        win.write(string.rep(" ", contentW))
    end

    st.sb:setBounds(W, hdr + 1, H - 1)
    st.sb:setContent(visRows, #rows)
    st.sb:setScroll(scroll)
    st.sb:draw(win)

    win.setCursorPos(1, H)
    win.setBackgroundColor(colors.black)
    win.setTextColor(colors.gray)
    local statusStr = (st.mode == "store") and st.storeStatus or st.manageStatus
    if statusStr == "" then
        if #rows > visRows then
            statusStr = string.format("%d-%d/%d", first, last, #rows)
        elseif st.mode == "store" then
            statusStr = "Tap an app to install or update"
        else
            statusStr = "Tap app twice to remove"
        end
    end
    win.write(padR(statusStr, W))
end

local function setScroll(st, value)
    if st.mode == "store" then st.storeScroll = value
    else st.manageScroll = value end
end

local function clampScroll(st, H)
    local rows = currentRows(st)
    local maxScroll = math.max(0, #rows - math.max(1, H - 1 - hdrRows(st)))
    if st.mode == "store" then
        st.storeScroll = clamp(st.storeScroll, 0, maxScroll)
    else
        st.manageScroll = clamp(st.manageScroll, 0, maxScroll)
    end
end

local function appendQuery(st, ch)
    if st.mode == "store" then
        st.storeQuery = st.storeQuery .. ch
        st.storeScroll = 0
    else
        st.manageQuery = st.manageQuery .. ch
        st.manageScroll = 0
        st.manageConfirm = 0
    end
end

local function backspaceQuery(st)
    if st.mode == "store" then
        st.storeQuery = string.sub(st.storeQuery, 1, -2)
        st.storeScroll = 0
    else
        st.manageQuery = string.sub(st.manageQuery, 1, -2)
        st.manageScroll = 0
        st.manageConfirm = 0
    end
end

local function clearQuery(st)
    if st.mode == "store" then
        st.storeQuery = ""
        st.storeScroll = 0
    else
        st.manageQuery = ""
        st.manageScroll = 0
        st.manageConfirm = 0
    end
end

-- ── events ────────────────────────────────────────────────────────────────────

function M.onEvent(st, event, p1, p2, p3, p4)
    if event == "timer" and p1 == st.initialTimer then
        st.initialTimer = nil
        requestCatalog(st)
        return st, true
    end
    if event == "timer" and p1 == st.refreshTimer then
        requestCatalog(st)
        st.refreshTimer = os.startTimer(30)
        return st, true
    end

    if event == "rednet_message" then
        local senderId, proto = p1, p3
        -- Магазин присылает КОД, который пойдёт на диск, поэтому принимаем ответы
        -- только от выбранного сервера и только когда сами его выбрали.
        local expected = rednetTarget(st)
        local trusted  = not isHttpSource(st) and expected ~= nil and senderId == expected
        if trusted and proto == st.storeProtocol and type(p2) == "table" then
            if p2.type == "store_index" then
                onCatalogReceived(st, p2.apps or {})
                return st, true
            elseif p2.type == "store_app" and type(p2.id) == "string" then
                onAppReceived(st, p2)
                return st, true
            end
        end
    end

    if event == "mouse_click" or event == "monitor_touch" then
        local x, y = p2, p3
        local W, H = st.win.getSize()

        if y == 1 then
            if x <= TAB_STORE_W then
                st.mode = "store"
                st.storeScroll = 0
                st.manageConfirm = 0
            elseif x <= TAB_STORE_W + TAB_MANAGE_W then
                st.mode = "manage"
                st.manageScroll = 0
                st.manageConfirm = 0
                st.manageStatus = ""
                st.installed = scanInstalled(st.ctx)
            else
                -- SYS toggle (только в режиме manage)
                if st.mode == "manage" then
                    st.showSystem = not st.showSystem
                    st.manageConfirm = 0
                    st.manageScroll = 0
                end
            end
            return st, true
        end

        if y == 2 then
            if x >= W - 1 then clearQuery(st); return st, true end
            return st, true
        end

        if st.mode == "store" and y == SOURCE_ROW then
            local bx = 1
            for _, btn in ipairs(SOURCE_BUTTONS) do
                if x >= bx and x < bx + btn.w then
                    setSourceMode(st, btn.mode)
                    break
                end
                bx = bx + btn.w
            end
            return st, true
        end

        if st.sb:onClick(x, y) then
            setScroll(st, st.sb.scroll)
            return st, true
        end

        local row = y - hdrRows(st)
        if row >= 1 then
            local scroll = (st.mode == "store") and st.storeScroll or st.manageScroll
            local idx = scroll + row
            local rows = currentRows(st)
            local selected = rows[idx]
            if selected and selected.type == "header" then
                local expanded = (st.mode == "store") and st.storeExpanded or st.manageExpanded
                expanded[selected.cat] = not expanded[selected.cat]
                if st.mode == "store" then st.storeScroll = 0 else st.manageScroll = 0 end
                st.manageConfirm = 0
                return st, true
            end
            if st.mode == "store" then
                local app = selected and selected.app
                if app then
                    local W2, _ = st.win.getSize()
                    local contentW = W2 - 1
                    local hasDev = hasDevChannel(app)
                    -- Channel toggle: rightmost 3 chars before status badge (only if dev exists)
                    local chStart = contentW - 5 - 3 + 1  -- 6-badge + 3-ch
                    if hasDev and x >= chStart and x <= chStart + 2 then
                        local cur = appEffectiveChannel(app.id, st.channelOverrides, st.globalChannel)
                        st.channelOverrides[app.id] = (cur == "dev") and "stable" or "dev"
                        saveChannelOverrides(st.ctx, st.channelOverrides)
                        local newCh = st.channelOverrides[app.id]
                        st.storeStatus = (app.name or app.id) .. ": switched to " .. newCh
                    else
                        local ch = appEffectiveChannel(app.id, st.channelOverrides, st.globalChannel)
                        if isHttpSource(st) then
                            downloadHttp(st, app, ch)
                        else
                            local target = rednetTarget(st)
                            if target then
                                st.pendingDownloads[app.id] = ch
                                st.storeStatus = "Downloading " .. (app.name or app.id) .. " [" .. ch .. "]..."
                                st.ctx.send(target,
                                    {type = "store_request_app", id = app.id, channel = ch},
                                    st.storeProtocol)
                            else
                                st.storeStatus = "Store computer is not configured"
                            end
                        end
                    end
                    return st, true
                end
            else
                local item = selected and selected.app
                if item then
                    if item.system then
                        st.manageConfirm = 0
                        st.manageStatus = (item.name or item.id) .. ": system app"
                        return st, true
                    end
                    if st.manageConfirm == idx then
                        -- Второй тап — удалить
                        local ok, msg = deleteInstalledApp(st, item)
                        st.manageStatus = msg
                        st.manageConfirm = 0
                        st.installed = scanInstalled(st.ctx)
                        clampScroll(st, H)
                    else
                        st.manageConfirm = idx
                        st.manageStatus = "Tap again to remove"
                    end
                    return st, true
                end
            end
        end

        if st.manageConfirm ~= 0 then
            st.manageConfirm = 0
            st.manageStatus = ""
            return st, true
        end
    end

    if event == "mouse_drag" then
        if st.sb:onDrag(p2, p3) then
            setScroll(st, st.sb.scroll)
            return st, true
        end
        return st, false
    end

    if event == "mouse_scroll" then
        st.sb:scrollBy(p1)
        setScroll(st, st.sb.scroll)
        return st, true
    end

    if event == "char" then
        appendQuery(st, p1)
        return st, true
    end

    if event == "key" then
        local k = p1
        if k == keys.backspace then
            backspaceQuery(st)
            return st, true
        elseif k == keys.delete then
            clearQuery(st)
            return st, true
        elseif k == keys.tab then
            if st.mode == "store" then
                st.mode = "manage"
                st.installed = scanInstalled(st.ctx)
            else
                st.mode = "store"
            end
            st.manageConfirm = 0
            return st, true
        elseif k == keys.up then
            if st.mode == "store" then st.storeScroll = math.max(0, st.storeScroll - 1)
            else st.manageScroll = math.max(0, st.manageScroll - 1) end
            return st, true
        elseif k == keys.down then
            if st.mode == "store" then st.storeScroll = st.storeScroll + 1
            else st.manageScroll = st.manageScroll + 1 end
            local _, H = st.win.getSize()
            clampScroll(st, H)
            return st, true
        elseif k == keys.escape then
            if ((st.mode == "store" and st.storeQuery) or st.manageQuery) ~= "" then
                clearQuery(st)
                return st, true
            end
        end
        return st, true
    end

    return st, false
end

return M
