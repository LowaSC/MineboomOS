-- Точка входа PocketOS: создание ОС, регистрация приложений, event loop.
-- Поддерживает встроенный терминал и внешний монитор (cfg.monitorSide / cfg.useMonitor).
local POCKETOS_ROOT = "/os/lib/pocketos"
local Loader     = dofile("/os/lib/loader.lua")
local Shell      = Loader.require(POCKETOS_ROOT .. "/shell.lua")
local WM         = Loader.require(POCKETOS_ROOT .. "/wm.lua")
local Toast      = Loader.require(POCKETOS_ROOT .. "/toast.lua")
local Log        = Loader.require("/os/lib/log.lua")
local Notify     = Loader.require("/os/lib/notify.lua")
local Login      = Loader.require(POCKETOS_ROOT .. "/login.lua")
local LockScreen = Loader.require(POCKETOS_ROOT .. "/lockscreen.lua")
local Users      = Loader.require("/os/lib/users.lua")
local Sound      = Loader.require("/os/lib/sound.lua")
local Clock      = Loader.require("/os/lib/clock.lua")
local Modem      = Loader.require("/os/lib/modem.lua")

-- Подхватываем уже накопленный лог при старте.
pcall(Log.loadFromDisk)

local PocketOS = {}

local function tryMonitor(mon)
    return type(mon) == "table" and type(mon.getSize) == "function" and mon
end

