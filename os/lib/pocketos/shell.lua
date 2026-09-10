-- Оболочка PocketOS: тонкий wrapper над визуальными компонентами.
-- Управляет загрузкой тем, состоянием рабочего стола (desktop.db)
-- и собирает рендер из подмодулей.
local POCKETOS_ROOT = "/os/lib/pocketos"
local UI_ROOT       = "/os/lib/ui_framework"

local Loader    = dofile("/os/lib/loader.lua")
local FsUtil    = Loader.require("/os/lib/fsutil.lua")
local Dashboard = Loader.require(POCKETOS_ROOT .. "/dashboard.lua")
local Launcher  = Loader.require(POCKETOS_ROOT .. "/launcher.lua")
local Taskbar   = Loader.require(POCKETOS_ROOT .. "/taskbar.lua")
local Modal     = Loader.require(POCKETOS_ROOT .. "/modal.lua")
local Toast     = Loader.require(POCKETOS_ROOT .. "/toast.lua")
local Log       = Loader.require("/os/lib/log.lua")
local Notify    = Loader.require("/os/lib/notify.lua")

local Shell = {}

Shell.WALLPAPERS = {"solid", "dots", "stars", "grid", "tiles"}
Shell.Dashboard  = Dashboard
Shell.Launcher   = Launcher
Shell.Taskbar    = Taskbar
Shell.Modal      = Modal
Shell.Toast      = Toast

local MIN_LABEL  = "[-]"
local CLOSE_LABEL = "[x]"

