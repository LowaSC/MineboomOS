-- Панель задач PocketOS: только системные элементы и запущенные приложения.
--
-- Слева:  [#] кнопка launcher (полноэкранный список приложений).
-- Центр:  узкая полоса запущенных приложений (фокус — инверсия).
-- Справа: bell [!N], громкость [V], часы.
local Clock = dofile("/os/lib/clock.lua")

local Taskbar = {}

Taskbar.CLOCK_W   = 5   -- "HH:MM"
Taskbar.VOLUME_W  = 3   -- "[V]"
Taskbar.LAUNCH_W  = 3   -- "[#]"
Taskbar.APP_W     = 4   -- "[Xx]"
Taskbar.BELL_MIN  = 3   -- "[!]" минимум

-- ── Хелперы ───────────────────────────────────────────────────────────────────

-- opts: таблица из Clock.optsFromDesktop(desktop) либо nil (тогда дефолты).
function Taskbar.getClockStr(opts)
    return Clock.clockStr(opts)
end

local function volumeGlyph(v)
    if v <= 0    then return "[x]" end
    if v <= 0.33 then return "[.]" end
    if v <= 0.66 then return "[:]" end
    return "[i]"
end

local function bellLabel(unread)
    if not unread or unread <= 0 then return "[!]", false end
    if unread > 99 then return "[!9+]", true end
    return "[!" .. tostring(unread) .. "]", true
end

local function iconText(def)
    local s = def.icon or string.sub(def.name or def.id or "?", 1, 2)
    s = tostring(s)
    if #s < 2 then s = s .. " " end
    return string.sub(s, 1, 2)
end

-- ── Геометрия ─────────────────────────────────────────────────────────────────

local function rightCluster(W, opts)
    local volX = W - Taskbar.CLOCK_W - Taskbar.VOLUME_W
    local label = bellLabel((opts or {}).unread or 0)
    local bellX = volX - #label
    return volX, bellX, label
end

local function runStripBounds(W, opts)
    local _, bellX = rightCluster(W, opts)
    local x1 = Taskbar.LAUNCH_W + 1
    local x2 = bellX - 1
    return x1, x2
end

-- ── Отрисовка ─────────────────────────────────────────────────────────────────

local function drawAppSlot(taskbarWin, x, def, focused, theme)
    local bg = def.iconBg or theme.accentBg or colors.cyan
    local fg = def.iconFg or colors.black

    taskbarWin.setCursorPos(x, 1)
    if focused then
        taskbarWin.setBackgroundColor(colors.white)
        taskbarWin.setTextColor(bg)
    else
        taskbarWin.setBackgroundColor(bg)
        taskbarWin.setTextColor(fg)
    end
    taskbarWin.write("[" .. iconText(def) .. "]")
end

function Taskbar.draw(running, focusedIdx, modal, screen, desktop, theme, taskbarWin, W, opts)
    opts = opts or {}
    local tbBg = theme.headerBg or colors.blue
    local tbFg = theme.headerFg or colors.white
    local acBg = theme.accentBg or colors.cyan

    taskbarWin.setBackgroundColor(tbBg)
    taskbarWin.setTextColor(tbFg)
    taskbarWin.clear()

    -- Launcher [#]
    local launcherOpen = (screen == "launcher")
    taskbarWin.setCursorPos(1, 1)
    taskbarWin.setBackgroundColor(launcherOpen and acBg or tbBg)
    taskbarWin.setTextColor(launcherOpen and colors.black or tbFg)
    taskbarWin.write("[#]")

    -- Часы (режим/смещение из desktop)
    local clock = Taskbar.getClockStr(Clock.optsFromDesktop(desktop))
    taskbarWin.setBackgroundColor(tbBg)
    taskbarWin.setTextColor(tbFg)
    taskbarWin.setCursorPos(W - Taskbar.CLOCK_W + 1, 1)
    taskbarWin.write(clock)

    -- Громкость
    local volX, bellX, bellStr = rightCluster(W, opts)
    local isTray = (type(modal) == "table" and modal.kind == "tray")
    taskbarWin.setBackgroundColor(isTray and acBg or tbBg)
    taskbarWin.setTextColor(tbFg)
    taskbarWin.setCursorPos(volX, 1)
    taskbarWin.write(volumeGlyph(desktop.volume or 1))

    -- Bell
    local hasUnread = (opts.unread or 0) > 0
    local isNotif = (type(modal) == "table" and modal.kind == "notifications")
    taskbarWin.setBackgroundColor(isNotif and acBg or tbBg)
    taskbarWin.setTextColor(hasUnread and colors.yellow or tbFg)
    taskbarWin.setCursorPos(bellX, 1)
    taskbarWin.write(bellStr)

    -- Полоса запущенных приложений
    local sx1, sx2 = runStripBounds(W, opts)
    local cx = sx1
    for i, r in ipairs(running) do
        if cx + Taskbar.APP_W - 1 > sx2 then break end
        drawAppSlot(taskbarWin, cx, r.def, i == focusedIdx, theme)
        cx = cx + Taskbar.APP_W
    end
end

-- ── Hit-test ──────────────────────────────────────────────────────────────────

-- Возвращает: "launcher" | ("app", runningIdx) | "tray" | "bell" | nil
function Taskbar.hit(running, x, W, opts)
    opts = opts or {}
    if x <= Taskbar.LAUNCH_W then return "launcher", nil end

    local volX, bellX, bellStr = rightCluster(W, opts)
    local clockX1 = W - Taskbar.CLOCK_W + 1
    if x >= volX and x <= clockX1 + Taskbar.CLOCK_W - 1 then
        return "tray", nil
    end
    if x >= bellX and x <= bellX + #bellStr - 1 then return "bell", nil end

    local sx1, sx2 = runStripBounds(W, opts)
    local cx = sx1
    for i = 1, #running do
        if cx + Taskbar.APP_W - 1 > sx2 then break end
        if x >= cx and x < cx + Taskbar.APP_W then return "app", i end
        cx = cx + Taskbar.APP_W
    end
    return nil, nil
end

return Taskbar