function PocketOS.create(cfg)
    -- Если настроен сервер пользователей — переключаем Users в remote-режим.
    -- Делаем это ДО первого обращения к Users.list()/find().
    if cfg.userServerId then
        local modem = Modem.open(cfg.modemSide)
        if modem then cfg.modemSide = modem end
        Users.setRemote(cfg.userServerId, modem, cfg.userServerIsolated)
    else
        Users.setRemote(nil)
    end
    Shell.userDataRoot = Users.getDataRoot

    -- Определяем сессию и пользователя ДО загрузки desktop (путь зависит от юзера).
    local currentUser  = nil
    local loginState   = nil
    do
        local session = Users.getSession()
        local allUsers = Users.list()
        if session and session.userId then
            currentUser = Users.find(session.userId)
        end
        loginState = Login.initialState(allUsers, session, Users.getLastUser())
    end

    -- Загружаем desktop.db пользователя (или общий если не залогинен).
    local function userDesktopId()
        return currentUser and currentUser.id or nil
    end
    local desktop = Shell.loadDesktop(userDesktopId())

    local function pickScreen()
        local pref = desktop.display  -- "external" | "internal" | nil
        if pref == "internal" then return term.current() end
        -- Ищем внешний монитор: подсказка из cfg или автопоиск
        local mon
        if cfg.monitorSide then
            local ok, m = pcall(peripheral.wrap, cfg.monitorSide)
            mon = (ok and tryMonitor(m)) or tryMonitor(peripheral.find("monitor"))
        elseif pref == "external" or cfg.useMonitor then
            mon = tryMonitor(peripheral.find("monitor"))
        end
        return mon or term.current()
    end

    local screen   = pickScreen()
    local hasScale = type(screen.setTextScale) == "function"
    if hasScale and cfg.monitorTextScale and not desktop.textScale then
        desktop.textScale = cfg.monitorTextScale
    end
    if hasScale then screen.setTextScale(desktop.textScale or 1) end

    local W, H = screen.getSize()
    local AH   = H - 1

    local workArea   = window.create(screen, 1, 1, W, AH)
    local taskbarWin = window.create(screen, 1, H, W, 1)

    local os_apps     = {}
    local os_services = {}   -- фоновые сервисы без UI
    local os_running  = {}
    local os_focused  = 0
    local os_modal    = nil       -- nil | {kind=...}
    -- "login" | "locked" | "home" | "launcher"
    local os_screen   = currentUser and "home" or "login"
    local prev_screen = os_screen  -- для black-frame перехода
    local os_launcherScroll = 0
    local os_launcherQuery  = ""
    local shiftHeld  = false

    local function isDigitChar(ch)
        return type(ch) == "string" and string.match(ch, "^%d$") ~= nil
    end

    local function isEnterKey(k)
        return k == keys.enter or k == keys.space or (keys.numPadEnter and k == keys.numPadEnter)
    end

    -- ── Auto-lock ─────────────────────────────────────────────────────────────
    local lockTimer = nil
    local function resetLockTimer()
        if lockTimer then os.cancelTimer(lockTimer) end
        lockTimer = nil
        local timeout = currentUser and (currentUser.lockTimeout or 600)
        if timeout and timeout > 0 then
            lockTimer = os.startTimer(timeout)
        end
    end

    -- ── Фильтрация приложений по правам пользователя ─────────────────────────
    local function visibleApps()
        if not currentUser then return {} end
        if currentUser.isAdmin then return os_apps end
        -- Не-админ: adminOnly-приложения (например Terminal) скрыты ВСЕГДА,
        -- даже при allowedApps == nil. Затем применяем whitelist, если задан.
        local allowed = currentUser.allowedApps   -- nil = все (кроме adminOnly)
        local out = {}
        for _, def in ipairs(os_apps) do
            if not def.adminOnly then
                if allowed == nil then
                    table.insert(out, def)
                else
                    for _, id in ipairs(allowed) do
                        if def.id == id then table.insert(out, def); break end
                    end
                end
            end
        end
        return out
    end

    -- ── Rednet ────────────────────────────────────────────────────────────────

    -- Rate-limit для уведомлений о сбоях rednet: не чаще раза в 60 секунд,
    -- иначе можем спамить toast'ами при недоступной сети.
    local _lastRednetWarn = 0
    local function warnRednet(reason, detail)
        Log.warn(tostring(reason) .. (detail and (": " .. tostring(detail)) or ""), "rednet")
        local now = (os.epoch and math.floor(os.epoch("utc") / 1000)) or os.clock()
        if now - _lastRednetWarn < 60 then return end
        _lastRednetWarn = now
        Notify.push("Network: " .. reason, detail, {level = "warn", source = "rednet"})
    end

    local function openRednet()
        local preferred = desktop.modemSide or cfg.modemSide
        local side, err = Modem.open(preferred)
        if side then
            if side ~= preferred then
                desktop.modemSide = side
                Shell.saveDesktop(desktop, currentUser and currentUser.id or nil)
            end
            cfg.modemSide = side
            return true
        end
        warnRednet("modem open failed", tostring(err))
        return false
    end

    local function setModemSide(side)
        if type(side) ~= "string" or side == "" then return false end
        local previous = desktop.modemSide or cfg.modemSide
        if previous and rednet.isOpen and previous ~= side then
            pcall(rednet.close, previous)
        end
        desktop.modemSide = side
        cfg.modemSide = side
        Shell.saveDesktop(desktop, currentUser and currentUser.id or nil)
        return openRednet()
    end

    local function safeRednetSend(id, msg, proto)
        if not openRednet() then return false end
        local ok, err = pcall(rednet.send, id, msg, proto)
        if not ok then warnRednet("send failed", tostring(err)) end
        return ok
    end

    local function safeRednetBroadcast(msg, proto)
        if not openRednet() then return false end
        local ok, err = pcall(rednet.broadcast, msg, proto)
        if not ok then warnRednet("broadcast failed", tostring(err)) end
        return ok
    end

    -- ── Применение настроек desktop (live) ────────────────────────────────────

    local ctx

    local function applyScale()
        if not hasScale then return end
        local s = desktop.textScale or 1
        screen.setTextScale(s)
        local nw, nh = screen.getSize()
        if nw ~= W or nh ~= H then
            W, H = nw, nh
            AH   = H - 1
            if workArea.reposition  then workArea.reposition(1, 1, W, AH) end
            if taskbarWin.reposition then taskbarWin.reposition(1, H, W, 1) end
            WM.reposition(os_running, workArea)
        end
    end

    local function reloadDesktop(userId)
        desktop = Shell.loadDesktop(userId)
        ctx.desktop = desktop
        ctx.saveDesktop = function() Shell.saveDesktop(desktop, userId) end
        applyScale()
    end

    -- ── Контекст приложений ───────────────────────────────────────────────────

    -- Тост-таймер: ставим, когда что-то нужно скрыть; nil при пустой очереди.
    local toastTimer = nil
    local function scheduleToastTick()
        local delay = Toast.nextExpiry()
        if delay then toastTimer = os.startTimer(delay) end
    end

    local function showToast(text, opts)
        Toast.push(text, opts)
        scheduleToastTick()
    end

    local function vol()
        if desktop.soundEnabled == false then return 0 end
        return desktop.volume or 1
    end

    -- Подписка: каждое новое уведомление автоматически даёт toast + звук.
    Notify.subscribe(function(entry)
        local prefix = "[i] "
        if     entry.level == "error"   then prefix = "[!] "; Sound.error(vol())
        elseif entry.level == "warn"    then prefix = "[*] "; Sound.notify(vol())
        elseif entry.level == "success" then prefix = "[+] "; Sound.success(vol())
        else Sound.notify(vol())
        end
        showToast(prefix .. (entry.title or ""), {level = entry.level})
    end)

    -- Прокси для onEvent: pcall с логом ошибок в Log + Notify (тост
    -- генерируется подписчиком Notify).
    local function callAppEvent(r, event, p1, p2, p3, p4)
        local ok, s, nd = pcall(r.def.onEvent, r.state, event, p1, p2, p3, p4)
        if ok then return true, s, nd end
        local label = (r.def.id or "app")
        Log.error(tostring(s), label)
        Notify.push("App error: " .. label, tostring(s), {level = "error", source = label})
        return false
    end

    -- ── Фоновые воркеры (ctx.spawn) ───────────────────────────────────────────
    -- Приложения уносят блокирующий I/O (http.get, долгое ожидание rednet) в
    -- корутину. Внутри неё блокирующие вызовы делают coroutine.yield в наш цикл
    -- вместо заморозки UI. Модель filter/resume повторяет ядро Opus.
    local os_workers = {}

    -- Резюмит воркер по семантике os.pullEvent: будим только если фильтр пуст
    -- или совпал с событием. Возвращает true, если воркер ещё жив.
    local function resumeWorker(wk, event, ...)
        if coroutine.status(wk.co) == "dead" then return false end
        if wk.filter ~= nil and wk.filter ~= event then return true end
        local ok, filt = coroutine.resume(wk.co, event, ...)
        if not ok then
            local label = wk.label or "worker"
            Log.error(tostring(filt), label)
            Notify.push("Background task failed", tostring(filt),
                        {level = "error", source = label})
            return false
        end
        wk.filter = filt
        return coroutine.status(wk.co) ~= "dead"
    end

    ctx = {
        config       = cfg,
        send         = safeRednetSend,
        broadcast    = safeRednetBroadcast,
        openRednet   = openRednet,
        desktop      = desktop,
        hasScale     = hasScale,
        saveDesktop  = function() Shell.saveDesktop(desktop, userDesktopId()) end,
        applyScale   = applyScale,
        setModemSide = setModemSide,
        themes       = function() return Shell.getThemes() end,
        wallpapers   = Shell.WALLPAPERS,
        osRoot       = "/os",
        appRoot      = "/os/apps",
        dataRoot     = currentUser and Users.getDataRoot(currentUser.id) or "/data",
        currentUser  = currentUser,
        users        = Users,
        lockDevice   = function()
            os_screen = "locked"
            if lockTimer then os.cancelTimer(lockTimer) end
            lockTimer = nil
        end,
        log          = function(level, msg, src) Log.write(level, msg, src) end,
        notify       = function(title, body, opts) Notify.push(title, body, opts) end,
        toast        = showToast,
    }

    local function lockDevice()
        os_screen = "locked"
        if lockTimer then os.cancelTimer(lockTimer) end
        lockTimer = nil
    end
    ctx.lockDevice = lockDevice

    -- Просит ОС перерисовать экран (для воркеров, которые мутируют state апва
    -- из фоновой корутины). Использует уже существующий канал refresh_desktop.
    ctx.refresh = function() os.queueEvent("pocketos_event", "refresh_desktop") end

    -- Запускает fn() в фоновой корутине. fn может звать блокирующие API
    -- (http.get, sleep, rednet.receive) — они отдадут управление циклу ОС, а не
    -- заморозят его. Результат отдавайте через мутацию state апва + ctx.refresh().
    ctx.spawn = function(fn, label)
        if type(fn) ~= "function" then return end
        local wk = { label = label, co = coroutine.create(fn) }
        -- Первый resume крутит воркер до первого блокирующего вызова.
        if resumeWorker(wk) then table.insert(os_workers, wk) end
    end

    -- ── Recent apps (MRU) ─────────────────────────────────────────────────────

    local MAX_RECENT = 8

    local function buildRecentDefs()
        local visible = visibleApps()
        local list = desktop.recentApps or {}
        local result, seen = {}, {}
        for _, id in ipairs(list) do
            for _, def in ipairs(visible) do
                if def.id == id and not seen[id] then
                    table.insert(result, def); seen[id] = true; break
                end
            end
        end
        if #result < 6 then
            for _, def in ipairs(visible) do
                if not seen[def.id] and not def.system then
                    table.insert(result, def); seen[def.id] = true
                    if #result >= 6 then break end
                end
            end
        end
        return result
    end

    local function pushRecent(id)
        if type(id) ~= "string" then return end
        local list = desktop.recentApps or {}
        for i = #list, 1, -1 do
            if list[i] == id then table.remove(list, i) end
        end
        table.insert(list, 1, id)
        while #list > MAX_RECENT do table.remove(list) end
        desktop.recentApps = list
        Shell.saveDesktop(desktop, currentUser and currentUser.id or nil)
    end

    local function buildDctx()
        local notifList = Notify.list()
        local lastNotif = notifList[#notifList]
        local logTail   = Log.tail(1)
        local lastLog   = logTail and logTail[#logTail]
        local freeKb
        if fs and fs.getFreeSpace then
            local ok, n = pcall(fs.getFreeSpace, "/")
            if ok and type(n) == "number" then freeKb = math.floor(n / 1024) end
        end
        return {
            unread        = Notify.unreadCount(),
            notifTotal    = #notifList,
            lastNotif     = lastNotif,
            lastLog       = lastLog,
            computerId    = cfg.computerId,
            computerLabel = cfg.computerLabel,
            modemSide     = desktop.modemSide or cfg.modemSide,
            freeKb        = freeKb,
            osVersion     = cfg.osVersion,
            wallpaper     = desktop.pattern,
            clockOpts     = Clock.optsFromDesktop(desktop),
            recentApps    = buildRecentDefs(),
            networkStatus = Users.getNetworkStatus(),
        }
    end

    local function render()
        -- Чёрный кадр при смене состояния экрана
        if os_screen ~= prev_screen then
            screen.setBackgroundColor(colors.black)
            screen.clear()
            prev_screen = os_screen
        end

        if os_screen == "login" then
            -- Скрываем taskbar чтобы не проглядывал поверх экрана входа
            if taskbarWin.setVisible then taskbarWin.setVisible(false) end
            local theme = Shell.getTheme(desktop.themeIndex)
            loginState.networkStatus = Users.getNetworkStatus()
            loginState.allowLocalLogin = cfg.userServerIsolated and fs.exists("/data/users.db")
            Login.render(screen, W, H, loginState, theme)
            return
        end
        if os_screen == "locked" then
            if taskbarWin.setVisible then taskbarWin.setVisible(false) end
            LockScreen.render(screen, W, H, currentUser, Clock.optsFromDesktop(desktop), Users.getNetworkStatus())
            return
        end
        if taskbarWin.setVisible then taskbarWin.setVisible(true) end
        Shell.render(visibleApps(), os_running, os_focused, os_modal,
                     os_screen, os_launcherScroll, os_launcherQuery,
                     desktop, workArea, taskbarWin, W, AH, {
                         hasScale = hasScale,
                         unread   = Notify.unreadCount(),
                         userName = currentUser and currentUser.name,
                         dctx     = buildDctx(),
                     })
    end

    local function resetLauncher()
        os_launcherQuery  = ""
        os_launcherScroll = 0
    end

    local function launchApp(def)
        os_running, os_focused = WM.launch(os_running, os_focused, def, workArea, ctx)
        os_modal  = nil
        os_screen = "home"
        resetLauncher()
        if def and def.id then pushRecent(def.id) end
        Sound.open(vol())
    end

    -- Запустить приложение либо переключиться на уже запущенное.
    local function activateApp(def)
        if not def then return end
        for i, r in ipairs(os_running) do
            if r.def.id == def.id then
                os_focused = i
                os_modal   = nil
                os_screen  = "home"
                resetLauncher()
                pushRecent(def.id)
                return
            end
        end
        launchApp(def)
    end

    local function closeApp(idx)
        os_focused = WM.close(os_running, os_focused, idx)
        Sound.close(vol())
    end

    local function minimizeApp()
        os_focused = 0
        os_modal = nil
    end

    local function openTray()
        os_modal = {kind = "tray", volume = desktop.volume or 1, scale = desktop.textScale or 1}
    end

    local function modalOpts()
        return {themes = Shell.getThemes(), wallpapers = Shell.WALLPAPERS,
                hasScale = hasScale, W = W, AH = AH}
    end

    -- Изменение значения slider/tray с шагом dir (+/-1).
    local function clamp(v, lo, hi) return math.max(lo, math.min(hi, v)) end

    local function applyVolume(delta)
        desktop.volume = clamp(math.floor(((desktop.volume or 1) + delta) * 100 + 0.5) / 100, 0, 1)
        Shell.saveDesktop(desktop, currentUser and currentUser.id or nil)
    end

    local function applyTextScale(delta)
        if not hasScale then return end
        local s = (desktop.textScale or 1) + delta
        s = clamp(math.floor(s * 10 + 0.5) / 10, 0.5, 5)
        desktop.textScale = s
        applyScale()
        Shell.saveDesktop(desktop, currentUser and currentUser.id or nil)
    end

    -- ── Публичное API ─────────────────────────────────────────────────────────

    local pos = {}

    function pos:registerApp(def)
        table.insert(os_apps, def)
        openRednet()
    end

    function pos:registerService(svc)
        if type(svc) == "table" and type(svc.onEvent) == "function" then
            table.insert(os_services, svc)
        end
    end

    function pos:loadAppFile(file)
        local ok, def = pcall(dofile, file)
        if not ok or type(def) ~= "table" then return nil end
        def._file = file
        for i, ex in ipairs(os_apps) do
            if ex.id == def.id then os_apps[i] = def; return def end
        end
        table.insert(os_apps, def)
        return def
    end

    -- ── Обработчики кликов ────────────────────────────────────────────────────

    local function openNotifications()
        os_modal = {
            kind   = "notifications",
            items  = Notify.list(),
            scroll = 0,
        }
        Notify.markAllRead()
    end

    -- Возвращает true, если экран нужно перерисовать.
    local function handleTaskbarClick(btn, mx)
        local opts = {unread = Notify.unreadCount(),
                      userName = currentUser and currentUser.name}
        local kind, data = Shell.Taskbar.hit(os_running, mx, W, opts)
        if kind == "launcher" then
            if os_screen == "launcher" then
                os_screen = "home"
                resetLauncher()
            else
                os_screen = "launcher"
                resetLauncher()
            end
            os_focused = 0
            os_modal = nil
            return true
        elseif kind == "app" then
            if btn == 3 then closeApp(data) else
                os_focused = data
                os_modal   = nil
                os_screen  = "home"
            end
            return true
        elseif kind == "tray" then
            if type(os_modal) == "table" and os_modal.kind == "tray" then
                os_modal = nil
            else openTray() end
            return true
        elseif kind == "bell" then
            if type(os_modal) == "table" and os_modal.kind == "notifications" then
                os_modal = nil
            else
                openNotifications()
            end
            return true
        end
        return false
    end

    -- Прямое объявление: реальное тело определено ниже (после doLogin),
    -- но handleLauncherClick ссылается на него раньше по тексту файла.
    local doLogout

    local function handleLauncherClick(btn, mx, my)
        local expanded = desktop.expandedCategories or {}
        local kind, data = Shell.Launcher.hit(visibleApps(), os_running, os_launcherScroll,
                                              os_launcherQuery, expanded, mx, my, W, AH)
        if kind == "close" then
            os_screen = "home"
            resetLauncher()
            return true
        elseif kind == "clear_query" then
            if os_launcherQuery ~= "" then
                os_launcherQuery = ""
                os_launcherScroll = 0
                return true
            end
            return false
        elseif kind == "search" then
            -- Просто индикация фокуса; ввод идёт через char events.
            return false
        elseif kind == "toggle_category" then
            local cat = data
            if type(cat) == "string" then
                desktop.expandedCategories = desktop.expandedCategories or {}
                desktop.expandedCategories[cat] = not desktop.expandedCategories[cat]
                Shell.saveDesktop(desktop, currentUser and currentUser.id or nil)
                -- После сворачивания скролл может вылезти за пределы.
                os_launcherScroll = Shell.Launcher.clampScroll(
                    visibleApps(), os_running, os_launcherQuery,
                    desktop.expandedCategories, os_launcherScroll, AH)
                return true
            end
            return false
        elseif kind == "app" then
            local def = data
            if not def then return false end
            if btn == 3 then
                for i, r in ipairs(os_running) do
                    if r.def.id == def.id then closeApp(i); return true end
                end
                return false
            end
            activateApp(def)
            return true
        elseif kind == "logout" then
            doLogout()
            return true
        elseif kind == "reboot" then
            os.reboot()
            return true
        elseif kind == "lock_now" then
            lockDevice()
            Sound.lock(vol())
            return true
        end
        return false
    end

    local function handleModalClick(mx, my)
        local m = os_modal
        local kind, data = Shell.Modal.hit(m, mx, my, W, AH, modalOpts())

        if kind == "outside" or kind == "close" then
            os_modal = nil
            return true
        end

        if m.kind == "volume" then
            if kind == "minus" then applyVolume(-0.1); m.value = desktop.volume end
            if kind == "plus"  then applyVolume( 0.1); m.value = desktop.volume end
            return true
        end

        if m.kind == "scale" then
            if kind == "minus" then applyTextScale(-0.5); m.value = desktop.textScale end
            if kind == "plus"  then applyTextScale( 0.5); m.value = desktop.textScale end
            return true
        end

        if m.kind == "tray" then
            if kind == "vol_minus"   then applyVolume(-0.1)   ; m.volume = desktop.volume    end
            if kind == "vol_plus"    then applyVolume( 0.1)   ; m.volume = desktop.volume    end
            if kind == "scale_minus" then applyTextScale(-0.5); m.scale  = desktop.textScale end
            if kind == "scale_plus"  then applyTextScale( 0.5); m.scale  = desktop.textScale end
            if kind == "reboot"      then os.reboot()                                        end
            return true
        end

        if m.kind == "theme" then
            if kind == "select" then
                m.selected = data
                desktop.themeIndex = data
                Shell.saveDesktop(desktop, currentUser and currentUser.id or nil)
            end
            return true
        end

        if m.kind == "wallpaper" then
            if kind == "select" then
                m.selected = data
                desktop.pattern = Shell.WALLPAPERS[data]
                Shell.saveDesktop(desktop, currentUser and currentUser.id or nil)
            end
            return true
        end

        if m.kind == "modem" then
            if kind == "select" then
                m.selected = data
                local side = m.items and m.items[data]
                if side and setModemSide(side) then
                    showToast("Modem: " .. side, {level = "success"})
                elseif side then
                    showToast("Modem failed: " .. side, {level = "error"})
                end
            end
            return true
        end

        if m.kind == "notifications" then
            if kind == "clear_all" then
                Notify.clear()
                m.items  = {}
                m.scroll = 0
            end
            return true
        end

        return false
    end

    local function handleDashboardClick(btn, mx, my)
        local kind, data = Shell.Dashboard.hit(mx, my, W, AH)
        if kind == "app" and type(data) == "table" then
            activateApp(data)
            return true
        elseif kind == "status" then
            -- Если есть непрочитанные — открываем уведомления, иначе tray.
            if Notify.unreadCount() > 0 then
                openNotifications()
            else
                openTray()
            end
            return true
        elseif kind == "clock" then
            openTray()
            return true
        end
        return kind ~= nil
    end

    local function handleAppTitlebarClick(mx, my)
        local hit = Shell.hitAppTitlebar(mx, my, W)
        if hit == "minimize" then
            minimizeApp()
            return true
        elseif hit == "close" then
            closeApp(os_focused)
            os_modal = nil
            return true
        elseif hit == "titlebar" then
            return true
        end
        return false
    end

    -- ── Главный цикл ──────────────────────────────────────────────────────────

    -- Закрывает все запущенные приложения (смена пользователя / logout).
    local function closeAllApps()
        for i = #os_running, 1, -1 do
            local r = os_running[i]
            if r.def and r.def.onClose then pcall(r.def.onClose, r.state) end
        end
        os_running = {}
        os_focused = 0
        os_modal   = nil
    end

    -- Применяет вход пользователя: обновляет ctx, dataRoot, desktop, запускает таймер.
    local function doLogin(user, remember)
        -- Закрываем приложения предыдущего пользователя
        closeAllApps()
        currentUser = user
        Users.ensureDir(user.id)
        ctx.currentUser = user
        ctx.dataRoot    = Users.getDataRoot(user.id)
        -- Перезагружаем desktop пользователя и применяем сохранённый scale.
        reloadDesktop(user.id)
        if remember then Users.saveSession(user.id)
        else Users.clearSession() end
        -- Запоминаем последнего вошедшего (переживает logout).
        Users.setLastUser(user.id)
        os_screen = "home"
        Sound.login(vol())
        resetLockTimer()
        -- Обновляем loginState на следующий вход
        loginState = Login.initialState(Users.list(), Users.getSession(), Users.getLastUser())
    end

    -- Выход из системы: закрывает приложения, сбрасывает сессию, возвращает на login.
    -- (local объявлен выше, перед handleLauncherClick)
    function doLogout()
        Sound.lock(vol())
        closeAllApps()
        Users.clearSession()
        if lockTimer then os.cancelTimer(lockTimer); lockTimer = nil end
        currentUser     = nil
        ctx.currentUser = nil
        ctx.dataRoot    = "/data"
        reloadDesktop(nil)
        os_screen   = "login"
        loginState  = Login.initialState(Users.list(), nil, Users.getLastUser())
    end

    local function unlockDevice()
        local session = Users.getSession()
        if currentUser and session and session.userId == currentUser.id then
            os_screen = "home"
            resetLockTimer()
            return
        end

        closeAllApps()
        currentUser     = nil
        ctx.currentUser = nil
        ctx.dataRoot    = "/data"
        reloadDesktop(nil)
        if lockTimer then os.cancelTimer(lockTimer); lockTimer = nil end
        os_screen  = "login"
        loginState = Login.initialState(Users.list(), session, Users.getLastUser())
    end

    local function handleLoginAction(action, data)
        if not action then return false end
        if action == "local_login" and loginState.allowLocalLogin then
            local Connections = dofile("/os/lib/connections.lua")
            local ok, err = Connections.set("userServerId", false)
            if ok then os.reboot()
            else loginState.error = tostring(err) end
            return true
        end

        if loginState.mode == "login" then
            if action == "user_prev" then
                local n = #(loginState.users or {})
                loginState.userIdx = n > 0 and ((loginState.userIdx - 2) % n + 1) or 1
                loginState.password = ""
                loginState.error = ""
            elseif action == "user_next" then
                local n = #(loginState.users or {})
                loginState.userIdx = n > 0 and (loginState.userIdx % n + 1) or 1
                loginState.password = ""
                loginState.error = ""
            elseif action == "digit" then
                loginState.password = loginState.password .. tostring(data)
                loginState.error = ""
            elseif action == "backspace" then
                if #loginState.password > 0 then
                    loginState.password = string.sub(loginState.password, 1, -2)
                end
            elseif action == "remember" then
                loginState.remember = not loginState.remember
            elseif action == "ok" then
                local users = loginState.users or {}
                local u = users[loginState.userIdx]
                if u and Users.authenticate(u.id, loginState.password) then
                    doLogin(u, loginState.remember)
                else
                    loginState.error = "Wrong password"
                    loginState.password = ""
                end
            elseif action == "register" then
                loginState.mode    = "register"
                loginState.regStep = 1
                loginState.regName = ""
                loginState.regPass = ""
                loginState.regConfirm = ""
                loginState.regError   = ""
            end
        else -- register mode
            if action == "cancel" then
                loginState.mode = "login"
                loginState.password = ""
                loginState.error = ""
            elseif action == "digit" then
                if loginState.regStep == 1 then
                    loginState.regName = loginState.regName .. tostring(data)
                elseif loginState.regStep == 2 then
                    loginState.regPass = loginState.regPass .. tostring(data)
                elseif loginState.regStep == 3 then
                    loginState.regConfirm = loginState.regConfirm .. tostring(data)
                end
                loginState.regError = ""
            elseif action == "backspace" then
                if loginState.regStep == 1 and #loginState.regName > 0 then
                    loginState.regName = string.sub(loginState.regName, 1, -2)
                elseif loginState.regStep == 2 and #loginState.regPass > 0 then
                    loginState.regPass = string.sub(loginState.regPass, 1, -2)
                elseif loginState.regStep == 3 and #loginState.regConfirm > 0 then
                    loginState.regConfirm = string.sub(loginState.regConfirm, 1, -2)
                end
            elseif action == "ok" then
                if loginState.regStep == 1 then
                    if #loginState.regName < 1 then
                        loginState.regError = "Name required"
                    else
                        loginState.regStep = 2
                    end
                elseif loginState.regStep == 2 then
                    if #loginState.regPass < 1 then
                        loginState.regError = "Password required"
                    else
                        loginState.regStep = 3
                    end
                elseif loginState.regStep == 3 then
                    if loginState.regPass ~= loginState.regConfirm then
                        loginState.regError = "Passwords differ"
                        loginState.regConfirm = ""
                    else
                        -- Генерируем id из имени (строчные, без пробелов)
                        local newId = string.lower(loginState.regName):gsub("%s+", "_")
                        if Users.find(newId) then
                            loginState.regError = "User exists"
                        else
                            local db = Users.load()
                            Users.create(db, newId, loginState.regName, loginState.regPass, false)
                            Users.save(db)
                            -- Обновляем список пользователей
                            loginState.users = Users.list()
                            loginState.mode  = "login"
                            loginState.password = ""
                            loginState.error = "Registered! Enter password"
                            -- Найти нового юзера
                            for i, u in ipairs(loginState.users) do
                                if u.id == newId then loginState.userIdx = i; break end
                            end
                        end
                    end
                end
            end
        end
        return true
    end

    -- Обработчик клика по экрану входа.
    local function handleLoginClick(mx, my)
        local action, data = Login.hit(mx, my, W, H, loginState)
        return handleLoginAction(action, data)
    end

    function pos:run()
        if currentUser then resetLockTimer() end
        openRednet()
        render()
        -- Clock timer: app screens redraw only when the displayed minute changes;
        -- lockscreen and home dashboard stay live.
        local clockTimer = os.startTimer(1)
        local lastClock  = Shell.Taskbar.getClockStr(Clock.optsFromDesktop(desktop))

        while true do
            local event, p1, p2, p3, p4 = os.pullEvent()
            local needsDraw = false

            -- Памп фоновых воркеров: каждый получает любое событие (с учётом
            -- своего фильтра), завершившиеся/упавшие удаляются. Идём с конца,
            -- чтобы безопасно удалять; новые воркеры (spawn из воркера) попадут
            -- в следующий тик.
            for i = #os_workers, 1, -1 do
                if not resumeWorker(os_workers[i], event, p1, p2, p3, p4) then
                    table.remove(os_workers, i)
                end
            end

            if event == "key" then
                if p1 == keys.leftShift or p1 == keys.rightShift then shiftHeld = true end
            elseif event == "key_up" then
                if p1 == keys.leftShift or p1 == keys.rightShift then shiftHeld = false end
            end

            -- Сбрасываем таймер блокировки при активности (только если залогинен и не заблокирован)
            if os_screen == "home" or os_screen == "launcher" then
                if event ~= "timer" then resetLockTimer() end
            end

            if event == "mouse_click" or event == "monitor_touch" then
                local btn = (event == "mouse_click") and p1 or 1
                local mx, my = p2, p3

                -- Экран входа
                if os_screen == "login" then
                    -- Ввод имени в режиме register: char-события
                    needsDraw = handleLoginClick(mx, my) or needsDraw

                -- Экран блокировки
                elseif os_screen == "locked" then
                    local action = LockScreen.hit(mx, my, W, H)
                    if action == "unlock" then
                        unlockDevice()
                    end
                    needsDraw = true

                elseif my == H then
                    needsDraw = handleTaskbarClick(btn, mx) or needsDraw
                elseif my >= 1 and my < H then
                    if type(os_modal) == "table" then
                        needsDraw = handleModalClick(mx, my) or needsDraw
                    elseif os_screen == "launcher" then
                        needsDraw = handleLauncherClick(btn, mx, my) or needsDraw
                    elseif os_focused == 0 then
                        needsDraw = handleDashboardClick(btn, mx, my) or needsDraw
                    elseif os_running[os_focused] then
                        if handleAppTitlebarClick(mx, my) then
                            needsDraw = true
                        elseif my > 1 then
                            local r = os_running[os_focused]
                            local ok2, s, nd = callAppEvent(r, event, btn, mx, my - 1, p4)
                            if ok2 then r.state = s; needsDraw = nd or needsDraw end
                        end
                    end
                end

            elseif event == "mouse_drag" then
                -- Тащение мышью передаём только в сфокусированное приложение,
                -- минуя таскбар/тайтлбар. Нужно, чтобы скроллбары в списках
                -- (RTC, factory и т.п.) поддерживали реальный drag thumb'а.
                local btn = p1
                local mx, my = p2, p3
                if os_focused > 0 and os_running[os_focused]
                   and my > 1 and my < H
                   and type(os_modal) ~= "table"
                   and os_screen ~= "launcher" then
                    local r = os_running[os_focused]
                    local ok2, s, nd = callAppEvent(r, event, btn, mx, my - 1, p4)
                    if ok2 then r.state = s; needsDraw = nd or needsDraw end
                end

            elseif event == "mouse_scroll" then
                local dir = p1
                if os_screen == "login" or os_screen == "locked" then
                    -- игнорируем
                elseif type(os_modal) == "table" then
                    needsDraw = Shell.Modal.scroll(os_modal, dir, modalOpts()) or needsDraw
                elseif os_screen == "launcher" then
                    os_launcherScroll = Shell.Launcher.scrollBy(
                        visibleApps(), os_running, os_launcherQuery,
                        desktop.expandedCategories or {},
                        os_launcherScroll, dir, AH)
                    needsDraw = true
                elseif os_focused > 0 and os_running[os_focused] then
                    local sx, sy = p2, p3
                    if sy ~= 1 then
                        local r = os_running[os_focused]
                        local appY = sy and (sy - 1) or sy
                        local ok2, s, nd = callAppEvent(r, event, p1, sx, appY, shiftHeld)
                        if ok2 then r.state = s; needsDraw = nd or needsDraw end
                    end
                end

            elseif event == "key" then
                -- Escape: закрывает модал/launcher глобально.
                if os_screen == "locked" then
                    -- Lock screen is dismissed by pointer/touch only.
                elseif os_screen == "login" then
                    if isEnterKey(p1) then
                        needsDraw = handleLoginAction("ok") or needsDraw
                    elseif p1 == keys.backspace then
                        needsDraw = handleLoginAction("backspace") or needsDraw
                    end
                elseif p1 == keys.escape and (os_modal or os_screen == "launcher") then
                    os_modal = nil
                    if os_screen == "launcher" then
                        os_screen = "home"
                        os_launcherQuery = ""
                        os_launcherScroll = 0
                    end
                    needsDraw = true
                elseif os_screen == "launcher" then
                    -- В launcher backspace стирает символ запроса.
                    if p1 == keys.backspace and #os_launcherQuery > 0 then
                        os_launcherQuery = string.sub(os_launcherQuery, 1, -2)
                        os_launcherScroll = 0
                        needsDraw = true
                    end
                elseif os_focused > 0 and os_running[os_focused] then
                    local r = os_running[os_focused]
                    local ok2, s, nd = callAppEvent(r, event, p1, p2, p3, p4)
                    if ok2 then r.state = s; needsDraw = nd or needsDraw end
                end

            elseif event == "char" then
                if os_screen == "locked" then
                    -- Ignore keyboard text input while locked.
                elseif os_screen == "login" then
                    if isDigitChar(p1) then
                        needsDraw = handleLoginAction("digit", p1) or needsDraw
                    elseif loginState.mode == "register" and loginState.regStep == 1 then
                        -- Ввод имени в режиме регистрации через клавиатуру
                        if type(p1) == "string" and #p1 == 1 then
                            loginState.regName = loginState.regName .. p1
                            loginState.regError = ""
                            needsDraw = true
                        end
                    end
                elseif os_screen == "launcher" then
                    if type(p1) == "string" and #p1 == 1 then
                        os_launcherQuery = os_launcherQuery .. p1
                        os_launcherScroll = 0
                        needsDraw = true
                    end
                elseif os_focused > 0 and os_running[os_focused] then
                    local r = os_running[os_focused]
                    local ok2, s, nd = callAppEvent(r, event, p1, p2, p3, p4)
                    if ok2 then r.state = s; needsDraw = nd or needsDraw end
                end

            elseif event == "paste" then
                if os_focused > 0 and os_running[os_focused] then
                    local r = os_running[os_focused]
                    local ok2, s, nd = callAppEvent(r, event, p1, p2, p3, p4)
                    if ok2 then r.state = s; needsDraw = nd or needsDraw end
                end

            elseif event == "rednet_message" then
                for _, r in ipairs(os_running) do
                    local ok2, s, nd = callAppEvent(r, event, p1, p2, p3, p4)
                    if ok2 then r.state = s; needsDraw = nd or needsDraw end
                end
                -- Сервисы тоже получают rednet события
                for _, svc in ipairs(os_services) do
                    pcall(svc.onEvent, ctx, event, p1, p2, p3, p4)
                end

            elseif event == "timer" then
                if p1 == clockTimer then
                    local clockNow = Shell.Taskbar.getClockStr(Clock.optsFromDesktop(desktop))
                    if clockNow ~= lastClock then
                        lastClock = clockNow
                        needsDraw = true
                    end
                    if os_screen == "locked"
                       or (os_screen == "home" and os_focused == 0) then
                        needsDraw = true
                    end
                    clockTimer = os.startTimer(1)
                elseif p1 == toastTimer then
                    if Toast.prune() then needsDraw = true end
                    scheduleToastTick()
                elseif p1 == lockTimer then
                    lockTimer = nil
                    if os_screen == "home" or os_screen == "launcher" then
                        lockDevice()
                        Sound.lock(vol())
                        needsDraw = true
                    end
                else
                    -- Чужой таймер: отдаём приложениям и сервисам.
                    for _, r in ipairs(os_running) do
                        local ok2, s, nd = callAppEvent(r, event, p1, p2, p3, p4)
                        if ok2 then r.state = s; needsDraw = nd or needsDraw end
                    end
                    for _, svc in ipairs(os_services) do
                        pcall(svc.onEvent, ctx, event, p1, p2, p3, p4)
                    end
                end

            elseif event == "pocketos_event" then
                -- Внутренние сообщения от приложений: открытие модалов и т.п.
                local kind = p1
                if kind == "open_modal" and type(p2) == "table" then
                    os_modal = p2
                    needsDraw = true
                elseif kind == "close_modal" then
                    os_modal = nil
                    needsDraw = true
                elseif kind == "refresh_desktop" then
                    needsDraw = true
                elseif kind == "switch_display" and type(p2) == "string" then
                    local mode = p2  -- "external" | "internal"
                    os_modal  = nil
                    os_screen = "home"
                    -- Очищаем старый экран перед сменой parent'а у workArea.
                    pcall(function()
                        screen.setBackgroundColor(colors.black); screen.clear()
                    end)
                    -- Выбираем новый экран.
                    if mode == "internal" then
                        screen = term.current()
                    else
                        local mon
                        if cfg.monitorSide then
                            local ok, m = pcall(peripheral.wrap, cfg.monitorSide)
                            mon = (ok and tryMonitor(m)) or tryMonitor(peripheral.find("monitor"))
                        else
                            mon = tryMonitor(peripheral.find("monitor"))
                        end
                        screen = mon or term.current()
                    end
                    hasScale    = type(screen.setTextScale) == "function"
                    ctx.hasScale = hasScale
                    if hasScale then screen.setTextScale(desktop.textScale or 1) end
                    W, H        = screen.getSize()
                    AH          = H - 1
                    workArea    = window.create(screen, 1, 1, W, AH)
                    taskbarWin  = window.create(screen, 1, H, W, 1)
                    -- Перепривязываем окна запущенных приложений к новому
                    -- workArea — состояние приложений (state) сохраняется.
                    WM.rebind(os_running, workArea)
                    needsDraw   = true
                elseif kind == "logout" then
                    doLogout()
                    needsDraw = true
                elseif kind == "set_lock_timeout" and type(p2) == "number" then
                    -- Смена timeout блокировки для текущего пользователя
                    if currentUser then
                        local db = Users.load()
                        for _, u in ipairs(db.users) do
                            if u.id == currentUser.id then u.lockTimeout = p2; break end
                        end
                        Users.save(db)
                        currentUser.lockTimeout = p2
                        ctx.currentUser = currentUser
                        resetLockTimer()
                    end
                    needsDraw = true
                elseif kind == "launch_app" and type(p2) == "string" then
                    local appId = p2
                    for _, def in ipairs(visibleApps()) do
                        if def.id == appId then activateApp(def); needsDraw = true; break end
                    end
                elseif kind == "register_app" and type(p2) == "string" then
                    local def = pos:loadAppFile(p2)
                    if def then needsDraw = true end
                elseif kind == "unregister_app" and type(p2) == "string" then
                    local appId = p2
                    for i = #os_running, 1, -1 do
                        if os_running[i].def.id == appId then
                            if os_running[i].def.onClose then
                                pcall(os_running[i].def.onClose, os_running[i].state)
                            end
                            table.remove(os_running, i)
                            if os_focused >= i then
                                os_focused = math.max(0, os_focused - 1)
                            end
                        end
                    end
                    for i = #os_apps, 1, -1 do
                        if os_apps[i].id == appId then
                            table.remove(os_apps, i)
                        end
                    end
                    needsDraw = true
                end
            end

            if needsDraw then render() end
        end
    end

    return pos
end

return PocketOS