local function clipped(text, width)
    local s = tostring(text or "")
    if #s > width then return string.sub(s, 1, width) end
    return s .. string.rep(" ", width - #s)
end

local function drawAppTitlebar(runningApp, workArea, W, theme)
    local bg = theme.headerBg or colors.blue
    local fg = theme.headerFg or colors.white
    local ac = theme.accentBg or colors.cyan
    local title = runningApp.def.name or runningApp.def.id or "App"
    local titleW = math.max(0, W - #MIN_LABEL - #CLOSE_LABEL - 2)

    workArea.setBackgroundColor(bg)
    workArea.setTextColor(fg)
    workArea.setCursorPos(1, 1)
    workArea.write(string.rep(" ", W))

    workArea.setCursorPos(1, 1)
    workArea.setBackgroundColor(ac)
    workArea.setTextColor(colors.black)
    workArea.write(MIN_LABEL)

    if titleW > 0 then
        workArea.setCursorPos(#MIN_LABEL + 2, 1)
        workArea.setBackgroundColor(bg)
        workArea.setTextColor(fg)
        workArea.write(clipped(" " .. title, titleW))
    end

    workArea.setCursorPos(W - #CLOSE_LABEL + 1, 1)
    workArea.setBackgroundColor(colors.red)
    workArea.setTextColor(colors.white)
    workArea.write(CLOSE_LABEL)
end

local function wrap(text, width)
    local out = {}
    local s = tostring(text or "")
    while #s > width do
        table.insert(out, string.sub(s, 1, width))
        s = string.sub(s, width + 1)
    end
    if #s > 0 then table.insert(out, s) end
    return out
end

local function drawCrashBanner(r, workArea, W, AH, theme)
    local bg = colors.red
    local fg = colors.white
    workArea.setBackgroundColor(bg)
    for y = 2, AH do
        workArea.setCursorPos(1, y)
        workArea.write(string.rep(" ", W))
    end
    workArea.setCursorPos(1, 2)
    workArea.setTextColor(fg)
    workArea.write(clipped(" App crashed", W))
    workArea.setCursorPos(1, 3)
    workArea.write(clipped(" " .. (r.def.id or "app"), W))
    local lines = wrap(r.crashErr or "(no detail)", W - 2)
    local y = 5
    workArea.setTextColor(colors.yellow)
    for _, line in ipairs(lines) do
        if y > AH - 1 then break end
        workArea.setCursorPos(2, y)
        workArea.write(line)
        y = y + 1
    end
    workArea.setTextColor(colors.white)
    workArea.setCursorPos(1, AH)
    workArea.write(clipped(" Close window [x] in titlebar to dismiss", W))
end

local function safeDrawApp(r, workArea, theme)
    if r.crashed then
        local W, AH = workArea.getSize()
        drawCrashBanner(r, workArea, W, AH, theme)
        return
    end
    local ok, err = pcall(r.def.draw, r.state, r.win or workArea)
    if not ok then
        r.crashed  = true
        r.crashErr = tostring(err)
        local label = r.def.id or "app"
        Log.error("draw: " .. r.crashErr, label)
        Notify.push("App crashed: " .. label, r.crashErr,
                    {level = "error", source = label})
        local W, AH = workArea.getSize()
        drawCrashBanner(r, workArea, W, AH, theme)
    end
end

-- ── desktop.db ────────────────────────────────────────────────────────────────

local DEFAULT_DESKTOP = {
    themeIndex   = 1,
    bgColor      = colors.black,
    fgColor      = colors.lightGray,
    pattern      = "stars",
    volume       = 1.0,
    textScale    = 1.0,
    display      = "external",  -- "external" | "internal"
    modemSide    = nil,
    soundEnabled = true,        -- звуковые эффекты вкл/выкл
    clockFormat  = "24h",       -- "24h" | "12h"
    timeMode     = "real",      -- "real" (реальное, UTC+offset) | "mc" (Minecraft)
    tzOffset     = 3,           -- смещение пояса в часах для режима real (UTC+3)
    recentApps   = {},
    expandedCategories = {},
}

local DESKTOP_PATH = "/data/desktop.db"

local function desktopPath(userId)
    if userId and userId ~= "" then
        if Shell.userDataRoot then return Shell.userDataRoot(userId) .. "/desktop.db" end
        return "/data/users/" .. userId .. "/desktop.db"
    end
    return DESKTOP_PATH
end

function Shell.loadDesktop(userId)
    local d = {}
    for k, v in pairs(DEFAULT_DESKTOP) do d[k] = v end
    local path = desktopPath(userId)
    FsUtil.ensureDir(fs.getDir(path))
    if fs.exists(path) then
        local data = FsUtil.readFile(path)
        if type(data) == "string" then
            local ok, t = pcall(textutils.unserialize, data)
            if ok and type(t) == "table" then
                for k, v in pairs(t) do d[k] = v end
            end
        end
    end
    return d
end

function Shell.saveDesktop(d, userId)
    local path = desktopPath(userId)
    FsUtil.ensureDir(fs.getDir(path))
    FsUtil.atomicWrite(path, textutils.serialize(d))
end

-- ── Темы ─────────────────────────────────────────────────────────────────────

local _themes_cache = nil

local function loadThemes()
    if _themes_cache then return _themes_cache end
    local ok, t = pcall(dofile, UI_ROOT .. "/themes.lua")
    if ok and type(t) == "table" then _themes_cache = t end
    return _themes_cache
end

local FALLBACK_THEME = {
    headerBg  = colors.blue,  headerFg  = colors.white,
    sectionBg = colors.gray,  sectionFg = colors.white,
    accentBg  = colors.cyan,  columnBg  = colors.lightGray,
    columnFg  = colors.black, mutedFg   = colors.lightGray,
    pageBg    = colors.black,
}

function Shell.getTheme(themeIndex)
    local themes = loadThemes()
    if not themes then return FALLBACK_THEME end
    local idx = math.max(1, math.min(#themes, themeIndex or 1))
    return themes[idx]
end

function Shell.getThemes()
    return loadThemes() or {}
end

function Shell.getThemeCount()
    local themes = loadThemes()
    return themes and #themes or 1
end

function Shell.hitAppTitlebar(x, y, W)
    if y ~= 1 then return nil end
    if x <= #MIN_LABEL then return "minimize" end
    if x >= W - #CLOSE_LABEL + 1 then return "close" end
    return "titlebar"
end

-- ── Полный рендер кадра ───────────────────────────────────────────────────────

function Shell.render(apps, running, focusedIdx, modal, screen, scroll, query, desktop, workArea, taskbarWin, W, AH, opts)
    opts = opts or {}
    local theme = Shell.getTheme(desktop.themeIndex)

    -- Слой 1: рабочая область.
    -- Приоритет: фокусированное приложение > launcher > dashboard.
    if focusedIdx > 0 and running[focusedIdx] then
        local r = running[focusedIdx]
        drawAppTitlebar(r, workArea, W, theme)
        safeDrawApp(r, workArea, theme)
    elseif screen == "launcher" then
        Launcher.draw(apps, running, focusedIdx, scroll or 0, query or "",
                      desktop.expandedCategories or {},
                      theme, workArea, W, AH, opts.userName)
    else
        Dashboard.draw(workArea, W, AH, theme, opts.dctx or {})
    end

    -- Слой 2: модал по центру (поверх любого экрана).
    if type(modal) == "table" then
        Modal.draw(modal, workArea, W, AH, theme, {
            themes     = Shell.getThemes(),
            wallpapers = Shell.WALLPAPERS,
            hasScale   = opts.hasScale,
        })
    end

    -- Слой 2.5: тост поверх контента и модала.
    Toast.draw(workArea, theme, W, AH)

    -- Слой 3: панель задач.
    Taskbar.draw(running, focusedIdx, modal, screen, desktop, theme, taskbarWin, W, {
        unread   = opts.unread or 0,
        userName = opts.userName,
    })
end

return Shell
